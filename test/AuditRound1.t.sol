// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {ArtifactDeployment} from "./utils/ArtifactDeployment.sol";
import {MockIMD, MockSIMD, MockStacker, MockIntake} from "./utils/Mocks.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {Letterbox} from "../src/Letterbox.sol";
import {PleaHook} from "../src/PleaHook.sol";
import {PleaLaunch} from "../src/PleaLaunch.sol";
import {PleaDistributor} from "../src/PleaDistributor.sol";

/// Swarm audit round 1 (jobs 945bd652 / 9241c499 / eeff38ef at cd88136): the fixes, one test each.
contract AuditRound1Test is Fixture {
    using StateLibrary for IPoolManager;

    function withTribunal() internal pure override returns (bool) {
        return true;
    }

    function _letter(address who, string memory text) internal returns (uint256 id) {
        vm.prank(who);
        (bool ok, bytes memory ret) = address(letterbox).call(bytes(text));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        id = gate.lastPleaOf(who);
    }

    function _imdId() internal view returns (uint256) {
        return uint256(uint160(address(imd)));
    }

    /// R1-A3-1: a 1-wei buy pays no fee, so it must not consume the first-buy exception; the real
    /// first buy still routes its payouts to the pool, and the buy after it pays sIMD, not claims.
    function test_aDustFirstBuyDoesNotConsumeTheFirstBuyException() public {
        assertEq(imd.balanceOf(address(pm)), 0, "fresh PoolManager");
        buy(carol, 1); // one wei: the IMD fee rounds to zero
        vm.expectEmit(false, false, false, false, address(hook));
        emit PleaHook.PayoutsToPool(0);
        buy(bob, 100e18); // still the first fee-paying buy: payouts to liquidity, as accepted
        assertEq(pm.balanceOf(bob, _imdId()), 0, "bob was paid ERC-6909 claims");
        assertEq(pm.balanceOf(OWNER, _imdId()), 0, "the owner was paid claims");
        buy(alice, 100e18);
        assertGt(simd.byProject(alice, address(hook)), 0, "the next buy's cashback is sIMD");
        assertEq(pm.balanceOf(alice, _imdId()), 0, "no claims for the next buy");
    }

    /// R1-A3-2: an exact-output sell (the Letterbox's fee sale) pays the same 1.75% of the fill as an
    /// exact-input trade: the pool share is 0.25% of the fill, a third of the owner's 0.75%.
    function test_exactOutputFeeSaleSplitsTheFeeOnTheFill() public {
        buy(alice, 50e18);
        skip(1 days);
        buy(bob, 1e18); // the hour's checkpoint
        uint256 owner0 = hook.totalOwnerFees();
        uint256 pool0 = hook.totalPoolFees();
        uint256 prize0 = hook.totalPrize();
        uint256 amount = plea.balanceOf(alice) * 15 / 100;
        vm.prank(alice);
        letterbox.plead(amount, "A sliver for the plumber; the rest stays."); // exact-output fee sale
        uint256 owner = hook.totalOwnerFees() - owner0;
        uint256 pool = hook.totalPoolFees() - pool0;
        uint256 prize = hook.totalPrize() - prize0;
        assertGt(owner, 0);
        assertApproxEqRel(pool * 3, owner, 0.002e18, "the pool share is not a third of the owner's");
        assertApproxEqRel(prize, pool, 0.002e18, "the prize share is not the pool share");
    }

    /// R1-A3-3: after the death a seller drains the market band to a limit inside the liquidity-free
    /// region; rebalance places no wall at that tick, and does once a buy brings spot back.
    function test_rebalancePlacesNoWallAtASellerChosenDrainedTick() public {
        buy(alice, 100e18);
        skip(DEADMAN + 1);
        vm.prank(address(distributor));
        plea.transfer(alice, 50_000_000e18);
        (int24 mLower, int24 mUpper,) = hook.market();
        bool pz = hook.pleaIsZero();
        int24 limitTick = pz ? mLower - 6000 : mUpper + 6000;
        vm.startPrank(alice);
        plea.approve(address(router), type(uint256).max);
        router.sellExactInLimit(50_000_000e18, abi.encode(alice), TickMath.getSqrtPriceAtTick(limitTick));
        imd.approve(address(hook), type(uint256).max);
        hook.fundWall(10e18);
        vm.stopPrank();
        assertEq(hook.currentTick(), limitTick, "the sell did not stop at the seller's limit");
        assertEq(IPoolManager(address(pm)).getLiquidity(hook.poolId()), 0, "liquidity is active at the limit");
        assertTrue(hook.pendingRebalance());
        vm.prank(keeper);
        (bool ok,) = address(hook).call(abi.encodeCall(hook.rebalance, ())); // redeems claims, places no wall
        ok;
        (,, uint128 liq) = hook.wall();
        assertEq(liq, 0, "a wall was placed at the drained tick");
        assertGt(hook.retainedImd(), 9e18, "the reserve was spent");
        vm.roll(vm.getBlockNumber() + 1);
        skip(1 hours);
        buy(bob, 50e18);
        vm.prank(keeper);
        hook.rebalance();
        (int24 lo, int24 hi, uint128 liq2) = hook.wall();
        assertGt(liq2, 0, "no wall once spot is back");
        int24 near = pz ? hi : lo;
        // The wall sits against the market band, not thousands of ticks below it.
        assertTrue(pz ? near > limitTick + 3000 : near < limitTick - 3000, "the wall followed the drained tick");
    }

    /// R1-A2-2: the site's appeal of a small plea made straight at the gate (no floor there) is refused
    /// instead of delivered for nothing; a letter's appeal (no fee) still goes through.
    function test_appealAutoOfASubFloorGatePleaIsRefused() public {
        buy(alice, 20e18);
        skip(1 days);
        buy(bob, 1e18);
        uint256 bal = plea.balanceOf(alice);
        vm.prank(alice);
        uint256 id = gate.submitSell(bal / 100, "One percent for a book; the rest stays with me.");
        assertTrue(answer(id, 0), "verdict");
        uint256 worth = _worth(bal / 100); // before the prank: a view call would consume it
        assertLt(worth, 0.7e18, "setup: the gate plea is under the floor");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Letterbox.TooSmallForTheFee.selector, worth));
        letterbox.appealAuto(id, "The book is for my exam; I keep the rest.");
        uint256 a = _letter(alice, "APPEAL The book is for my exam; I keep the rest.");
        assertTrue(gate.getPlea(a).isAppeal, "a letter's appeal pays no fee and is accepted");
        assertEq(gate.getPlea(a).flags, 3);
    }

    function _worth(uint256 amount) internal view returns (uint256) {
        return amount * hook.latestPrice() / (1 << 96);
    }

    /// R1-A2-4: a lapsed letter plea's status carries the escrow note.
    function test_lapsedStatusCarriesTheEscrowNote() public {
        buy(alice, 20e18);
        skip(1 days);
        buy(bob, 1e18);
        uint256 id = _letter(alice, "Fifteen percent for the dentist; the rest stays all season.");
        assertTrue(answer(id, 45), "verdict");
        skip(7 minutes + 1);
        string memory s = letterbox.status(alice);
        assertTrue(vm.contains(s, "LAPSED"), s);
        assertTrue(vm.contains(s, "call settle to get your PLEA back"), s);
        (, bool open,) = _escrowed(id);
        assertTrue(open);
    }

    function _escrowed(uint256 id) internal view returns (address writer, bool open, uint256 amount) {
        (writer, open, amount,) = letterbox.escrowOf(id);
    }

    /// R1-A2-5: a recorded plea's status shows the points Seasons counted, not the seat read now.
    function test_recordedPointsAreShownAsCounted() public {
        buy(alice, 20e18);
        skip(1 days);
        buy(bob, 1e18);
        seat.mint(alice);
        uint256 id = _letter(alice, "Fifteen percent for the dentist; the rest stays all season.");
        assertTrue(answer(id, 45), "verdict");
        vm.prank(keeper);
        letterbox.deliver(id);
        skip(20 minutes + 1);
        seasons.record(id);
        assertEq(seasons.pointsOf(id), 54, "45 x 1.2");
        seat.burn(alice);
        string memory s = letterbox.status(alice);
        assertTrue(vm.contains(s, "+54 points"), s);
    }

    /// R1-A2-6: a zero Merkle root is refused.
    function test_zeroRootIsRefused() public {
        vm.prank(OWNER);
        vm.expectRevert(PleaDistributor.ZeroRoot.selector);
        distributor.setMerkleRoot(bytes32(0));
    }
}

