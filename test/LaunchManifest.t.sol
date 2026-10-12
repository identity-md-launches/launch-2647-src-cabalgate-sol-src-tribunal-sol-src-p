// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PLEA} from "../src/PLEA.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {Seasons} from "../src/Seasons.sol";
import {Laureates} from "../src/Laureates.sol";
import {PleaDistributor} from "../src/PleaDistributor.sol";
import {Letterbox} from "../src/Letterbox.sol";
import {PleaLaunch} from "../src/PleaLaunch.sol";
import {PleaHook} from "../src/PleaHook.sol";

/// @dev Test-only equivalent of the factory's zero-value, ordered CREATE2 deployment.
contract ManifestFactory {
    function deploy(bytes memory code, bytes32 salt) public returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
            if iszero(deployed) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
    }

    function deployAll(bytes[7] memory codes) external returns (address[7] memory deployed) {
        for (uint256 i; i < 7; ++i) {
            deployed[i] = deploy(codes[i], bytes32(i));
        }
    }
}

abstract contract ManifestFixture is Test {
    // Exact static constructor values from the supplied launch.json. Only $owner and earlier
    // contract references are resolved locally; no external contract is installed or called.
    // Mainnet draft: IMD is both the oracle fee asset and the pool currency, so the Letterbox buys
    // the oracle fee with PLEA (mintOracleFee = false).
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant ORACLE_ASSET = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    /// @dev Placeholders until launch.json has them: the mainnet Stacker and START.
    address constant STACKER = address(0x5743C3E7);
    uint256 constant START = 1791817200;
    uint256 constant SEASON = 15 days;
    uint256 constant CREDIT_GAS = 400_000;

    ManifestFactory factory;
    address owner;
    bytes[7] codes;
    address[7] expected;

    function setUp() public virtual {
        vm.chainId(1);
        vm.roll(1000);
        vm.warp(START - 1 days);
        owner = makeAddr("manifest owner");
        factory = new ManifestFactory();
        _prepare(0, "PLEA.sol:PLEA", abi.encode(owner));
        _prepare(
            1,
            "CabalGate.sol:CabalGate",
            abi.encode(expected[0], INTAKE, ORACLE_ASSET, IMD, SIGNER, SEASON, uint256(118800))
        );
        _prepare(2, "Seasons.sol:Seasons", abi.encode(expected[0], expected[1], IMD));
        _prepare(3, "Laureates.sol:Laureates", abi.encode(expected[0]));
        _prepare(4, "PleaDistributor.sol:PleaDistributor", abi.encode(expected[0], owner));
        _prepare(
            5,
            "Letterbox.sol:Letterbox",
            abi.encode(expected[0], expected[1], expected[2], expected[3], IMD, ORACLE_ASSET, false)
        );
        _prepare(
            6,
            "PleaLaunch.sol:PleaLaunch",
            abi.encode(
                expected[0],
                expected[1],
                expected[2],
                expected[3],
                expected[4],
                expected[5],
                POOL_MANAGER,
                IMD,
                STACKER,
                CREDIT_GAS,
                START
            )
        );
    }

    function _prepare(uint256 i, string memory artifact, bytes memory args) internal {
        codes[i] = bytes.concat(vm.getCode(artifact), args);
        expected[i] = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), bytes32(i), keccak256(codes[i]))))
            )
        );
        assertLe(codes[i].length, 49_152, "EIP-3860 init code limit");
    }

    function _assertWiring() internal view {
        PLEA p = PLEA(expected[0]);
        CabalGate g = CabalGate(expected[1]);
        Seasons s = Seasons(expected[2]);
        PleaLaunch l = PleaLaunch(expected[6]);
        assertEq(p.owner(), owner);
        assertEq(p.launcher(), expected[6]);
        assertEq(p.letterbox(), expected[5]);
        assertEq(p.gate(), expected[1]);
        assertEq(p.seasons(), expected[2]);
        assertEq(p.laureates(), expected[3]);
        assertEq(p.distributor(), expected[4]);
        assertEq(address(g.plea()), expected[0]);
        assertEq(address(g.intake()), INTAKE);
        assertEq(address(g.oracleAsset()), ORACLE_ASSET);
        assertEq(address(g.imd()), IMD);
        assertEq(g.oracleSigner(), SIGNER);
        assertEq(g.SEASON(), SEASON);
        assertEq(g.DEADMAN(), 118800);
        assertEq(g.PANEL_SIZE(), 30);
        assertEq(g.QUORUM(), 17);
        assertEq(address(s.plea()), expected[0]);
        assertEq(address(s.gate()), expected[1]);
        assertEq(address(s.imd()), IMD);
        assertEq(s.SEASON(), SEASON);
        assertEq(address(Laureates(expected[3]).plea()), expected[0]);
        assertEq(address(PleaDistributor(expected[4]).plea()), expected[0]);
        assertEq(PleaDistributor(expected[4]).owner(), owner);
        assertEq(l.plea(), expected[0]);
        assertEq(l.gate(), expected[1]);
        assertEq(l.owner(), owner);
        assertEq(l.poolManager(), POOL_MANAGER);
        assertEq(l.START(), START);
        assertEq(l.hookInitCodeHash(), keccak256(_hookCode()));
        assertEq(p.totalSupply(), 0, "hook deployment must remain a separate step");
        assertEq(p.hook(), address(0));
        assertEq(g.startedAt(), 0);
        assertTrue(p.restricted());
        assertFalse(l.opened());
    }

    function _hookCode() internal view returns (bytes memory) {
        return bytes.concat(
            vm.getCode("PleaHook.sol:PleaHook"),
            abi.encode(POOL_MANAGER, expected[0], IMD, STACKER, owner, expected[2], CREDIT_GAS)
        );
    }
}

