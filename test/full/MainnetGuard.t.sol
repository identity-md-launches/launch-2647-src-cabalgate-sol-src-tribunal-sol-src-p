// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "../utils/Fixture.sol";
import {ArtifactDeployment} from "../utils/ArtifactDeployment.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PleaLaunch} from "../../src/PleaLaunch.sol";
import {MockIMD, MockSIMD, MockStacker, MockIntake} from "../utils/Mocks.sol";

/// @dev The agreed mainnet clock (15-day seasons, 33-hour dead-man) is enforced when trading opens,
/// on the live chain, not in CabalGate's constructor: IMD's launch rehearsal deploys the manifest on
/// a bare EVM whose chain id is 1, where a constructor check refused the Sepolia settings (run 5,
/// launch #1691 parked).
abstract contract MainnetGuardBase is Fixture {
    /// @dev The mainnet path: the oracle fee is pool IMD, nothing is minted (the Letterbox and the
    /// Tribunal refuse `mintOracleFee` on chain id 1 by their own guard; they are not in the manifest).
    function oracleFeeToken() internal view override returns (MockIMD) {
        return imd;
    }

    /// @dev The fixture up to, but not including, seed, on chain id 1 (each suite sets its own clock).
    function setUp() public override {
        vm.chainId(1);
        vm.warp(T0);
        vm.roll(1000);
        setTimings();
        pm = PoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        deployImd();
        oimd = MockIMD(ArtifactDeployment.deploy("Mocks.sol:MockIMD", bytes("")));
        simd = MockSIMD(ArtifactDeployment.deploy("Mocks.sol:MockSIMD", bytes("")));
        stacker = MockStacker(ArtifactDeployment.deploy("Mocks.sol:MockStacker", abi.encode(imd, simd)));
        intake = MockIntake(ArtifactDeployment.deploy("Mocks.sol:MockIntake", abi.encode(oracleFeeToken())));
        deployLaunch();
        deployHook();
    }
}

contract MainnetGuardTest is MainnetGuardBase {
    function setTimings() internal override {
        SEASON = 5 hours;
        DEADMAN = 33 hours;
    }

    function test_manifestDeploysOnChainOneWithTheFastClock() public view {
        assertEq(block.chainid, 1);
        assertEq(gate.SEASON(), 5 hours);
        assertEq(gate.startedAt(), 0);
    }

    function test_seedRefusesTheFastClockOnChainOne() public {
        vm.prank(OWNER);
        vm.expectRevert(PleaLaunch.BelowAgreedTiming.selector);
        launch.seed();
        assertEq(gate.startedAt(), 0);
    }

    function test_seedOpensOnAnyOtherChain() public {
        vm.chainId(11155111);
        vm.prank(OWNER);
        launch.seed();
        assertEq(gate.startedAt(), uint64(block.timestamp));
    }
}

/// @dev Round 8 (R8-A3-1): with the agreed clock, `seed` on chain id 1 also refuses a hook built with
/// the Sepolia opening market cap (the compile-time `MARKET_CAP_IMD`, 5,700 IMD); the mainnet
/// branch's 14,000 opens.
contract MainnetMarketCapGuardTest is MainnetGuardBase {
    function setTimings() internal override {
        SEASON = 15 days;
        DEADMAN = 33 hours;
    }

    function test_chainOneSeedNeedsTheAgreedMarketCap() public {
        assertEq(block.chainid, 1);
        uint256 cap = hook.MARKET_CAP_IMD();
        vm.prank(OWNER);
        if (cap < 14_000e18) {
            vm.expectRevert(PleaLaunch.BelowAgreedMarketCap.selector);
            launch.seed();
            assertEq(gate.startedAt(), 0, "a Sepolia build never opens trading on chain id 1");
        } else {
            launch.seed();
            assertEq(gate.startedAt(), uint64(block.timestamp));
        }
    }
}
