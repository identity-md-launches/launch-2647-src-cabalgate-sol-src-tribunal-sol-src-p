// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PleaHook} from "./PleaHook.sol";
import {IStacker} from "./interfaces/IStacker.sol";
import {IGate, IPleaHook} from "./interfaces/IPleaParts.sol";

interface IPLEAForLaunch {
    function owner() external view returns (address);
    function setLauncher(address gate, address seasons, address distributor) external;
    function setLetterbox(address letterbox) external;
    function init(address hook, address poolManager) external;
}

/// @title PleaLaunch — wires PLEA at launch and deploys the hook, the Letterbox and the Tribunal afterwards
/// @dev Last contract of the launch. Its constructor (inside the launch transaction) registers the
/// system's contracts with PLEA and commits to the hook's, the Letterbox's and the Tribunal's exact
/// init code, so the launch transaction stays under Ethereum's 16,777,216-gas cap. After launch,
/// anyone calls `deployHook` with a salt mined off chain (script/MineSalt.s.sol): the hook lands on
/// an address carrying its flag bits, and PLEA mints 82% to it, 6% to Seasons and 12% to the
/// distributor. Anyone calls `deployLetterbox` and `deployTribunal` once each with the committed
/// creation code: both read their settings from this contract. Every result's code and settings are
/// fully determined by the committed code, so front-running any of these calls changes nothing but,
/// for the hook, the address: the salt is the caller's, so a front-runner may land the same hook at
/// another flag-valid address (the Letterbox and the Tribunal use salt 0 and have fixed addresses). A zero Tribunal hash
/// launches with objections off for good. `seed` opens trading once the hook, the Letterbox and a
/// committed Tribunal exist: the owner may call it any time, anyone once `START` has passed.
/// @dev Round 5, R5-A2-1: the Letterbox's (and the Tribunal's) oracle-fee settings are checked here,
/// in the launch transaction, wherever they do not depend on the chain; the one that does (no minted
/// fee on chain id 1) stops `deployLetterbox`, and `seed` waits for the Letterbox, so trading never
/// opens on a launch whose letters could never work.
contract PleaLaunch {
    error WrongInitCode();
    error HookDeployFailed();
    error WrongFlags(address hook);
    error HookAlreadyDeployed();
    error HookNotDeployed();
    error TooEarly(uint256 start);
    error BelowAgreedTiming();
    error BelowAgreedMarketCap();
    error LetterboxAlreadyDeployed();
    error LetterboxDeployFailed();
    error TribunalOff();
    error TribunalAlreadyDeployed();
    error TribunalDeployFailed();
    error OracleAssetNotImd();
    error MintWithPoolImd();
    error OracleAssetMismatch();
    error LetterboxNotDeployed();
    error TribunalNotDeployed();

    event HookDeployed(address indexed hook, bytes32 salt);
    event LetterboxDeployed(address indexed letterbox);
    event TribunalDeployed(address indexed tribunal);
    event TradingOpened(uint256 at);

    uint160 public constant FLAG_MASK = (1 << 14) - 1;
    /// beforeInitialize | beforeAddLiquidity | beforeSwap | afterSwap | beforeSwapReturnDelta | afterSwapReturnDelta
    uint160 public constant FLAGS = (1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);

    address public immutable plea;
    address public immutable gate;
    address public immutable seasons;
    address public immutable poolManager;
    address public immutable imd;
    address public immutable owner;
    /// @notice Latest time trading opens: from then on anyone may call `seed`.
    uint256 public immutable START;
    bytes32 public immutable hookInitCodeHash;
    /// @notice The Letterbox's settings, read by its constructor: the asset the oracle fee is paid
    /// in, and whether it mints that fee (Sepolia's open-mint test token; refused on chain id 1).
    address public immutable oracleAsset;
    bool public immutable mintOracleFee;
    /// @notice keccak256 of the Letterbox's creation code (it takes no constructor arguments).
    bytes32 public immutable letterboxCodeHash;
    /// @notice keccak256 of the Tribunal's creation code (no constructor arguments); zero means the
    /// launch has no objections.
    bytes32 public immutable tribunalCodeHash;

    address public hook;
    address public letterbox;
    address public tribunal;
    bool public opened;

    constructor(
        address plea_,
        address gate_,
        address seasons_,
        address distributor_,
        address poolManager_,
        address imd_,
        address stacker_,
        uint256 creditGas_,
        uint256 start_,
        address oracleAsset_,
        bool mintOracleFee_,
        bytes32 letterboxCodeHash_,
        bytes32 tribunalCodeHash_
    ) {
        plea = plea_;
        gate = gate_;
        seasons = seasons_;
        poolManager = poolManager_;
        imd = imd_;
        START = start_;
        oracleAsset = oracleAsset_;
        mintOracleFee = mintOracleFee_;
        letterboxCodeHash = letterboxCodeHash_;
        tribunalCodeHash = tribunalCodeHash_;
        // No creation code hashes to zero, and the two committed codes differ: a zero or swapped
        // Letterbox hash would leave trading closed for good (round 6, R6-A2-1). A zero Tribunal
        // hash stays "objections off".
        if (letterboxCodeHash_ == bytes32(0) || letterboxCodeHash_ == tribunalCodeHash_) revert WrongInitCode();
        // The Letterbox's constructor refusals that hold on every chain (it repeats them).
        if (!mintOracleFee_ && oracleAsset_ != imd_) revert OracleAssetNotImd();
        if (mintOracleFee_ && oracleAsset_ == imd_) revert MintWithPoolImd();
        if (IGate(gate_).oracleAsset() != oracleAsset_) revert OracleAssetMismatch();
        address owner_ = IPLEAForLaunch(plea_).owner();
        owner = owner_;
        hookInitCodeHash = keccak256(
            abi.encodePacked(
                type(PleaHook).creationCode,
                abi.encode(poolManager_, plea_, imd_, stacker_, owner_, seasons_, creditGas_)
            )
        );
        IPLEAForLaunch(plea_).setLauncher(gate_, seasons_, distributor_);
    }

    /// @notice Deploys PleaHook with CREATE2 at a flagged address and lets PLEA mint the supply.
    /// `initCode` must be the committed one (PleaHook creation code + its constructor arguments).
    function deployHook(bytes32 salt, bytes calldata initCode) external returns (address deployed) {
        if (hook != address(0)) revert HookAlreadyDeployed();
        if (keccak256(initCode) != hookInitCodeHash) revert WrongInitCode();
        if (uint160(predict(salt)) & FLAG_MASK != FLAGS) revert WrongFlags(predict(salt));
        bytes memory code = initCode;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        if (deployed == address(0)) revert HookDeployFailed();
        hook = deployed;
        IPLEAForLaunch(plea).init(deployed, poolManager);
        emit HookDeployed(deployed, salt);
    }

    /// @notice Deploys the Letterbox with CREATE2 (salt 0) and registers it with PLEA, once.
    /// `creationCode` must be the committed one; the Letterbox reads its settings from this contract.
    function deployLetterbox(bytes calldata creationCode) external returns (address deployed) {
        if (letterbox != address(0)) revert LetterboxAlreadyDeployed();
        if (keccak256(creationCode) != letterboxCodeHash) revert WrongInitCode();
        bytes memory code = creationCode;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), 0)
        }
        if (deployed == address(0)) revert LetterboxDeployFailed();
        letterbox = deployed;
        IPLEAForLaunch(plea).setLetterbox(deployed);
        emit LetterboxDeployed(deployed);
    }

    /// @notice Deploys the Tribunal (Objection!) with CREATE2 (salt 0), once. `creationCode` must be
    /// the committed one; the Tribunal reads its settings from this contract and Seasons finds it here.
    function deployTribunal(bytes calldata creationCode) external returns (address deployed) {
        if (tribunalCodeHash == bytes32(0)) revert TribunalOff();
        if (tribunal != address(0)) revert TribunalAlreadyDeployed();
        if (keccak256(creationCode) != tribunalCodeHash) revert WrongInitCode();
        bytes memory code = creationCode;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), 0)
        }
        if (deployed == address(0)) revert TribunalDeployFailed();
        tribunal = deployed;
        emit TribunalDeployed(deployed);
    }

    /// @notice The address `deployTribunal` deploys to (zero when objections are off).
    function predictTribunal() external view returns (address) {
        if (tribunalCodeHash == bytes32(0)) return address(0);
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(0), tribunalCodeHash))))
        );
    }

    /// @notice The address `deployLetterbox` deploys to.
    function predictLetterbox() external view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(0), letterboxCodeHash))))
        );
    }

    /// @notice The address `deployHook(salt, …)` deploys to.
    function predict(bytes32 salt) public view returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hookInitCodeHash)))));
    }

    /// @notice Opens trading: creates the pool (90-min launch window starts) and the first Cabal's era.
    /// The hook, the Letterbox and a committed Tribunal must exist (anyone may deploy each with the
    /// committed code), so no plea is ever recorded out of the Tribunal's reach (round 6).
    function seed() external {
        if (hook == address(0)) revert HookNotDeployed();
        if (letterbox == address(0)) revert LetterboxNotDeployed();
        if (tribunalCodeHash != bytes32(0) && tribunal == address(0)) revert TribunalNotDeployed();
        // The early-seed power follows PLEA's current owner (Ownable2Step), not the launch-time snapshot.
        if (msg.sender != IPLEAForLaunch(plea).owner() && block.timestamp < START) revert TooEarly(START);
        // The agreed mainnet clock and opening market cap, checked on the live chain rather than in a
        // constructor: launch rehearsals deploy the manifest on a bare EVM whose chain id is 1. The cap is
        // the hook's compile-time constant (5,700 IMD on the Sepolia code), so a Sepolia build can never
        // open trading on chain id 1 (round 8, R8-A3-1).
        if (block.chainid == 1) {
            if (IGate(gate).SEASON() < 15 days || IGate(gate).DEADMAN() < 33 hours) revert BelowAgreedTiming();
            if (IPleaHook(hook).MARKET_CAP_IMD() < 14_000e18) revert BelowAgreedMarketCap();
        }
        opened = true;
        IPleaHook(hook).seed();
        IGate(gate).begin();
        emit TradingOpened(block.timestamp);
    }
}
