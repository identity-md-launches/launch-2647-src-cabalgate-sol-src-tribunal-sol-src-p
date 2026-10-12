// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SepoliaFixture} from "./utils/SepoliaFixture.sol";
import {BuyRouter} from "./utils/Mocks.sol";
import {PleaHook} from "src/PleaHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// forge-config: default.fuzz.runs = 256
contract HookAdversarialTest is SepoliaFixture {
    function test_zeroBuyRevertsAndOneWeiBuyConservesSupply() public {
        uint256 supply = plea.totalSupply();
        uint256 quoteBefore = imd.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        router.buyExactIn(0, abi.encode(alice));
        assertEq(plea.totalSupply(), supply);
        uint256 bought = buy(alice, 1);
        assertGt(bought, 0);
        assertEq(imd.balanceOf(alice), quoteBefore - 1);
        assertEq(plea.totalSupply() + hook.totalBurned(), supply);
        assertEq(
            plea.balanceOf(alice) + plea.balanceOf(address(pm)) + plea.balanceOf(address(distributor))
                + plea.balanceOf(address(seasons)),
            plea.totalSupply()
        );
    }

    function test_hookCallbacksRejectCallersAndForeignPools() public {
        PoolKey memory key = hook.poolKey();
        SwapParams memory params = SwapParams(!hook.pleaIsZero(), -int256(1e18), TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(PleaHook.NotPoolManager.selector);
        hook.beforeSwap(alice, key, params, abi.encode(alice));
        vm.expectRevert(PleaHook.NotPoolManager.selector);
        hook.afterSwap(alice, key, params, BalanceDelta.wrap(0), "");
        key.fee = 1;
        vm.prank(address(pm));
        vm.expectRevert(PleaHook.InvalidPool.selector);
        hook.beforeSwap(alice, key, params, abi.encode(alice));
        vm.prank(address(pm));
        vm.expectRevert(PleaHook.InvalidPool.selector);
        hook.afterSwap(alice, key, params, BalanceDelta.wrap(0), "");
    }

    function test_onlyHookMayInitializeOrAddLiquidity() public {
        PoolKey memory key = hook.poolKey();
        vm.prank(address(pm));
        vm.expectRevert(PleaHook.InitializationRestrictedToHook.selector);
        hook.beforeInitialize(alice, key, 0);
        vm.prank(address(pm));
        vm.expectRevert(PleaHook.LiquidityRestrictedToHook.selector);
        hook.beforeAddLiquidity(alice, key, ModifyLiquidityParams(-60, 60, 1, bytes32(0)), "");
        vm.prank(address(pm));
        assertEq(hook.beforeInitialize(address(hook), key, 0), IHooks.beforeInitialize.selector);
        vm.prank(address(pm));
        assertEq(
            hook.beforeAddLiquidity(address(hook), key, ModifyLiquidityParams(-60, 60, 1, bytes32(0)), ""),
            IHooks.beforeAddLiquidity.selector
        );
    }

    function test_seedAndUnlockAreOneShotAndOnlyAuthorizedContextsWork() public {
        vm.expectRevert(PleaHook.NotLauncher.selector);
        hook.seed();
        vm.prank(address(launch));
        vm.expectRevert(PleaHook.AlreadySeeded.selector);
        hook.seed();
        vm.expectRevert(PleaHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint8(3), bytes("")));
        vm.prank(address(pm));
        vm.expectRevert(PleaHook.CallbackNotExpected.selector);
        hook.unlockCallback(abi.encode(uint8(3), bytes("")));
        assertTrue(hook.seeded());
        assertEq(hook.launchedAt(), T0);
    }

    function test_wallFundingCannotCreateUnbackedReserveWhenTransferFails() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(hook), uint256(0), 1e18)
        );
        hook.fundWall(1e18);
        assertEq(hook.retainedImd(), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        vm.expectRevert(PleaHook.RebalanceNotNeeded.selector);
        hook.rebalance();
        vm.startPrank(alice);
        imd.approve(address(hook), type(uint256).max);
        hook.fundWall(0);
        hook.fundWall(1);
        vm.stopPrank();
        assertEq(hook.retainedImd(), 1);
        assertFalse(hook.pendingRebalance());
    }

    function test_rebalancePaysNoTipAndDeploysTheWholeReserve() public {
        vm.startPrank(alice);
        imd.approve(address(hook), type(uint256).max);
        hook.fundWall(200e18);
        vm.stopPrank();
        uint256 reserve = hook.retainedImd();
        vm.prank(keeper);
        hook.rebalance();
        assertEq(imd.balanceOf(keeper), 0, "no keeper tip");
        assertGe(hook.retainedImd() + hook.wallImd(), reserve, "the whole reserve is kept or deployed");
        assertEq(imd.balanceOf(address(hook)), hook.retainedImd());
    }

    function test_realCreditBudgetMustBeAffordableAndExhaustedCreditFallsBack() public {
        assertEq(hook.creditGas(), 1300000);
        buy(bob, 50e18);
        bytes memory data = abi.encodeCall(BuyRouter.buyExactIn, (10e18, abi.encode(alice)));
        uint256 balance = imd.balanceOf(alice);
        vm.prank(alice);
        (bool ok,) = address(router).call{gas: 2_000_000}(data);
        assertFalse(ok);
        assertEq(imd.balanceOf(alice), balance);
        assertEq(plea.balanceOf(alice), 0);
        stacker.setBurnAllGas(true);
        uint256 cashback = hook.totalCashback();
        vm.prank(alice);
        (ok,) = address(router).call{gas: 5_000_000}(data);
        assertTrue(ok, "a reverting credit must leave gas for the plain payout");
        uint256 paidPlain = hook.totalCashback() - cashback;
        assertGt(paidPlain, 0);
        assertEq(imd.balanceOf(alice), balance - 10e18 + paidPlain);
        assertEq(simd.balanceOf(alice), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    function test_partialFillRefundChargesOnlyRealizedImdAndKeepsCostBasisCorrect() public {
        buy(bob, 50e18); // enough quote to pay the refund in ERC-20
        uint256 before = imd.balanceOf(alice);
        uint256 ownerBefore = imd.balanceOf(OWNER);
        uint256 prizeBefore = imd.balanceOf(address(seasons));
        uint256 cashbackBefore = hook.totalCashback();
        uint256 rate = hook.IMD_FEE_BPS();
        uint160 limit = nearLimit();
        vm.prank(alice);
        uint256 bought = router.buyExactInLimit(1000e18, abi.encode(alice), limit);
        uint256 spent = before - imd.balanceOf(alice);
        assertGt(bought, 0);
        assertLt(spent, 1000e18, "price-limited swap must refund unearned specified-side fees");
        assertEq(pm.balanceOf(alice, uint256(uint160(address(imd)))), 0);
        (uint256 basis, uint256 held,) = hook.basisOf(alice);
        assertEq(basis, spent);
        assertEq(held, plea.balanceOf(alice));
        // Remove the fee from the observed gross cost, allowing one wei for integer inversion.
        uint256 fill = spent * 10000 / (10000 + rate);
        assertApproxEqAbs(imd.balanceOf(OWNER) - ownerBefore, fill * 50 / 10000, 1);
        assertApproxEqAbs(imd.balanceOf(address(seasons)) - prizeBefore, fill * 25 / 10000, 1);
        assertApproxEqAbs(hook.totalCashback() - cashbackBefore, fill * 50 / 10000, 1);
    }

    function test_firstPartialFillRefundIsBackedByRedeemableQuoteClaims() public {
        uint256 before = imd.balanceOf(alice);
        uint160 limit = nearLimit();
        vm.prank(alice);
        uint256 bought = router.buyExactInLimit(1000e18, abi.encode(alice), limit);
        uint256 claims = pm.balanceOf(alice, uint256(uint160(address(imd))));
        assertGt(bought, 0);
        assertGt(claims, 0, "an empty pool cannot pay a cash refund before settlement");
        (uint256 basis, uint256 held,) = hook.basisOf(alice);
        assertEq(before - imd.balanceOf(alice) - claims, basis);
        assertEq(held, plea.balanceOf(alice));
        assertGe(imd.balanceOf(address(pm)), claims + hook.retainClaims());
        assertEq(pm.balanceOf(alice, uint256(uint160(address(plea)))), 0);
    }

    function testFuzz_immediateRoundTripCannotProfitIncludingCashback(uint256 raw) public {
        vm.warp(uint256(gate.lastVerdictAt()) + 118800);
        uint256 amount = bound(raw, 1e15, 5000e18);
        uint256 before = imd.balanceOf(alice);
        buy(alice, amount);
        uint256 bought = plea.balanceOf(alice);
        vm.startPrank(alice);
        plea.approve(address(router), bought);
        router.sellExactIn(bought, abi.encode(alice));
        vm.stopPrank();
        assertLe(imd.balanceOf(alice) + simd.balanceOf(alice), before, "round trip created economic value");
        assertEq(plea.balanceOf(address(hook)), 0);
        assertEq(plea.balanceOf(address(router)), 0);
        assertEq(imd.balanceOf(address(seasons)), 0, "no new prize fees after death");
    }

    function test_exactOutputBuyWorksAfterDeathAndKeepsAllAccountingSettled() public {
        buy(bob, 50e18);
        vm.warp(uint256(gate.lastVerdictAt()) + 118800);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = router.buyExactOut(10_000e18, abi.encode(alice));
        assertEq(plea.balanceOf(alice), 10_000e18);
        assertEq(before - imd.balanceOf(alice), paid);
        assertEq(plea.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(hook)), hook.retainedImd());
        assertEq(pm.balanceOf(address(hook), uint256(uint160(address(imd)))), hook.retainClaims());
    }

    function nearLimit() internal view returns (uint160) {
        int24 tick = hook.currentTick();
        return TickMath.getSqrtPriceAtTick(hook.pleaIsZero() ? tick + 60 : tick - 60);
    }
}

