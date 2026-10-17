// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "../utils/Fixture.sol";
import {MockIMD} from "../utils/Mocks.sol";
import {CabalGate} from "../../src/CabalGate.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

/// Run-4 audit: a same-share clamp must not round a valid minimum plea below the gate's minimum.
contract AppealRoundingTest is Fixture {
    function setUp() public virtual override {
        super.setUp();
        buy(alice, 2_000e18);
        buy(bob, 1e18);
        holdAWeek(bob); // run 7: a 50% plea needs the 7-day holding points
        // Round 4 (R4-A1-1): the trend reference must lie within two days, so a quiet week reads as "no
        // history"; a real day-old reference and an up trend (the 50% plea needs the 9 points).
        trendUp(bob, 150e18);
    }

    function test_minimumSitePleaCanAppealAfterFeeSaleRounding() public {
        _minimumAppeal(99, 0);
    }

    function testFuzz_minimumPleaAppealsThroughEveryLetterEntry(uint8 remainder, uint8 route) public {
        _minimumAppeal(uint8(bound(remainder, 1, 99)), uint8(bound(route, 0, 2)));
    }

    function _minimumAppeal(uint8 remainder, uint8 route) internal {
        uint256 bought = plea.balanceOf(alice);
        uint256 originalBalance = bought - bought % 100 - 100 + remainder;
        deal(address(plea), alice, originalBalance);
        uint256 originalAmount = originalBalance / 100;
        assertLt(originalAmount, gate.MAX_SELL());
        vm.prank(alice);
        uint256 original = letterbox.plead(originalAmount, "One percent for rent; the rest stays.");
        assertEq(gate.pleaBalance(original), originalBalance);
        assertTrue(answer(original, 0));
        letterbox.settle(original);
        uint256 afterFee = plea.balanceOf(alice);
        assertLt(afterFee, originalBalance, "the fee sale shrank the balance");
        uint256 balance = afterFee - afterFee % 100;
        deal(address(plea), alice, balance);
        uint256 minimum = balance / 100;
        assertEq(FullMath.mulDiv(balance, originalAmount, originalBalance), minimum - 1);

        uint256 appeal;
        vm.prank(alice);
        if (route == 0) {
            appeal = letterbox.appealAuto(original, "The same small share is still needed for rent.");
        } else if (route == 1) {
            letterbox.letter("APPEAL The same small share is still needed for rent.");
            appeal = gate.lastPleaOf(alice);
        } else {
            (bool ok, bytes memory ret) =
                address(letterbox).call("APPEAL The same small share is still needed for rent.");
            if (!ok) {
                assembly ("memory-safe") { revert(add(ret, 32), mload(ret)) }
            }
            appeal = gate.lastPleaOf(alice);
        }
        CabalGate.Plea memory p = gate.getPlea(appeal);
        assertEq(p.amount, minimum);
        assertEq(p.originalId, original);
        assertTrue(p.isAppeal);
        assertEq(uint8(p.status), uint8(CabalGate.Status.Pending));
        assertEq(gate.pleaBalance(appeal), balance);
        assertLe(p.amount, originalAmount);
        assertLe(p.amount, balance / 2);
        assertEq(plea.balanceOf(address(letterbox)), p.amount);
        assertEq(imd.balanceOf(address(letterbox)), 0.25e18);
    }

    function test_cappedMinimumSitePleaCanAppealAfterFeeSale() public {
        // A bag whose 1% exceeds the 2.5M cap: 1,000 IMD on the Sepolia seed (5,700 IMD), more on a larger one.
        while (plea.balanceOf(alice) / 100 <= gate.MAX_SELL() * 102 / 100) {
            buy(alice, 250e18 * hook.MARKET_CAP_IMD() / 5_700e18);
        }
        uint256 originalBalance = plea.balanceOf(alice);
        uint256 amount = gate.MAX_SELL();
        assertGt(originalBalance / 100, amount);
        vm.prank(alice);
        uint256 original = letterbox.plead(amount, "The maximum is under one percent of my bag.");
        assertTrue(answer(original, 0));
        letterbox.settle(original);
        uint256 balance = plea.balanceOf(alice);
        assertLt(balance, originalBalance);
        assertGt(balance / 100, amount);
        assertLt(FullMath.mulDiv(balance, amount, originalBalance), amount);

        vm.prank(alice);
        uint256 appeal = letterbox.appealAuto(original, "The same capped amount is still needed.");
        assertEq(gate.getPlea(appeal).amount, amount);
        assertEq(plea.balanceOf(address(letterbox)), amount);
        assertEq(imd.balanceOf(address(letterbox)), 0.25e18);
    }

    function test_shareBandsAndFiftyPercentClampKeepTheirExistingRounding() public {
        uint256[3] memory shares = [uint256(2_000), 3_500, 5_000];
        for (uint256 i; i < shares.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            uint256 originalBalance = 5_000_000e18 + 99;
            deal(address(plea), alice, originalBalance);
            uint256 amount = originalBalance * shares[i] / 10_000;
            if (amount > gate.MAX_SELL()) amount = gate.MAX_SELL();
            vm.prank(alice);
            uint256 original = letterbox.plead(amount, "This share is for rent; the rest stays.");
            uint8 need = gate.getPlea(original).need;
            assertTrue(answer(original, 0));
            letterbox.settle(original);
            uint256 balance = plea.balanceOf(alice);
            uint256 expected = FullMath.mulDiv(balance, amount, originalBalance);
            assertGt(expected, balance / 100, "the minimum does not apply here");
            vm.prank(alice);
            uint256 appeal = letterbox.appealAuto(original, "The same share is still needed for rent.");
            CabalGate.Plea memory p = gate.getPlea(appeal);
            assertEq(p.amount, expected, "non-minimum appeals retain the floor clamp");
            assertEq(p.need, need, "the fee sale must not change the share band");
            assertLe(p.amount, balance / 2);
            assertLe(p.amount, amount);
            assertEq(plea.balanceOf(address(letterbox)), p.amount);
            assertEq(imd.balanceOf(address(letterbox)), 0.25e18);
            vm.revertToState(snapshot);
        }
    }
}

contract AppealRoundingPaidFeeTest is AppealRoundingTest {
    function oracleFeeToken() internal view override returns (MockIMD) {
        return imd;
    }
}

contract AppealRoundingPleaZeroTest is AppealRoundingTest {
    function deployImd() internal override {
        address high = address(type(uint160).max);
        deployCodeTo("Mocks.sol:MockIMD", "", high);
        imd = MockIMD(high);
    }
}

contract AppealRoundingPaidFeePleaZeroTest is AppealRoundingPleaZeroTest {
    function oracleFeeToken() internal view override returns (MockIMD) {
        return imd;
    }
}
