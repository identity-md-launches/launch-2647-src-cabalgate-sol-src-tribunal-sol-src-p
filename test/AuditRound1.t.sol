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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";

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
        assertGt(imd.balanceOf(OWNER) - ownerBefore, 7e18, "the owner's 0.75%");
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