/// forge-config: default.fuzz.runs = 256
contract HookAdversarialPleaZeroTest is HookAdversarialTest {
    function pleaFirst() internal pure override returns (bool) {
        return true;
    }
}

/// forge-config: default.fuzz.runs = 256
contract LaunchFeeBoundaryTest is SepoliaFixture {
    function afterSeed() internal override {}

    function test_launchFeeHasExactStartMidpointAndEndValues() public {
        assertEq(hook.launchExtraBps(), 7000);
        vm.warp(T0 + 45 minutes);
        assertEq(hook.launchExtraBps(), 3500);
        vm.warp(T0 + 90 minutes - 1);
        assertEq(hook.launchExtraBps(), 1);
        vm.warp(T0 + 90 minutes);
        assertEq(hook.launchExtraBps(), 0);
    }

    function test_largeLaunchBuyRollsBackAndSucceedsAtWindowEnd() public {
        uint256 supply = plea.totalSupply();
        uint256 balance = imd.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(); // v4 wraps the hook's BuyTooLarge error
        router.buyExactIn(1000e18, abi.encode(alice));
        assertEq(plea.totalSupply(), supply);
        assertEq(imd.balanceOf(alice), balance);
        assertEq(hook.totalPoolFees(), 0);
        vm.warp(T0 + 90 minutes);
        assertGt(buy(alice, 1000e18), 5_000_000e18);
    }

    function testFuzz_launchFeeOnlyFallsWithTime(uint256 first, uint256 second) public {
        uint256 a = bound(first, 0, 90 minutes);
        uint256 b = bound(second, a, 90 minutes + 1 days);
        vm.warp(T0 + a);
        uint256 early = hook.launchExtraBps();
        vm.warp(T0 + b);
        uint256 late = hook.launchExtraBps();
        assertLe(late, early);
        assertLe(early, 7000);
        if (b >= 90 minutes) assertEq(late, 0);
    }
}