/// R1-A2-1: the early-seed power follows PLEA's current owner, not the launch-time snapshot.
contract AuditRound1SeedOwnerTest is Fixture {
    address newOwner = makeAddr("newOwner");

    function setUp() public override {
        vm.chainId(11155111);
        vm.warp(T0);
        vm.roll(1000);
        pm = PoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        deployImd();
        oimd = MockIMD(ArtifactDeployment.deploy("Mocks.sol:MockIMD", bytes("")));
        simd = MockSIMD(ArtifactDeployment.deploy("Mocks.sol:MockSIMD", bytes("")));
        stacker = MockStacker(ArtifactDeployment.deploy("Mocks.sol:MockStacker", abi.encode(imd, simd)));
        intake = MockIntake(ArtifactDeployment.deploy("Mocks.sol:MockIntake", abi.encode(oracleFeeToken())));
        deployLaunch();
        deployHook();
        vm.prank(OWNER);
        plea.transferOwnership(newOwner);
        vm.prank(newOwner);
        plea.acceptOwnership();
        assertEq(plea.owner(), newOwner);
        assertLt(vm.getBlockTimestamp(), launch.START());
    }

    function test_theNewPleaOwnerMaySeedEarly() public {
        vm.prank(newOwner);
        launch.seed();
        assertTrue(gate.cabalAlive());
    }

    function test_theFormerOwnerMayNotSeedEarly() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PleaLaunch.TooEarly.selector, launch.START()));
        launch.seed();
    }
}

/// R1-A2-3: on the mainnet fee path, whoever could plead by letter can appeal by letter.
contract AuditRound1MainnetAppealTest is Fixture {
    function oracleFeeToken() internal view override returns (MockIMD) {
        return imd;
    }

    function test_aSmallWriterCanAppealByLetterOnMainnet() public {
        buy(bob, 50e18);
        buy(alice, 8.7e18);
        skip(1 days);
        buy(carol, 1e18);
        vm.prank(alice);
        (bool ok,) = address(letterbox).call(bytes("Fifteen percent for the phone bill; the rest stays with me."));
        assertTrue(ok, "the letter was refused");
        uint256 id = gate.lastPleaOf(alice);
        assertTrue(answer(id, 0), "verdict");
        vm.prank(alice);
        (ok,) = address(letterbox).call(bytes("APPEAL The phone is how I work; I keep the rest."));
        assertTrue(ok, "the appeal letter was refused");
        uint256 a = gate.lastPleaOf(alice);
        assertTrue(gate.getPlea(a).isAppeal);
        assertEq(gate.getPlea(a).originalId, id);
    }
}