contract AtomicManifestTest is ManifestFixture {
    function test_factoryDeploysExactManifestOnAnEmptyChain() public {
        assertEq(
            INTAKE.code.length + ORACLE_ASSET.code.length + IMD.code.length + POOL_MANAGER.code.length
                + STACKER.code.length,
            0
        );
        uint256 before = gasleft();
        address[7] memory deployed = factory.deployAll(codes);
        uint256 gasUsed = before - gasleft();
        emit log_named_uint("seven-contract factory deployment gas", gasUsed);
        // Mainnet draft: the full run-3 code is over Ethereum's 16,777,216 per-transaction cap.
        // Whether IMD's mainnet factory deploy is bound by that cap is an open question to IMD; this
        // test reports the margin and does not assert it.
        emit log_named_int("margin to the 16,777,216 mainnet cap", int256(16_777_216) - int256(gasUsed));
        for (uint256 i; i < 7; ++i) {
            assertEq(deployed[i], expected[i]);
            bytes memory runtime = deployed[i].code;
            assertGt(runtime.length, 0);
            assertLe(runtime.length, 24_576);
            // The supplied protected floor's scanner: skip PUSH data, scan every runtime opcode.
            for (uint256 j; j < runtime.length; ++j) {
                uint8 op = uint8(runtime[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
            }
        }
        _assertWiring();
    }
}

contract RehearsalManifestTest is ManifestFixture {
    function setUp() public override {
        super.setUp();
        factory.deploy(codes[0], bytes32(0));
        // Foundry ends this call before running a test, clearing PLEA's transient deployment flag.
    }

    function test_separateConstructorCallsInDeploymentBlockStillWork() public {
        for (uint256 i = 1; i < 7; ++i) {
            factory.deploy(codes[i], bytes32(i));
        }
        _assertWiring();
    }

    function test_laterBlockCannotRegisterLauncher() public {
        vm.roll(vm.getBlockNumber() + 1);
        for (uint256 i = 1; i < 6; ++i) {
            factory.deploy(codes[i], bytes32(i));
        }
        vm.expectRevert(PLEA.NotDeployTx.selector);
        factory.deploy(codes[6], bytes32(uint256(6)));
    }

    /// @dev Reproduces the accepted informational finding; real launch must use deployAll atomically.
    function test_separateTransactionsLeaveTheAcceptedDeploymentBlockWindow() public {
        address attacker = makeAddr("deployment-block attacker");
        vm.prank(attacker);
        PLEA(expected[0]).setLauncher(expected[1], expected[2], expected[3], expected[4]);
        assertEq(PLEA(expected[0]).launcher(), attacker);
        for (uint256 i = 1; i < 6; ++i) {
            factory.deploy(codes[i], bytes32(i));
        }
        vm.expectRevert(PLEA.AlreadySet.selector);
        factory.deploy(codes[6], bytes32(uint256(6)));
    }
}

contract PostLaunchHookTest is ManifestFixture {
    function setUp() public override {
        super.setUp();
        factory.deployAll(codes);
    }

    function test_committedHookDeploysLaterAndMintsOnlyTheFixedSplit() public {
        _assertWiring();
        vm.roll(vm.getBlockNumber() + 1);
        PleaLaunch l = PleaLaunch(expected[6]);
        bytes memory code = _hookCode();
        bytes32 hash = keccak256(code);
        uint160 flags = l.FLAGS();
        uint256 salt;
        while (
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(l), bytes32(salt), hash)))) & 0x3fff
                != flags
        ) ++salt;
        address h = l.deployHook(bytes32(salt), code);
        PLEA p = PLEA(expected[0]);
        assertEq(p.hook(), h);
        assertEq(p.poolManager(), POOL_MANAGER);
        assertEq(p.totalSupply(), 1_000_000_000e18);
        assertEq(p.balanceOf(h), 870_000_000e18);
        assertEq(p.balanceOf(expected[2]), 30_000_000e18);
        assertEq(p.balanceOf(expected[4]), 100_000_000e18);
        assertEq(PleaHook(h).owner(), owner);
        assertEq(address(PleaHook(h).stacker()), STACKER);
        assertEq(PleaHook(h).seasons(), expected[2]);
        assertEq(PleaHook(h).creditGas(), CREDIT_GAS);
        assertFalse(PleaHook(h).seeded());
        vm.expectRevert(PleaLaunch.HookAlreadyDeployed.selector);
        l.deployHook(bytes32(salt), code);
    }
}
