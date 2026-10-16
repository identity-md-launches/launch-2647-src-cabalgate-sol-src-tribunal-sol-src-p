// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ArtifactDeployment} from "./utils/ArtifactDeployment.sol";

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PLEA} from "../src/PLEA.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {Seasons} from "../src/Seasons.sol";
import {PleaDistributor} from "../src/PleaDistributor.sol";
import {Letterbox} from "../src/Letterbox.sol";
import {PleaLaunch} from "../src/PleaLaunch.sol";
import {PleaHook} from "../src/PleaHook.sol";
import {MockIMD, MockIntake} from "./utils/Mocks.sol";

/// @dev The launch as IMD runs it: five constructors, then deployLetterbox, deployHook and seed.
contract LaunchTest is Test {
    address constant OWNER = 0x4b91078b2374c956A65F7Af0999CaE0a935E6821;
    address constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    uint256 constant START = 1_800_100_000;

    PoolManager pm;
    MockIMD imd;
    PLEA plea;
    Seasons seasons;
    CabalGate gate;
    PleaLaunch launch;
    address stacker = address(0x5747);
    bool overrideHashes;
    bytes32 letterboxHashOverride;
    bytes32 tribunalHashOverride;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(1_800_000_000);
        pm = PoolManager(ArtifactDeployment.deploy("PoolManager.sol:PoolManager", abi.encode(address(this))));
        imd = MockIMD(ArtifactDeployment.deploy("Mocks.sol:MockIMD", bytes("")));
    }

    function deployAll(address poolManager) internal {
        deployAll(poolManager, address(imd), false);
    }

    /// @dev `oracleAsset` is the gate's fee asset; the launch names `launchAsset` and `mint`.
    function deployAll(address poolManager, address oracleAsset, bool mint) internal {
        deployAll(poolManager, oracleAsset, oracleAsset, mint);
    }

    function deployAll(address poolManager, address oracleAsset, address launchAsset, bool mint) internal {
        MockIntake intake = MockIntake(ArtifactDeployment.deploy("Mocks.sol:MockIntake", abi.encode(imd)));
        plea = PLEA(ArtifactDeployment.deploy("PLEA.sol:PLEA", abi.encode(OWNER)));
        gate = CabalGate(
            ArtifactDeployment.deploy(
                "CabalGate.sol:CabalGate",
                abi.encode(address(plea), address(intake), oracleAsset, address(imd), SIGNER, 5 hours, 27.5 minutes)
            )
        );
        seasons = Seasons(
            ArtifactDeployment.deploy(
                "Seasons.sol:Seasons", abi.encode(address(plea), address(gate), address(imd), address(0))
            )
        );
        PleaDistributor d = PleaDistributor(
            ArtifactDeployment.deploy("PleaDistributor.sol:PleaDistributor", abi.encode(address(plea), OWNER))
        );
        launch = PleaLaunch(
            ArtifactDeployment.deploy(
                "PleaLaunch.sol:PleaLaunch",
                abi.encode(
                    address(plea),
                    address(gate),
                    address(seasons),
                    address(d),
                    poolManager,
                    address(imd),
                    stacker,
                    1_300_000,
                    START,
                    launchAsset,
                    mint,
                    overrideHashes ? letterboxHashOverride : keccak256(vm.getCode("Letterbox.sol:Letterbox")),
                    overrideHashes ? tribunalHashOverride : bytes32(0)
                )
            )
        );
    }

    function initCode() internal view returns (bytes memory) {
        return abi.encodePacked(
            vm.getCode("PleaHook.sol:PleaHook"),
            abi.encode(address(pm), address(plea), address(imd), stacker, OWNER, address(seasons), uint256(1_300_000))
        );
    }

    function mine() internal view returns (bytes32 salt) {
        for (uint256 s;; ++s) {
            if (uint160(launch.predict(bytes32(s))) & 0x3fff == launch.FLAGS()) return bytes32(s);
        }
    }

    function test_launchWiresEverythingWithoutCallingOutside() public {
        // An empty chain: the PoolManager has no code; every constructor still succeeds.
        deployAll(address(0xdead));
        assertEq(plea.launcher(), address(launch));
        assertEq(plea.gate(), address(gate));
        assertEq(plea.seasons(), address(seasons));
        assertTrue(plea.restricted());
        assertEq(gate.startedAt(), 0);
        assertEq(plea.letterbox(), address(0), "the Letterbox comes after the launch");
        assertEq(launch.letterboxCodeHash(), keccak256(vm.getCode("Letterbox.sol:Letterbox")));
    }

    function test_deployHookChecksTheInitCodeAndFlags() public {
        deployAll(address(pm));
        bytes memory code = initCode();
        bytes32 salt = mine();
        bytes memory wrong = bytes.concat(code, hex"00");
        vm.expectRevert(PleaLaunch.WrongInitCode.selector);
        launch.deployHook(salt, wrong);
        bytes32 bad = salt == bytes32(0) ? bytes32(uint256(1)) : bytes32(0);
        if (uint160(launch.predict(bad)) & 0x3fff != launch.FLAGS()) {
            vm.expectRevert();
            launch.deployHook(bad, code);
        }
        vm.prank(address(0xBEEF)); // anyone may deploy it: the outcome is fixed
        address h = launch.deployHook(salt, code);
        assertEq(uint160(h) & 0x3fff, launch.FLAGS());
        assertEq(plea.hook(), h);
        assertEq(plea.balanceOf(h), 820_000_000e18);
        assertEq(plea.balanceOf(address(seasons)), 60_000_000e18);
        vm.expectRevert(PleaLaunch.HookAlreadyDeployed.selector);
        launch.deployHook(salt, code);
    }

    function test_seedByOwnerAnyTimeByAnyoneAfterStart() public {
        deployAll(address(pm));
        vm.expectRevert(PleaLaunch.HookNotDeployed.selector);
        launch.seed();
        launch.deployHook(mine(), initCode());
        vm.expectRevert(PleaLaunch.LetterboxNotDeployed.selector);
        launch.seed();
        launch.deployLetterbox(vm.getCode("Letterbox.sol:Letterbox"));
        vm.expectRevert(abi.encodeWithSelector(PleaLaunch.TooEarly.selector, START));
        launch.seed();
        vm.warp(START);
        launch.seed();
        assertTrue(gate.cabalAlive());
        assertEq(gate.startedAt(), START);
        vm.expectRevert();
        launch.seed();
    }

    function test_ownerMaySeedEarly() public {
        deployAll(address(pm));
        launch.deployHook(mine(), initCode());
        launch.deployLetterbox(vm.getCode("Letterbox.sol:Letterbox"));
        vm.prank(OWNER);
        launch.seed();
        assertTrue(PleaHook(plea.hook()).seeded());
    }

    /// @dev Round 5, R5-A2-1: the Letterbox's chain-independent refusals stop the launch itself.
    function test_theLaunchRefusesAnOracleSetupTheLetterboxWouldRefuse() public {
        address fee = ArtifactDeployment.deploy("Mocks.sol:MockIMD", bytes(""));
        vm.expectRevert(PleaLaunch.OracleAssetNotImd.selector);
        this.launchWith(fee, fee, false); // a foreign fee asset, not minted
        vm.expectRevert(PleaLaunch.MintWithPoolImd.selector);
        this.launchWith(address(imd), address(imd), true); // minting the pool IMD
        vm.expectRevert(PleaLaunch.OracleAssetMismatch.selector);
        this.launchWith(address(imd), fee, true); // the gate pulls IMD, the launch mints another token
        this.launchWith(fee, fee, true); // Sepolia's settings
        this.launchWith(address(imd), address(imd), false); // the mainnet settings
    }

    /// @dev Round 6 (R6-A2-1): a zero Letterbox hash, or the Tribunal's in its place, would leave
    /// trading closed for good; the launch refuses both. A zero Tribunal hash stays "objections off".
    function test_theLaunchRefusesAZeroOrSwappedLetterboxHash() public {
        bytes32 lb = keccak256(vm.getCode("Letterbox.sol:Letterbox"));
        bytes32 tr = keccak256(vm.getCode("Tribunal.sol:Tribunal"));
        vm.expectRevert(PleaLaunch.WrongInitCode.selector);
        this.launchWithHashes(bytes32(0), bytes32(0));
        vm.expectRevert(PleaLaunch.WrongInitCode.selector);
        this.launchWithHashes(bytes32(0), tr);
        vm.expectRevert(PleaLaunch.WrongInitCode.selector);
        this.launchWithHashes(tr, tr);
        this.launchWithHashes(lb, bytes32(0));
        this.launchWithHashes(lb, tr);
    }

    function launchWithHashes(bytes32 letterboxHash, bytes32 tribunalHash) external {
        letterboxHashOverride = letterboxHash;
        tribunalHashOverride = tribunalHash;
        overrideHashes = true;
        deployAll(address(pm));
        overrideHashes = false;
    }

    function launchWith(address gateAsset, address launchAsset, bool mint) external {
        deployAll(address(pm), gateAsset, launchAsset, mint);
    }

    /// @dev Round 5, R5-A2-1: Sepolia's minted fee on chain id 1 (IMD's launch rehearsal accepts it,
    /// so the launch cannot refuse it): the Letterbox refuses, and trading never opens.
    function test_aMintedFeeOnChainOneNeverOpensTrading() public {
        vm.chainId(1);
        address fee = ArtifactDeployment.deploy("Mocks.sol:MockIMD", bytes(""));
        deployAll(address(pm), fee, true);
        launch.deployHook(mine(), initCode());
        vm.expectRevert(PleaLaunch.LetterboxDeployFailed.selector);
        launch.deployLetterbox(vm.getCode("Letterbox.sol:Letterbox"));
        vm.prank(OWNER);
        vm.expectRevert(PleaLaunch.LetterboxNotDeployed.selector);
        launch.seed();
        vm.warp(START);
        vm.expectRevert(PleaLaunch.LetterboxNotDeployed.selector);
        launch.seed();
        assertEq(gate.startedAt(), 0);
    }

    function test_eachStepFitsAMainnetTransaction() public {
        uint256 g = gasleft();
        deployAll(address(pm));
        uint256 deployGas = g - gasleft();
        bytes memory lbCode = vm.getCode("Letterbox.sol:Letterbox");
        g = gasleft();
        launch.deployLetterbox(lbCode);
        uint256 letterboxGas = g - gasleft();
        bytes memory code = initCode();
        bytes32 salt = mine();
        g = gasleft();
        launch.deployHook(salt, code);
        uint256 hookGas = g - gasleft();
        vm.prank(OWNER);
        g = gasleft();
        launch.seed();
        uint256 seedGas = g - gasleft();
        emit log_named_uint("launch (5 contracts + intake mock)", deployGas);
        emit log_named_uint("deployLetterbox", letterboxGas);
        emit log_named_uint("deployHook", hookGas);
        emit log_named_uint("seed", seedGas);
        assertLt(deployGas, 16_777_216);
        assertLt(letterboxGas, 16_777_216);
        assertLt(hookGas, 16_777_216);
        assertLt(seedGas, 16_777_216);
        assertTrue(PleaHook(plea.hook()).seeded());
        assertEq(Letterbox(payable(plea.letterbox())).nameOf(OWNER), "");
    }
}
