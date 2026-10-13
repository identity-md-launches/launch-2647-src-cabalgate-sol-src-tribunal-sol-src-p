// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {SepoliaFixture} from "./utils/SepoliaFixture.sol";
import {AdversarialTraderRouter} from "./utils/AdversarialTraderRouter.sol";
import {PleaHook} from "src/PleaHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract TraderFallbackFixture is SepoliaFixture {
    AdversarialTraderRouter internal unusualRouter;

    function setUp() public virtual override {
        super.setUp();
        unusualRouter =
            new AdversarialTraderRouter(IPoolManager(address(pm)), hook, IERC20(address(imd)), IERC20(address(plea)));
        for (uint256 i; i < users.length; ++i) {
            vm.startPrank(users[i]);
            imd.approve(address(unusualRouter), type(uint256).max);
            plea.approve(address(unusualRouter), type(uint256).max);
            vm.stopPrank();
        }
        // Seed real IMD backing before checking individual cashback recipients.
        buy(carol, 20e18);
    }

    function noRecipientError() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(PleaHook.RecipientRequired.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function endCabal() internal {
        vm.warp(uint256(gate.lastVerdictAt()) + gate.DEADMAN());
        assertFalse(gate.cabalAlive());
    }

    function assertNoRouterCredit() internal view {
        assertEq(simd.balanceOf(address(unusualRouter)), 0);
        assertEq(plea.balanceOf(address(unusualRouter)), 0);
        assertEq(imd.balanceOf(address(unusualRouter)), 0);
        (uint256 spent, uint256 held, uint256 at) = hook.basisOf(address(unusualRouter));
        assertEq(spent, 0);
        assertEq(held, 0);
        assertEq(at, 0);
    }
}

