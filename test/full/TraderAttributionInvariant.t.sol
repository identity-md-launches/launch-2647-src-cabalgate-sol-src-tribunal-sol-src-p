// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TraderFallbackFixture} from "./TraderFallbackAdversarial.t.sol";
import {AdversarialTraderRouter} from "../utils/AdversarialTraderRouter.sol";
import {MockIMD, MockSIMD} from "../utils/Mocks.sol";
import {PLEA} from "src/PLEA.sol";
import {PleaHook} from "src/PleaHook.sol";
import {CabalGate} from "src/CabalGate.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";

/// @dev The independent ledger assigns actual delivered tokens to the specified beneficiary.
/// Router response, hookData, payer and tx.origin vary independently. Expected reverts are exact;
/// unexpected reverts fail the campaign instead of silently discarding difficult sequences.
contract TraderAttributionHandler is Test {
    PLEA public immutable token;
    CabalGate public immutable gate;
    PleaHook public immutable hook;
    MockIMD public immutable imd;
    MockSIMD public immutable simd;
    AdversarialTraderRouter public immutable router;
    IPoolManager public immutable manager;
    address[3] public actors;
    uint256[3] public attributedBuys;
    uint256[3] public walletReceipts;
    uint256 public accepted;
    uint256 public refused;
    uint256 public unresolved;
    uint256 public redirected;
    uint256 public plainCashback;
    bool public dead;

    struct Snapshot {
        uint256[3] balances;
        uint256[3] quote;
        bytes32[3] basis;
        uint256 cashback;
        uint256 supply;
    }

    constructor(
        PLEA token_,
        CabalGate gate_,
        PleaHook hook_,
        MockIMD imd_,
        MockSIMD simd_,
        AdversarialTraderRouter router_,
        address[3] memory actors_
    ) {
        token = token_;
        gate = gate_;
        hook = hook_;
        imd = imd_;
        simd = simd_;
        router = router_;
        manager = hook_.poolManager();
        actors = actors_;
        for (uint256 i; i < 3; ++i) {
            (, attributedBuys[i],) = hook_.basisOf(actors_[i]);
            walletReceipts[i] = token_.balanceOf(actors_[i]);
        }
    }

    function buy(uint256 payerSeed, uint256 dataSeed, uint256 responseSeed, uint256 rawAmount) external {
        uint256 payerIndex = payerSeed % 3;
        address payer = actors[payerIndex];
        address other = actors[(payerIndex + 1) % 3];
        address expected = configureResponse(responseSeed % 12, payer, other);
        bytes memory data;
        uint256 how = dataSeed % 6;
        if (how == 0) {
            data = abi.encode(other);
            expected = other;
        } else if (how == 1) {
            data = "";
        } else if (how == 2) {
            data = abi.encode(address(0));
        } else if (how == 3) {
            data = abi.encode(uint256(uint160(other)) | (1 << 200));
        } else if (how == 4) {
            data = new bytes(31);
        } else {
            data = abi.encode(address(simd));
        }

        uint256 amount = bound(rawAmount, 1e15, 2e18);
        bool live = gate.cabalAlive();
        Snapshot memory before = snapshot();
        if (live && expected == address(0)) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.beforeSwap.selector,
                    abi.encodeWithSelector(PleaHook.RecipientRequired.selector),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
        }
        vm.prank(payer, actors[(payerIndex + 2) % 3]);
        router.buyExactIn(amount, data);
        if (live && expected == address(0)) {
            ++refused;
            assertEq(token.totalSupply(), before.supply);
            assertEq(hook.totalCashback(), before.cashback);
            for (uint256 i; i < 3; ++i) {
                assertEq(token.balanceOf(actors[i]), before.balances[i]);
                assertEq(quoteWealth(actors[i]), before.quote[i]);
                assertEq(basisHash(actors[i]), before.basis[i]);
            }
            return;
        }

        ++accepted;
        if (expected == address(0)) ++unresolved;
        if (expected != address(0) && expected != payer) ++redirected;
        address receiver = live ? expected : payer;
        uint256 received = token.balanceOf(receiver);
        uint256 cashback = hook.totalCashback() - before.cashback;
        if (expected == address(0)) assertEq(cashback, 0);
        else assertGt(cashback, 0, "a resolved funded buy must earn cashback");
        for (uint256 i; i < 3; ++i) {
            if (actors[i] == receiver) {
                received -= before.balances[i];
                assertGt(received, 0);
                walletReceipts[i] += received;
            } else {
                assertEq(token.balanceOf(actors[i]), before.balances[i], "PLEA delivered to another actor");
            }
        }
        for (uint256 i; i < 3; ++i) {
            if (actors[i] == expected) attributedBuys[i] += received;
            else assertEq(basisHash(actors[i]), before.basis[i], "unrelated trader's basis changed");
            // sIMD and redeemable claims are included so both credit modes count as actual payments.
            assertEq(
                quoteWealth(actors[i]) + (i == payerIndex ? amount : 0),
                before.quote[i] + (actors[i] == expected ? cashback : 0),
                "cashback recipient or input accounting"
            );
        }
        if (simd.paused()) plainCashback += cashback;
    }

    function configureResponse(uint256 mode, address payer, address other) internal returns (address expected) {
        bytes memory response;
        uint256 behavior;
        if (mode == 0 || mode == 10) {
            response = abi.encode(payer);
            expected = payer;
        } else if (mode == 1) {
            response = abi.encode(other);
            expected = other;
        } else if (mode == 2) {
            response = abi.encode(address(router));
        } else if (mode == 3) {
            response = abi.encode(address(manager));
        } else if (mode == 4) {
            response = abi.encode(uint256(uint160(other)) | (1 << 200));
        } else if (mode == 5) {
            response = new bytes(31);
        } else if (mode == 6) {
            response = abi.encode(other, uint256(0));
        } else {
            response = abi.encode(payer);
        }
        if (mode >= 7) behavior = mode - 6; // revert, gas exhaustion, state write, exact budget, too much gas
        router.configure(response, behavior);
    }

    function advance(uint256 raw) external {
        vm.warp(vm.getBlockTimestamp() + bound(raw, 1, 3 hours));
        if (dead) assertFalse(gate.cabalAlive());
        dead = !gate.cabalAlive();
    }

    function pauseVault(bool paused) external {
        simd.setPaused(paused);
    }

    function quoteWealth(address who) internal view returns (uint256) {
        return imd.balanceOf(who) + simd.balanceOf(who) + manager.balanceOf(who, uint256(uint160(address(imd))));
    }

    function basisHash(address who) internal view returns (bytes32) {
        (uint256 spent, uint256 held, uint256 at) = hook.basisOf(who);
        return keccak256(abi.encode(spent, held, at));
    }

    function snapshot() internal view returns (Snapshot memory s) {
        for (uint256 i; i < 3; ++i) {
            s.balances[i] = token.balanceOf(actors[i]);
            s.quote[i] = quoteWealth(actors[i]);
            s.basis[i] = basisHash(actors[i]);
        }
        s.cashback = hook.totalCashback();
        s.supply = token.totalSupply();
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract TraderAttributionInvariantTest is TraderFallbackFixture {
    TraderAttributionHandler internal handler;
    uint256 internal startingSupply;
    uint256 internal startingBurned;

    function setUp() public virtual override {
        super.setUp();
        handler = new TraderAttributionHandler(plea, gate, hook, imd, simd, unusualRouter, [alice, bob, carol]);
        startingSupply = plea.totalSupply();
        startingBurned = hook.totalBurned();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.pauseVault.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_tokensAndBuyRecordsFollowTheirIndependentRecipients() public view {
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            (, uint256 held,) = hook.basisOf(actor);
            assertEq(held, handler.attributedBuys(i), "basis must include only this trader's identified buys");
            assertEq(plea.balanceOf(actor), handler.walletReceipts(i));
        }
    }

    function invariant_supplyAndPoolReserveRemainBacked() public view {
        uint256 sum = plea.balanceOf(address(pm)) + plea.balanceOf(address(seasons))
            + plea.balanceOf(address(distributor)) + plea.balanceOf(address(hook));
        for (uint256 i; i < 3; ++i) {
            sum += plea.balanceOf(handler.actors(i));
        }
        assertEq(sum, plea.totalSupply());
        assertEq(plea.totalSupply() + hook.totalBurned() - startingBurned, startingSupply);
        assertEq(imd.balanceOf(address(hook)), hook.retainedImd());
        assertEq(pm.balanceOf(address(hook), uint256(uint160(address(imd)))), hook.retainClaims());
        assertEq(imd.allowance(address(hook), address(stacker)), 0, "credit cannot leave a reserve-spending allowance");
    }

    function invariant_infrastructureNeverReceivesTraderCredit() public view {
        assertNoRouterCredit();
        address[5] memory forbidden = [address(stacker), address(imd), address(simd), address(pm), address(hook)];
        for (uint256 i; i < forbidden.length; ++i) {
            assertEq(simd.balanceOf(forbidden[i]), 0);
            (uint256 spent, uint256 held, uint256 at) = hook.basisOf(forbidden[i]);
            assertEq(spent + held + at, 0);
        }
        if (handler.dead()) assertFalse(gate.cabalAlive());
    }

    function test_handlerExercisesFallbacksDeathAndPlainCashback() public {
        handler.buy(0, 1, 0, 1e18); // msgSender names the payer
        handler.buy(1, 0, 8, 1e18); // explicit trader bypasses gas exhaustion
        handler.buy(0, 1, 4, 1e18); // malformed response refuses a live buy
        handler.pauseVault(true);
        handler.buy(0, 1, 1, 1e18); // fallback pays plain IMD to a different trader
        for (uint256 i; i < 12; ++i) {
            handler.advance(3 hours);
        }
        handler.buy(2, 1, 8, 1e18); // dead buy with no trader still delivers
        handler.buy(0, 1, 10, 1e18); // exact gas stipend still works after death
        assertEq(handler.accepted(), 5);
        assertEq(handler.refused(), 1);
        assertEq(handler.unresolved(), 1);
        assertEq(handler.redirected(), 2);
        assertGt(handler.plainCashback(), 0);
        invariant_tokensAndBuyRecordsFollowTheirIndependentRecipients();
        invariant_supplyAndPoolReserveRemainBacked();
        invariant_infrastructureNeverReceivesTraderCredit();
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract TraderAttributionInvariantPleaZeroTest is TraderAttributionInvariantTest {
    function pleaFirst() internal pure override returns (bool) {
        return true;
    }
}
