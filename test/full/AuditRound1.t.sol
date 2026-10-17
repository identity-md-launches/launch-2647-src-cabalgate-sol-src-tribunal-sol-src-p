// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "../utils/Fixture.sol";
import {ArtifactDeployment} from "../utils/ArtifactDeployment.sol";
import {MockIMD, MockSIMD, MockStacker, MockIntake} from "../utils/Mocks.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {CabalGate} from "../../src/CabalGate.sol";
import {Letterbox} from "../../src/Letterbox.sol";
import {PleaHook} from "../../src/PleaHook.sol";
import {PleaLaunch} from "../../src/PleaLaunch.sol";
import {PleaDistributor} from "../../src/PleaDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {MockStacker} from "../utils/Mocks.sol";

/// Swarm audit round 1 (jobs 945bd652 / 9241c499 / eeff38ef at cd88136): the fixes, one test each.
contract AuditRound1Test is Fixture {
    using StateLibrary for IPoolManager;

    function withTribunal() internal pure virtual override returns (bool) {
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

    /// R1-A3-1 / R2-A3-1: dust buys (1 wei: no fee; 100 wei: a 1-wei fee and no payouts) must not use
    /// up the opening exception; the real first buy still routes its payouts to the pool, and the buy
    /// after it pays sIMD, not claims. The rule is the PoolManager's IMD, not a flag.
    function test_aDustFirstBuyDoesNotConsumeTheFirstBuyException() public {
        assertEq(imd.balanceOf(address(pm)), 0, "fresh PoolManager");
        buy(carol, 1); // one wei: the IMD fee rounds to zero
        buy(carol, 100); // a 1-wei fee, payouts of zero
        assertLt(imd.balanceOf(address(pm)), hook.PAYOUT_RESERVE());
        vm.expectEmit(false, false, false, false, address(hook));
        emit PleaHook.PayoutsToPool(0);
        buy(bob, 100e18); // still the first fee-paying buy: payouts to liquidity, as accepted
        assertEq(pm.balanceOf(bob, _imdId()), 0, "bob was paid ERC-6909 claims");
        assertEq(pm.balanceOf(OWNER, _imdId()), 0, "the owner was paid claims");
        buy(alice, 100e18);
        assertGt(simd.byProject(alice, address(hook)), 0, "the next buy's cashback is sIMD");
        assertEq(pm.balanceOf(alice, _imdId()), 0, "no claims for the next buy");
    }

    /// R1-A3-2: an exact-output sell (the Letterbox's fee sale) pays the same 2% of the fill as an
    /// exact-input trade: the pool share is 0.25% of the fill, a quarter of the owner's 1%.
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
        assertApproxEqRel(pool * 4, owner, 0.002e18, "the pool share is not a quarter of the owner's");
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

    /// R3-A3-1 (High): a router that flash-takes the PoolManager's IMD inside its unlock must not be
    /// able to force the opening exception (payouts to the pool) or the claims path for its own buy.
    /// The hook measures the pool's own IMD, so the drained take simply fails and the swap reverts.
    function test_aFlashTakenPoolManagerCannotStripThePayouts() public {
        buy(alice, 2_000e18);
        skip(2 hours);
        FlashTakeRouter ft = new FlashTakeRouter(IPoolManager(address(pm)), hook, imd, plea);
        imd.mint(bob, 2_000e18);
        vm.startPrank(bob);
        imd.approve(address(ft), type(uint256).max);
        vm.expectRevert();
        ft.buyWithFlashTake(1_000e18, abi.encode(bob), true);
        // The same router without the take works: the revert above is the hook's take, not the router.
        ft.buyWithFlashTake(10e18, abi.encode(bob), false);
        vm.stopPrank();
        // The same buy without the take pays the owner, the pot and the cashback as usual.
        uint256 ownerBefore = imd.balanceOf(OWNER);
        uint256 potBefore = imd.balanceOf(address(seasons));
        buy(bob, 1_000e18);
        assertGt(imd.balanceOf(OWNER) - ownerBefore, 9.5e18, "the owner's 1%");
        assertGt(imd.balanceOf(address(seasons)) - potBefore, 2e18, "the pot's 0.25%");
        assertGt(simd.byProject(bob, address(hook)), 4e18, "the cashback");
    }

    /// R3-A1-1 (Medium): with the day-old reference in the slot the current hour would overwrite, a
    /// dust trade before the plea turned a down trend (0) into "no history" (5). The 48-slot ring keeps
    /// the reference through the current hour.
    function test_aDustTradeInTheCurrentHourDoesNotEvictTheDayOldReference() public {
        buy(alice, 50e18);
        uint256 h0 = vm.getBlockTimestamp() / 1 hours;
        // A checkpoint in every hour h0 + 2 .. h0 + 24, none in h0 + 1. Pleading in hour h0 + 25 looks
        // for h0 + 1, finds nothing, and must fall back to h0's checkpoint; with 25 slots the current
        // hour's first trade had just overwritten that slot ((h0 + 25) % 25 == h0 % 25).
        for (uint256 i = 2; i <= 24; ++i) {
            vm.warp((h0 + i) * 1 hours + 60);
            buy(bob, 1e18);
        }
        vm.warp((h0 + 25) * 1 hours + 60);
        buy(carol, 1e18); // the current hour's first trade
        assertGt(hook.price24hAgo(), 0, "the day-old reference was evicted");
        assertEq(hook.price24hAgo(), _ringPrice(h0), "the reference is h0's checkpoint");
    }

    function _ringPrice(uint256 hour) internal view returns (uint256 p) {
        (, p) = hook.ring(hour % 48);
    }

    /// R3-A2-2: a pending letter whose verdict can no longer arrive tells the writer to settle.
    function test_aStalePendingLetterSaysToSettle() public {
        buy(alice, 20e18);
        skip(1 days);
        buy(bob, 1e18);
        uint256 id = _letter(alice, "Fifteen percent for the dentist; the rest stays all season.");
        string memory s = letterbox.status(alice);
        assertTrue(vm.contains(s, "PENDING"), s);
        assertFalse(vm.contains(s, "call settle"), s);
        skip(gate.PENDING_EXPIRY() + 1);
        s = letterbox.status(alice);
        assertTrue(vm.contains(s, "no verdict can come now: call settle"), s);
        letterbox.settle(id);
    }

    /// R2-A3-2: after the death, zero-fill swaps inside the liquidity-free region (a 1-wei buy with a
    /// limit a hair toward the market) never pull refTick toward the drained tick; once a buy restores
    /// spot, the wall is placed against the market.
    function test_zeroFillSwapsInTheEmptyRegionDoNotDragTheReferenceTick() public {
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
        vm.stopPrank();
        assertEq(hook.currentTick(), limitTick);
        int24 ref0 = hook.refTick();
        // 20 blocks of zero-fill buys nudging the price one tick toward the market each time.
        for (uint256 i = 1; i <= 20; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            skip(12);
            int24 t = pz ? limitTick + int24(int256(i)) : limitTick - int24(int256(i));
            vm.prank(bob);
            router.buyExactInLimit(1, abi.encode(bob), TickMath.getSqrtPriceAtTick(t));
        }
        // The reference may still settle toward the last liquid tick, never toward the drained one.
        int24 ref1 = hook.refTick();
        assertTrue(pz ? ref1 >= ref0 : ref1 <= ref0, "zero-fill swaps dragged the reference tick");
        assertTrue(pz ? ref1 > limitTick + 3000 : ref1 < limitTick - 3000, "the reference followed the drained tick");
        vm.roll(vm.getBlockNumber() + 1);
        skip(1 hours);
        buy(bob, 50e18); // spot is back inside the market band
        vm.startPrank(alice);
        imd.approve(address(hook), type(uint256).max);
        hook.fundWall(10e18);
        vm.stopPrank();
        vm.prank(keeper);
        hook.rebalance();
        (int24 lo, int24 hi, uint128 liq) = hook.wall();
        assertGt(liq, 0, "no wall");
        int24 near = pz ? hi : lo;
        assertTrue(pz ? near > limitTick + 3000 : near < limitTick - 3000, "the wall was parked at the drained tick");
    }

    /// R2-A3-3: a price-limited partial fill through a router that cannot name its caller (no trader)
    /// refunds the unearned fee to the router instead of keeping it.
    function test_partialFillWithoutATraderRefundsTheRouter() public {
        buy(alice, 100e18);
        skip(DEADMAN + 1); // free trading: a buy needs no recipient
        uint160 limit = hook.currentSqrtPriceX96();
        bool pz = hook.pleaIsZero();
        // One tick of room in the buy's direction: the fill is a sliver of the 100 IMD requested.
        int24 t = hook.currentTick() + (pz ? int24(1) : int24(-1));
        limit = TickMath.getSqrtPriceAtTick(t);
        uint256 routerImd = imd.balanceOf(address(router));
        uint256 routerClaims = pm.balanceOf(address(router), _imdId());
        uint256 pool0 = hook.totalPoolFees();
        vm.prank(alice);
        router.buyExactInLimit(100e18, "", limit);
        uint256 refunded = imd.balanceOf(address(router)) - routerImd + pm.balanceOf(address(router), _imdId()) - routerClaims;
        assertGt(refunded, 1e18, "the unearned fee on the unfilled part came back to the router");
        assertLt(hook.totalPoolFees() - pool0, 0.1e18, "the surplus was kept as pool fees");
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
    // ---------------------------------------------------------------- round 4

    /// R4-A1-1: the trend reference is the newest older checkpoint within two days; one that only
    /// survived in a quiet ring reads as "no history".
    function test_aCheckpointOlderThanTwoDaysIsNoDayOldReference() public {
        buy(alice, 50e18);
        uint256 h0 = vm.getBlockTimestamp() / 1 hours;
        vm.warp((h0 + 60) * 1 hours + 60);
        buy(bob, 1e18); // the first trade in 60 hours
        assertGt(_ringPrice(h0), 0, "setup: h0's checkpoint is still in the ring");
        assertEq(hook.price24hAgo(), 0, "a 60-hour-old checkpoint is no day-old reference");
        vm.warp((h0 + 61) * 1 hours + 60);
        buy(bob, 1e18);
        vm.warp((h0 + 84) * 1 hours + 60);
        assertEq(hook.price24hAgo(), _ringPrice(h0 + 60), "exactly 24 hours old: the reference");
        vm.warp((h0 + 85) * 1 hours + 60);
        assertEq(hook.price24hAgo(), _ringPrice(h0 + 61), "the newest older one within two days");
    }

    /// R4-A3-1: after the death an exact-output trade stopped by a price limit would hand the swapper
    /// a short (even negative) output delta and the rest as a separate refund; it reverts instead,
    /// and a whole fill returns exactly the requested output.
    function test_aPriceLimitedExactOutputTradeRevertsInsteadOfAShortDelta() public {
        buy(alice, 500e18);
        skip(DEADMAN + 1);
        bool pz = hook.pleaIsZero();
        // One tick of room in the sell's direction: the fill is a sliver of the 100 IMD requested.
        uint160 limit = TickMath.getSqrtPriceAtTick(hook.currentTick() + (pz ? -int24(1) : int24(1)));
        vm.prank(alice);
        (bool ok, bytes memory ret) =
            address(router).call(abi.encodeCall(router.sellExactOutLimit, (100e18, abi.encode(alice), limit)));
        assertFalse(ok, "a price-limited exact-output trade must revert");
        assertEq(_hookReason(ret), PleaHook.PartialFill.selector, "the hook's PartialFill");
        uint256 before = imd.balanceOf(alice);
        vm.startPrank(alice);
        plea.approve(address(router), type(uint256).max);
        router.sellExactOutLimit(50e18, abi.encode(alice), 0);
        vm.stopPrank();
        assertEq(imd.balanceOf(alice) - before, 50e18, "a whole exact-output fill pays exactly the request");
    }

    /// R4-A3-2: the agreed opening rule (the owner buys 2 IMD right after seed) closes the opening
    /// exception although rounding leaves the pool a few wei under the 2 IMD reserve: the buy's own
    /// fee counts, so the next buy pays the owner, the pot and the cashback (as ERC-6909 claims while
    /// the PoolManager is short, as documented).
    function test_theOwnersTwoImdOpeningBuyClosesTheOpeningException() public {
        fund(OWNER);
        buy(OWNER, 2e18);
        assertLt(hook.imdInMarket() + hook.retainClaims(), hook.PAYOUT_RESERVE(), "setup: a few wei under the reserve");
        uint256 ownerBefore = imd.balanceOf(OWNER) + pm.balanceOf(OWNER, _imdId());
        uint256 potBefore = imd.balanceOf(address(seasons)) + pm.balanceOf(address(seasons), _imdId());
        buy(bob, 200e18);
        assertGt(imd.balanceOf(OWNER) + pm.balanceOf(OWNER, _imdId()) - ownerBefore, 1.9e18, "the owner's 1%");
        assertGt(
            imd.balanceOf(address(seasons)) + pm.balanceOf(address(seasons), _imdId()) - potBefore, 0.45e18, "the pot's 0.25%"
        );
        assertGt(simd.byProject(bob, address(hook)) + pm.balanceOf(bob, _imdId()), 0.9e18, "bob's 0.5% cashback");
    }

    /// R4-A2-2: the site's box asking for more than the balance leaves after the fee reserve is
    /// refused as FeeTooHigh, not with the token's error.
    function test_aPleaOfTheWholeBalanceIsRefusedAsFeeTooHigh() public {
        buy(alice, 200e18);
        uint256 bal = plea.balanceOf(alice);
        vm.prank(alice);
        vm.expectPartialRevert(Letterbox.FeeTooHigh.selector);
        letterbox.plead(bal, "Everything for the move; nothing stays behind.");
    }

    /// R4-A3-3: a credit that returns without pulling the cashback leaves no standing allowance over
    /// the hook's IMD.
    function test_aCreditThatPullsNothingLeavesNoAllowance() public {
        buy(alice, 100e18); // past the opening exception: this buy funds the PoolManager
        vm.etch(address(stacker), type(NoopStacker).runtimeCode);
        buy(bob, 100e18);
        assertEq(imd.allowance(address(hook), address(stacker)), 0, "no allowance stays after the credit");
    }

    /// @dev The hook error inside the PoolManager's WrappedError(hook, hookSelector, reason, HookCallFailed).
    function _hookReason(bytes memory ret) internal view returns (bytes4) {
        assertEq(bytes4(ret), CustomRevert.WrappedError.selector, "a wrapped hook error");
        bytes memory body = new bytes(ret.length - 4);
        for (uint256 i; i < body.length; ++i) body[i] = ret[i + 4];
        (address target, bytes4 hookSelector, bytes memory reason, bytes memory details) =
            abi.decode(body, (address, bytes4, bytes, bytes));
        assertEq(target, address(hook));
        assertEq(hookSelector, IHooks.afterSwap.selector);
        assertEq(bytes4(details), Hooks.HookCallFailed.selector);
        return bytes4(reason);
    }

    /// R5-A1-2: the profit bands compare exactly, with no rounded percentage: a gain just over an
    /// edge scores the next band (50% -> 12, 50.9% -> 10; 200% -> 10, 200.9% -> 8; 500% -> 8,
    /// 500.9% -> 6; 1,000% -> 6, 1,000.9% -> 4). The buy record and the price are pinned.
    function test_profitBandEdgesAreExact() public {
        address s = makeAddr("edgeSeller");
        uint256 held = 1_000_000e18;
        deal(address(plea), s, held);
        vm.mockCall(
            address(hook), abi.encodeWithSelector(hook.basisOf.selector, s), abi.encode(100e18, held, block.timestamp)
        );
        vm.mockCall(address(hook), abi.encodeWithSelector(hook.price24hAgo.selector), abi.encode(uint256(0)));
        uint256[8] memory values = [uint256(150e18), 150.9e18, 300e18, 300.9e18, 600e18, 600.9e18, 1100e18, 1100.9e18];
        uint8[8] memory points = [12, 10, 10, 8, 8, 6, 6, 4];
        for (uint256 i; i < 8; ++i) {
            // value = held * price / Q96, rounded down: round the price up so the value is not under it
            uint256 price = (values[i] * (1 << 96) + held - 1) / held;
            vm.mockCall(address(hook), abi.encodeWithSelector(hook.latestPrice.selector), abi.encode(price));
            // share 10%: 16; held since now: 0; no 24h history: 5
            assertEq(gate.factScore(s, held / 10), 16 + 0 + points[i] + 5, "profit band edge");
        }
    }

    /// R7-M-1: the delivery floor is 95% of the snapshot value after the hook's 2.25% sale fees, so an
    /// approved letter still sells when spot sits 4% under the hour's snapshot (the old gross floor
    /// refused anything past ~2.8%), and is still refused at 6%.
    function test_aLetterStillSellsAfterAFourPercentDip() public {
        buy(alice, 50e18);
        skip(2 hours);
        uint256 id = _letter(alice, "Twenty percent for the phone bill; the rest stays with me.");
        assertTrue(answer(id, 45), "verdict");
        uint256 p = hook.latestPrice();
        uint256 snap = vm.snapshotState();
        vm.mockCall(address(hook), abi.encodeWithSelector(PleaHook.latestPrice.selector), abi.encode(p * 106 / 100));
        vm.expectRevert();
        letterbox.deliver(id);
        vm.revertToState(snap);
        vm.mockCall(address(hook), abi.encodeWithSelector(PleaHook.latestPrice.selector), abi.encode(p * 104 / 100));
        uint256 out = letterbox.deliver(id);
        assertGt(out, 0, "sold");
    }

    /// The owner's 1% (2.25% in all): the delivery floor is 95% of the snapshot value after the hook's
    /// sale fees, 0.25% of the PLEA burned and 2% of the IMD out (`HOOK_SALE_FEE_BPS` 225). A snapshot
    /// that puts the floor a basis point above the real sale refuses it; a basis point below, it sells
    /// (counting only the old 2.0%, the floor would sit about 0.26% higher and refuse both).
    function test_theDeliveryFloorCountsTheHooksTwoAndAQuarterPercent() public {
        buy(alice, 50e18);
        skip(2 hours);
        uint256 id = _letter(alice, "Twenty percent for the phone bill; the rest stays with me.");
        assertTrue(answer(id, 45), "verdict");
        (,, uint256 amount,) = letterbox.escrowOf(id);
        uint256 snap = vm.snapshotState();
        // The real sale, with the floor out of the way (a 1-wei snapshot price).
        vm.mockCall(address(hook), abi.encodeWithSelector(PleaHook.latestPrice.selector), abi.encode(uint256(1)));
        uint256 out = letterbox.deliver(id);
        vm.revertToState(snap);
        vm.mockCall(
            address(hook),
            abi.encodeWithSelector(PleaHook.latestPrice.selector),
            abi.encode(_priceForFloor(amount, out * 10_001 / 10_000))
        );
        vm.expectRevert();
        letterbox.deliver(id);
        vm.revertToState(snap);
        vm.mockCall(
            address(hook),
            abi.encodeWithSelector(PleaHook.latestPrice.selector),
            abi.encode(_priceForFloor(amount, out * 9_999 / 10_000))
        );
        assertEq(letterbox.deliver(id), out, "sold, for the same IMD");
    }

    /// @dev The snapshot price whose delivery floor is `target`: amount x price x 95% x 97.75%.
    function _priceForFloor(uint256 amount, uint256 target) internal pure returns (uint256) {
        return target * 10_000 / 9_775 * 10_000 / 9_500 * (1 << 96) / amount;
    }

    /// R7-T-1: a seller who becomes excluded (accepts PLEA's ownership) while an objection to their
    /// approved plea is pending is never read as held.
    function test_aSellerExcludedWhileAnObjectionIsPendingIsNeverHeld() public {
        buy(alice, 50e18);
        skip(1 days);
        uint256 id = approvedPlea(alice, 45);
        address objector = makeAddr("objector");
        fund(objector);
        objectTo(objector, id, "That plea is boilerplate: the same three lines as every other sell this week.");
        (bool held,,) = tribunal.standing(id);
        assertTrue(held, "a pending objection holds the plea");
        vm.prank(OWNER);
        plea.transferOwnership(alice);
        vm.prank(alice);
        plea.acceptOwnership();
        (held,,) = tribunal.standing(id);
        assertFalse(held, "an excluded seller's plea is never held");
    }
}

/// @dev A Stacker whose credit succeeds without pulling anything (the round-4 allowance probe).
contract NoopStacker {
    function SIMD() external pure returns (address) {
        return address(0);
    }

    function credit(address, uint256) external {}
}

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

    /// R3-A2-1: an appeal letter whose fees pass the original-amount exception must still fit the
    /// balance with its escrow (the retry after a first appeal's fee sale), refused as FeeTooHigh
    /// rather than a raw token error. Mainnet fee path: an appeal buys 1.1 IMD of fees.
    function test_anAppealWhoseFeesDoNotFitTheBalanceIsRefusedAsFeeTooHigh() public {
        buy(bob, 50e18);
        address w = makeAddr("smallWriter");
        fund(w);
        buy(w, 3e18);
        holdAWeek(bob); // a week at a loss (no newer checkpoint): a 50% plea needs 43
        uint256 bal = plea.balanceOf(w);
        vm.prank(w);
        uint256 id = gate.submitSell(bal / 2, "Half for the move; the rest stays.");
        assertTrue(answer(id, 0), "verdict");
        vm.prank(w);
        (bool ok,) = address(letterbox).call(bytes("APPEAL The move will not wait; I keep the rest."));
        assertTrue(ok, "the first appeal fits: escrow + fees <= balance");
        uint256 a = gate.lastPleaOf(w);
        skip(gate.PENDING_EXPIRY() + 1); // no verdict: the appeal may be sent again
        letterbox.settle(a);
        uint256 left = plea.balanceOf(w);
        (, uint256 maxFeePlea) = letterbox.feesFor(true);
        assertGt(left / 2 + maxFeePlea, left, "setup: the retry no longer fits");
        vm.prank(w);
        bytes memory ret;
        (ok, ret) = address(letterbox).call(bytes("APPEAL The move will not wait; I keep the rest."));
        assertFalse(ok);
        assertEq(bytes4(ret), Letterbox.FeeTooHigh.selector, "refused as FeeTooHigh, not a token error");
    }

    /// R4-A2-1: the appeal's fee exception compares PLEA at two prices; with the fees' own 10% slack a
    /// small writer can still appeal by letter after the hourly snapshot fell by a few percent.
    function test_aSmallWriterCanAppealByLetterAfterThePriceFell() public {
        address[5] memory sellers = [bob, carol, makeAddr("seller3"), makeAddr("seller4"), makeAddr("seller5")];
        for (uint256 i = 2; i < 5; ++i) fund(sellers[i]);
        for (uint256 i; i < 5; ++i) buy(sellers[i], 150e18);
        buy(alice, 8.45e18);
        skip(1 days);
        buy(sellers[2], 1e18); // this hour's checkpoint
        uint256 p0 = hook.latestPrice();
        vm.prank(alice);
        (bool ok,) = address(letterbox).call(bytes("Fifteen percent for the phone bill; the rest stays with me."));
        assertTrue(ok, "the letter was refused");
        uint256 id = gate.lastPleaOf(alice);
        assertTrue(answer(id, 0), "verdict");
        // Five approved sales push the price down; the next hour's first trade checkpoints it.
        for (uint256 i; i < 5; ++i) {
            uint256 part = plea.balanceOf(sellers[i]) / 2;
            if (part > 2_500_000e18) part = 2_500_000e18; // the gate's cap
            vm.prank(sellers[i]);
            uint256 pid = gate.submitSell(part, "Part of it for the roof; the rest stays with me.");
            assertTrue(answer(pid, 45), "verdict");
            vm.startPrank(sellers[i]);
            plea.approve(address(gate), type(uint256).max);
            gate.executeSell(0);
            vm.stopPrank();
        }
        skip(1 hours);
        buy(sellers[2], 0.01e18);
        uint256 p1 = hook.latestPrice();
        assertLt(p1 * 100, p0 * 97, "setup: the snapshot fell by more than 3%");
        assertGt(p1 * 100, p0 * 90, "setup: but by less than 10%");
        vm.prank(alice);
        (ok,) = address(letterbox).call(bytes("APPEAL The phone is how I work; I keep the rest."));
        assertTrue(ok, "whoever could plead by letter can appeal by letter after a small price fall");
        assertTrue(gate.getPlea(gate.lastPleaOf(alice)).isAppeal);
    }
}

/// @dev A router that takes every IMD the PoolManager holds before its swap and repays it after
/// (v4 flash accounting), the round-3 audit's lever against a balance-based exception.
contract FlashTakeRouter {
    IPoolManager public pm;
    PleaHook public hook;
    IERC20 public imd;
    IERC20 public plea;

    constructor(IPoolManager pm_, PleaHook hook_, IERC20 imd_, IERC20 plea_) {
        pm = pm_;
        hook = hook_;
        imd = imd_;
        plea = plea_;
    }

    function buyWithFlashTake(uint256 imdIn, bytes memory hookData, bool takeAll) external {
        pm.unlock(abi.encode(msg.sender, imdIn, hookData, takeAll));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (address payer, uint256 imdIn, bytes memory hookData, bool takeAll) =
            abi.decode(raw, (address, uint256, bytes, bool));
        uint256 drained = takeAll ? imd.balanceOf(address(pm)) : 0;
        if (drained != 0) pm.take(Currency.wrap(address(imd)), address(this), drained);
        PoolKey memory key = hook.poolKey();
        bool pleaIsZero = hook.pleaIsZero();
        bool zeroForOne = !pleaIsZero;
        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(imdIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        );
        int128 imdDelta = pleaIsZero ? d.amount1() : d.amount0();
        uint256 amountIn = uint256(uint128(-imdDelta));
        pm.sync(Currency.wrap(address(imd)));
        imd.transferFrom(payer, address(pm), amountIn);
        if (drained != 0) imd.transfer(address(pm), drained);
        pm.settle();
        return "";
    }
}