/// forge-config: default.fuzz.runs = 128
contract TraderFallbackAdversarialTest is TraderFallbackFixture {
    function test_msgSenderReceivesExactlyTheThirtyThousandGasBudget() public {
        assertEq(hook.MSG_SENDER_GAS(), 30_000);
        unusualRouter.configure(abi.encode(alice), 4);
        vm.prank(alice);
        uint256 received = unusualRouter.buyExactIn(1e18, "");
        assertGt(received, 0);
        assertGt(simd.balanceOf(alice), 0);
        (, uint256 held,) = hook.basisOf(alice);
        assertEq(held, received);
        assertNoRouterCredit();
    }

    function test_hookDataTakesPriorityEvenWhenRouterCannotAnswer() public {
        for (uint256 behavior = 1; behavior <= 5; ++behavior) {
            unusualRouter.configure(abi.encode(alice), behavior);
            uint256 before = plea.balanceOf(bob);
            vm.prank(alice, carol);
            unusualRouter.buyExactIn(1e18, abi.encode(bob));
            assertGt(plea.balanceOf(bob), before, "the explicit trader receives the live buy");
        }
        assertEq(plea.balanceOf(alice), 0);
        assertEq(simd.balanceOf(alice), 0);
        assertGt(simd.balanceOf(bob), 0);
        (, uint256 held,) = hook.basisOf(bob);
        assertEq(held, plea.balanceOf(bob));
        assertEq(unusualRouter.attemptedWrite(), 0);
        assertNoRouterCredit();
    }

    function test_revertingOutOfGasAndStateWritingRoutersCannotBlockDeadCabalBuys() public {
        uint256 before = imd.balanceOf(alice);
        uint256 supply = plea.totalSupply();
        for (uint256 behavior = 1; behavior <= 5; ++behavior) {
            if (behavior == 4) continue; // this mode returns a valid answer with the correct stipend
            unusualRouter.configure(abi.encode(alice), behavior);
            vm.expectRevert(noRecipientError());
            vm.prank(alice, bob);
            unusualRouter.buyExactIn(1e18, "");
        }
        assertEq(imd.balanceOf(alice), before, "refused buys do not collect a fee");
        assertEq(plea.totalSupply(), supply, "refused buys do not burn PLEA");
        endCabal();
        uint256 cashback = hook.totalCashback();
        uint256 stacked = simd.totalSupply();
        for (uint256 behavior = 1; behavior <= 5; ++behavior) {
            if (behavior == 4) continue;
            unusualRouter.configure(abi.encode(alice), behavior);
            vm.prank(alice, bob);
            assertGt(unusualRouter.buyExactIn(1e18, ""), 0);
        }
        assertEq(hook.totalCashback(), cashback);
        assertEq(simd.totalSupply(), stacked);
        (, uint256 aliceHeld,) = hook.basisOf(alice);
        (, uint256 originHeld,) = hook.basisOf(bob);
        assertEq(aliceHeld, 0);
        assertEq(originHeld, 0, "tx.origin cannot become the unresolved trader");
        assertEq(unusualRouter.attemptedWrite(), 0, "msgSender must run in a static context");
        assertNoRouterCredit();
    }

    function testFuzz_nonAddressLengthResponsesDoNotResolve(uint8 rawLength, bool dead) public {
        uint256 length = bound(rawLength, 0, 96);
        if (length == 32) length = 33;
        bytes memory response = new bytes(length);
        // Even a valid first address word cannot make a 33/64-byte response valid.
        if (length >= 32) {
            address who = bob;
            assembly ("memory-safe") { mstore(add(response, 32), who) }
        }
        unusualRouter.configure(response, 0);
        assertUnresolvedBuy(dead);
    }

    function testFuzz_dirtyRouterReturnCannotBeTruncatedIntoATrader(uint96 highBits, bool dead) public {
        highBits = uint96(bound(highBits, 1, type(uint96).max));
        unusualRouter.configure(abi.encode(uint256(uint160(bob)) | (uint256(highBits) << 160)), 0);
        assertUnresolvedBuy(dead);
    }

    function test_everyExcludedRouterResponseHasNoRecipientFallbackToOrigin() public {
        address[7] memory excluded = [
            address(0),
            address(unusualRouter),
            address(stacker),
            address(imd),
            address(simd),
            address(pm),
            address(hook)
        ];
        for (uint256 i; i < excluded.length; ++i) {
            unusualRouter.configure(abi.encode(excluded[i]), 0);
            assertUnresolvedBuy(false);
        }
        endCabal();
        for (uint256 i; i < excluded.length; ++i) {
            unusualRouter.configure(abi.encode(excluded[i]), 0);
            assertUnresolvedBuy(true);
        }
    }

    function testFuzz_nonAddressLengthHookDataFallsBackToRouter(uint8 rawLength) public {
        uint256 length = bound(rawLength, 0, 96);
        if (length == 32) length = 33;
        bytes memory data = new bytes(length);
        if (length >= 32) {
            address wrong = bob;
            assembly ("memory-safe") { mstore(add(data, 32), wrong) }
        }
        unusualRouter.configure(abi.encode(alice), 0);
        vm.prank(alice, bob);
        uint256 received = unusualRouter.buyExactIn(1e18, data);
        assertGt(received, 0);
        assertEq(plea.balanceOf(bob), 0);
        assertEq(simd.balanceOf(bob), 0);
        (, uint256 held,) = hook.basisOf(alice);
        assertEq(held, received);
        assertNoRouterCredit();
    }

    function test_successThenUnresolvedThenNewTraderDoesNotLeakTransientIdentity() public {
        endCabal();
        unusualRouter.configure(abi.encode(alice), 0);
        vm.prank(alice);
        unusualRouter.buyExactIn(1e18, "");
        (uint256 spent, uint256 held, uint256 at) = hook.basisOf(alice);
        uint256 cashback = hook.totalCashback();
        unusualRouter.configure(abi.encode(alice), 2);
        vm.prank(bob, alice);
        unusualRouter.buyExactIn(1e18, "");
        (uint256 spentAfter, uint256 heldAfter, uint256 atAfter) = hook.basisOf(alice);
        assertEq(spentAfter, spent);
        assertEq(heldAfter, held);
        assertEq(atAfter, at);
        assertEq(hook.totalCashback(), cashback);
        unusualRouter.configure(abi.encode(bob), 0);
        vm.prank(bob);
        uint256 bobReceived = unusualRouter.buyExactIn(1e18, "");
        (, uint256 bobHeld,) = hook.basisOf(bob);
        assertEq(bobHeld, bobReceived, "only the identified buy enters Bob's basis");
        assertGt(plea.balanceOf(bob), bobHeld, "the unresolved buy still delivered tokens");
        assertNoRouterCredit();
    }

    function test_partialBuyWithoutTraderKeepsBothCashbackAndImdFeeSurplusForPool() public {
        endCabal();
        uint160 spot = hook.currentSqrtPriceX96();
        uint160 limit = hook.pleaIsZero() ? spot + spot / 200 : spot - spot / 200;
        uint256 state = vm.snapshotState();
        uint256 poolBefore = hook.totalPoolFees();
        uint256 cashbackBefore = hook.totalCashback();
        uint256 claimsBefore = hook.retainClaims();
        uint256 sharesBefore = simd.balanceOf(alice);
        vm.recordLogs();
        vm.prank(alice);
        uint256 resolvedOut = unusualRouter.buyExactInLimit(500e18, abi.encode(alice), limit);
        uint256 refund;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == PleaHook.FeeRefunded.selector) {
                (address currency, uint256 amount, bool asClaims) = abi.decode(logs[i].data, (address, uint256, bool));
                assertEq(currency, address(imd));
                assertFalse(asClaims, "the funded pool can pay this refund as tokens");
                refund += amount;
            }
        }
        assertGt(refund, 0, "price limit must actually cause a partial fill");
        uint256 resolvedCashback = hook.totalCashback() - cashbackBefore;
        uint256 resolvedPoolFee = hook.totalPoolFees() - poolBefore;
        uint256 resolvedClaims = hook.retainClaims() - claimsBefore;
        uint256 resolvedWalletImd = imd.balanceOf(alice);
        assertGt(resolvedCashback, 0);
        assertTrue(vm.revertToState(state));

        unusualRouter.configure(abi.encode(address(0)), 0);
        vm.prank(alice, bob);
        uint256 unresolvedOut = unusualRouter.buyExactInLimit(500e18, "", limit);
        assertEq(unresolvedOut, resolvedOut, "identity does not change the pool fill");
        assertEq(hook.totalPoolFees() - poolBefore, resolvedPoolFee + resolvedCashback + refund);
        assertEq(hook.retainClaims() - claimsBefore, resolvedClaims + resolvedCashback + refund);
        assertEq(pm.balanceOf(address(hook), uint256(uint160(address(imd)))), hook.retainClaims());
        assertEq(hook.totalCashback(), cashbackBefore);
        assertEq(simd.balanceOf(alice), sharesBefore);
        assertEq(imd.balanceOf(alice), resolvedWalletImd - refund);
        (, uint256 held,) = hook.basisOf(alice);
        assertEq(held, 0);
        assertNoRouterCredit();
    }

    function test_gateSaleAlwaysNamesSellerEvenWhenRelayedByLetterboxRunner() public {
        buy(alice, 20e18);
        vm.prank(alice);
        letterbox.letter("A fifth for repairs; I keep the rest through the season.");
        uint256 id = gate.lastPleaOf(alice);
        assertTrue(answer(id, 45));
        uint256 shares = simd.balanceOf(alice);
        uint256 runnerShares = simd.balanceOf(keeper);
        vm.recordLogs();
        vm.prank(keeper, bob);
        letterbox.deliver(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == PleaHook.FeesTaken.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), alice);
                (bool isBuy,,,,) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256));
                assertFalse(isBuy);
                found = true;
            }
        }
        assertTrue(found, "the real gate sale must have charged a fee");
        assertGt(simd.balanceOf(alice), shares);
        assertEq(simd.balanceOf(keeper), runnerShares);
        assertEq(simd.balanceOf(address(gate)), 0);
        assertEq(simd.balanceOf(address(letterbox)), 0);
        assertEq(simd.balanceOf(bob), 0);
        assertEq(imd.balanceOf(keeper), 0.25e18, "runner receives only the agreed delivery tip");
    }

    function assertUnresolvedBuy(bool dead) internal {
        if (dead && gate.cabalAlive()) endCabal();
        uint256 cash = hook.totalCashback();
        uint256 shares = simd.totalSupply();
        uint256 before = imd.balanceOf(alice);
        uint256 supply = plea.totalSupply();
        if (!dead) vm.expectRevert(noRecipientError());
        vm.prank(alice, bob);
        uint256 received = unusualRouter.buyExactIn(1e18, "");
        if (dead) {
            assertGt(received, 0);
        } else {
            assertEq(imd.balanceOf(alice), before);
            assertEq(plea.totalSupply(), supply);
        }
        assertEq(hook.totalCashback(), cash);
        assertEq(simd.totalSupply(), shares);
        (, uint256 aliceHeld,) = hook.basisOf(alice);
        (, uint256 bobHeld,) = hook.basisOf(bob);
        assertEq(aliceHeld, 0);
        assertEq(bobHeld, 0);
        assertNoRouterCredit();
    }
}

/// forge-config: default.fuzz.runs = 128
contract TraderFallbackAdversarialPleaZeroTest is TraderFallbackAdversarialTest {
    function pleaFirst() internal pure override returns (bool) {
        return true;
    }
}
