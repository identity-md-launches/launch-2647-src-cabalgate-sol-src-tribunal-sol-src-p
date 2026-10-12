// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {MsgSenderRouter} from "./utils/Mocks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// imd/acc's trader rule in the hook: the cashback and the buy record go to the trader named in
/// hookData, else to the wallet the router acts for (`msgSender()`), else to a plain-wallet sender;
/// never to a router. With no trader the trade still goes through, without cashback.
contract TraderResolutionTest is Fixture {
    MsgSenderRouter msr;

    function setUp() public virtual override {
        super.setUp();
        msr = new MsgSenderRouter(IPoolManager(address(pm)), hook, IERC20(address(imd)), IERC20(address(plea)));
        for (uint256 i; i < 2; ++i) {
            address a = i == 0 ? alice : bob;
            vm.startPrank(a);
            imd.approve(address(msr), type(uint256).max);
            plea.approve(address(msr), type(uint256).max);
            vm.stopPrank();
        }
        buy(carol, 20e18);
    }

    function _die() internal {
        vm.warp(uint256(gate.lastVerdictAt()) + gate.DEADMAN() + 1);
        assertFalse(gate.cabalAlive());
    }

    function test_hookDataNamesTheTrader() public {
        uint256 shares = simd.balanceOf(alice);
        uint256 got = buy(alice, 10e18);
        assertGt(got, 0);
        assertGt(simd.balanceOf(alice), shares, "cashback stacked for the named trader");
        (, uint256 held,) = hook.basisOf(alice);
        assertEq(held, got, "buy record for the named trader");
    }

    function test_routerCallerIsTheTraderWithoutHookData() public {
        uint256 shares = simd.balanceOf(alice);
        uint256 before = plea.balanceOf(alice);
        vm.prank(alice);
        uint256 out = msr.swap(true, 10e18, "");
        assertEq(out, 0, "the hook delivered the PLEA itself while the Cabal lives");
        uint256 got = plea.balanceOf(alice) - before;
        assertGt(got, 0, "alice received the PLEA");
        assertEq(plea.balanceOf(address(msr)), 0, "nothing stuck in the router");
        assertGt(simd.balanceOf(alice), shares, "cashback stacked for the router's caller");
        assertEq(simd.balanceOf(address(msr)), 0, "never for the router");
        (, uint256 held,) = hook.basisOf(alice);
        assertEq(held, got);
    }

    function test_invalidHookDataFallsBackToTheRouterCaller() public {
        address[6] memory bad = [
            address(stacker),
            address(imd),
            address(simd),
            address(hook),
            address(pm),
            address(msr) // the sender itself
        ];
        for (uint256 i; i < bad.length; ++i) {
            uint256 shares = simd.balanceOf(alice);
            vm.prank(alice);
            msr.swap(true, 1e18, abi.encode(bad[i]));
            assertGt(simd.balanceOf(alice), shares, "the caller, not the invalid name");
            assertEq(simd.balanceOf(bad[i]), 0);
        }
    }

    function test_routerWithoutMsgSenderNeedsHookDataWhileTheCabalLives() public {
        vm.startPrank(alice);
        vm.expectRevert(); // v4 wraps RecipientRequired
        router.buyExactIn(1e18, "");
        vm.expectRevert();
        router.buyExactIn(1e18, abi.encode(address(stacker)));
        vm.stopPrank();
    }

    function test_noTraderAfterDeathSellGoesThroughWithoutCashback() public {
        _die();
        uint256 amount = plea.balanceOf(carol) / 4;
        uint256 cashback = hook.totalCashback();
        uint256 owner0 = hook.totalOwnerFees();
        uint256 pool0 = hook.totalPoolFees();
        uint256 supply = simd.totalSupply();
        (, uint256 held,) = hook.basisOf(carol);
        vm.startPrank(carol);
        plea.approve(address(router), type(uint256).max);
        uint256 out = router.sellExactIn(amount, "");
        vm.stopPrank();
        assertGt(out, 0, "the sale went through");
        assertEq(hook.totalCashback(), cashback, "no cashback without a trader");
        assertEq(simd.totalSupply(), supply, "nothing stacked, not for the router either");
        assertEq(imd.balanceOf(address(router)), 0, "no plain IMD to the router");
        (, uint256 heldAfter,) = hook.basisOf(carol);
        assertEq(heldAfter, held, "no buy record touched");
        // After death the prize share joins the pool: pool = 0.25 + 0.25 + the skipped 0.5 = 2x owner.
        assertApproxEqAbs(hook.totalPoolFees() - pool0, 2 * (hook.totalOwnerFees() - owner0), 2);
    }

    function test_noTraderAfterDeathBuyGoesThroughWithoutCashback() public {
        _die();
        uint256 cashback = hook.totalCashback();
        uint256 before = plea.balanceOf(alice);
        vm.prank(alice);
        uint256 got = router.buyExactIn(5e18, "");
        assertGt(got, 0);
        assertEq(plea.balanceOf(alice) - before, got, "plain v4 accounting delivers the PLEA");
        assertEq(hook.totalCashback(), cashback, "no cashback without a trader");
        (, uint256 held,) = hook.basisOf(alice);
        assertEq(held, 0, "no buy record without a trader");
    }

    function test_routerCallerStillCreditedAfterDeath() public {
        _die();
        uint256 shares = simd.balanceOf(bob);
        vm.prank(bob);
        uint256 out = msr.swap(true, 5e18, "");
        assertGt(out, 0, "after death the router takes the PLEA for its caller");
        assertGt(simd.balanceOf(bob), shares);
    }

    function test_feeSurplusWithoutATraderIsBurnedOrKeptForThePool() public {
        _die();
        uint256 burned = hook.totalBurned();
        // A partial fill: the PLEA-side fee was charged on the requested amount; the surplus has no
        // trader to go back to and is burned.
        uint160 spot = hook.currentSqrtPriceX96();
        uint160 limit = hook.pleaIsZero() ? spot - spot / 200 : spot + spot / 200;
        vm.startPrank(carol);
        plea.approve(address(router), type(uint256).max);
        router.sellExactInLimit(plea.balanceOf(carol), "", limit);
        vm.stopPrank();
        assertGt(hook.totalBurned(), burned);
        assertEq(plea.balanceOf(address(hook)), 0, "the hook keeps no PLEA");
    }
}
