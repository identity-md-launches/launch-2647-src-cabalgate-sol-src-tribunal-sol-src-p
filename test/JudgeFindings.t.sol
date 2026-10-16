// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockIMD} from "./utils/Mocks.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {Letterbox} from "../src/Letterbox.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";

/// Run 3's IMD judge (job c20158a4) left four low findings in the deployed code; run 4 fixes three and
/// re-runs the fourth's recipe. The setup follows the judge's: 160 whales that bought 100 IMD each a
/// day earlier, whose approved cap-sized sales inside one hour crash spot to well under half the
/// hour's checkpoint.
contract JudgeFindingsTest is Fixture {
    uint256 constant N = 160; // run 7: 15% sales (was 110 whales selling 35%)
    address[] whales;
    address victim = makeAddr("victim");
    address smallHolder = makeAddr("smallHolder");

    function setUp() public virtual override {
        super.setUp();
        fund(victim);
        fund(smallHolder);
        buy(alice, 50e18);
        buy(bob, 50e18);
        for (uint256 i; i < N; ++i) {
            address w = makeAddr(string.concat("whale", vm.toString(i)));
            whales.push(w);
            fund(w);
            // 100 IMD on the Sepolia seed (5,700 IMD); the same share of the curve on a larger seed.
            buy(w, 100e18 * hook.MARKET_CAP_IMD() / 5_700e18);
        }
        skip(1 days);
        keepAlive(bob); // the dead-man clock starts here; tests may skip another day
        holdAWeek(bob); // run 7: a whale's cap-sized sale needs the 7-day holding points
    }

    function _nextHourPlusOneMinute() internal {
        uint256 t = vm.getBlockTimestamp();
        vm.warp((t / 1 hours + 1) * 1 hours + 60);
    }

    /// Every whale sells min(20% of its balance, 2.5M PLEA) through an approved plea, all in one hour
    /// (a week-old whale at any gain can plead 20%; a larger share needs a loss or an up trend).
    function _crash() internal {
        for (uint256 i; i < N; ++i) {
            address w = whales[i];
            uint256 amt = plea.balanceOf(w) * 20 / 100;
            if (amt > 2_500_000e18) amt = 2_500_000e18;
            uint256 id = plead(w, amt);
            require(answer(id, 45), "verdict");
            vm.prank(w);
            gate.executeSell(0);
        }
    }

    function _letter(address who, bytes memory text) internal returns (uint256 id) {
        vm.prank(who);
        (bool ok, bytes memory ret) = address(letterbox).call(text);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        id = gate.lastPleaOf(who);
    }

    /// Findings 1 and 4: a 0.72 IMD auto-sell plea, a crash of more than half between two hourly
    /// checkpoints, the first buy of the next hour, then the delivery. The buy must go through, and
    /// the delivery must sell with the fee capped at the sale instead of underflowing.
    function test_deliverAfterACrashCapsTheFeeAtTheSale() public {
        _nextHourPlusOneMinute();
        buy(carol, 1e18); // the hour's checkpoint P_H
        uint256 pH = hook.latestPrice();
        skip(44 minutes);
        buy(victim, 10e18);
        uint256 amount = FullMath.mulDiv(0.72e18, FixedPoint96.Q96, pH) + 1;
        vm.prank(victim);
        uint256 id = letterbox.plead(amount, "A sliver of my bag for a bike repair; the rest rides with me.");
        _crash();
        uint256 spot = hook.priceX96();
        assertLt(spot * 2, pH, "spot fell by more than half inside the hour");
        _nextHourPlusOneMinute();
        buy(carol, 1e18); // finding 4: the first buy of the next hour must not revert
        assertLt(hook.latestPrice() * 2, pH, "the new checkpoint is the crashed price");
        require(answer(id, 45), "verdict");
        uint256 writerBefore = imd.balanceOf(victim);
        vm.recordLogs();
        vm.prank(keeper);
        uint256 out = letterbox.deliver(id);
        uint256 fee = type(uint256).max;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == Letterbox.Delivered.selector) {
                (,, fee) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
        assertLe(fee, 0.35e18, "the fee never exceeds 0.35 IMD");
        assertEq(imd.balanceOf(victim) - writerBefore, out);
        assertGt(out + fee, 0, "the sale happened");
        assertLt(out + fee, 0.35e18 + 0.05e18, "the sale was indeed small");
        assertEq(imd.balanceOf(keeper), 0.25e18, "the runner earns the tip");
        assertEq(imd.balanceOf(address(letterbox)), 0);
        assertEq(plea.balanceOf(address(letterbox)), 0);
        assertTrue(seasons.recorded(id));
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Executed));
    }

    /// Live run 3 (Sepolia, 2026-10-12): a 20% letter's fee sale shrank the balance, so the APPEAL letter
    /// for the same amount fell into the next share band (fact 30, need 40 instead of 33; with run 7's
    /// 15% letters and bands 15/30 the same slip would cost 7 points of need). The appeal
    /// now keeps the original's share of the balance.
    function test_appealLetterKeepsTheOriginalShareBand() public {
        buy(alice, 20e18);
        skip(1 days);
        uint256 id = _letter(alice, "A fifth for the electrician; the rest stays until the lights go out.");
        CabalGate.Plea memory p = gate.getPlea(id);
        assertEq(p.need, 71 - p.factScore);
        uint8 need = p.need;
        require(answer(id, 0), "verdict");
        uint256 ap = _letter(alice, "APPEAL The electrician does not wait; the rest still stays.");
        CabalGate.Plea memory a = gate.getPlea(ap);
        assertEq(a.need, need, "the appeal is judged against the same need as the plea");
        assertLt(a.amount, p.amount, "a slightly smaller amount keeps the share band");
        assertLe(a.amount * 10_000 / gate.pleaBalance(ap), 2_000, "still in the 20% band");
    }

    /// Run-4 import audit: a site plea at exactly the gate's 1% minimum, denied, settled, then appealed
    /// with auto-sell: the same-share clamp rounds up so it never lands one wei under the minimum.
    function test_appealAutoOfAMinimumPleaStaysAtTheMinimum() public {
        address whale = makeAddr("whale");
        fund(whale);
        buy(whale, 500e18);
        skip(1 days);
        // The judge's recipe: a balance that is not a multiple of 100 (transfers are gated, so set it).
        uint256 b = plea.balanceOf(whale);
        b = b - (b % 100) - 1;
        deal(address(plea), whale, b);
        vm.prank(whale);
        uint256 id = letterbox.plead(b / 100, "Exactly one percent, the smallest plea the gate allows; the rest stays.");
        require(answer(id, 0), "verdict");
        letterbox.settle(id);
        // Shrunk by the fee sale; make it a multiple of 100 so a floored clamp would be one wei short.
        uint256 bal = plea.balanceOf(whale);
        deal(address(plea), whale, bal - (bal % 100));
        vm.prank(whale);
        uint256 ap = letterbox.appealAuto(id, "Still one percent; the rest still stays.");
        assertTrue(gate.getPlea(ap).isAppeal);
        assertGe(gate.getPlea(ap).amount, gate.pleaBalance(ap) / 100, "at least the gate's minimum");
    }

    /// Finding 2: a writer worth a few IMD can plead by letter and then appeal by letter.
    function test_aSmallWriterCanAppealByLetter() public {
        buy(smallHolder, 5e18);
        skip(1 days);
        uint256 id = _letter(smallHolder, "A fifth for a bike; the rest stays with me all season.");
        require(answer(id, 0), "verdict");
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Denied));
        assertTrue(vm.contains(letterbox.status(smallHolder), "send APPEAL"), letterbox.status(smallHolder));
        uint256 ap = _letter(smallHolder, "APPEAL The bike is how I get to work; I keep the rest.");
        assertTrue(gate.getPlea(ap).isAppeal);
        assertEq(gate.getPlea(ap).originalId, id);
        assertEq(IERC20Like(address(imd)).balanceOf(address(letterbox)), 0.25e18, "one tip held");
    }

    /// Finding 3: the owner cannot strip a season leader by handing them PLEA's ownership; the
    /// transfer takes effect only when the new owner accepts.
    function test_ownershipTransferNeedsAcceptanceSoALeaderKeepsThePrize() public {
        uint256 id1 = approvedPlea(alice, 45);
        seasons.record(id1);
        skip(4 hours + 8 minutes);
        uint256 id2 = approvedPlea(alice, 45);
        seasons.record(id2);
        assertEq(seasons.topOf(0)[0].wallet, alice);
        vm.prank(OWNER);
        plea.transferOwnership(alice);
        assertEq(plea.owner(), OWNER, "not yet accepted");
        assertEq(plea.pendingOwner(), alice);
        vm.warp(uint256(gate.lastVerdictAt()) + gate.DEADMAN() + 1 hours + 1);
        uint256 imdBefore = imd.balanceOf(alice);
        uint256 pleaBefore = plea.balanceOf(alice);
        seasons.closeSeason(new uint256[](0));
        assertGt(imd.balanceOf(alice), imdBefore, "the leader is paid");
        assertEq(plea.balanceOf(alice) - pleaBefore, 450_000e18, "and gets the bonus");
        vm.prank(alice);
        plea.acceptOwnership();
        assertEq(plea.owner(), alice);
    }

    /// Finding 7: the 50% ceiling and the 15% / 30% share bands, on a balance under the 2.5M cap.
    function test_fiftyPercentCeilingAndShareBands() public {
        address dave = makeAddr("dave");
        fund(dave);
        buy(dave, 1e18);
        holdAWeek(bob);
        trendUp(carol, 400e18); // run 7: half the balance at a small gain needs a week and an up trend
        uint256 bal = plea.balanceOf(dave);
        assertLt(bal, 5_000_000e18);
        vm.prank(dave);
        vm.expectRevert(CabalGate.AmountTooLarge.selector);
        gate.submitSell(bal / 2 + 1, "too much");
        assertEq(gate.factScore(dave, bal * 2000 / 10_000) - gate.factScore(dave, bal * 2001 / 10_000 + 1), 7);
        assertEq(gate.factScore(dave, bal * 3500 / 10_000) - gate.factScore(dave, bal * 3501 / 10_000 + 1), 6);
        vm.prank(dave);
        uint256 id = gate.submitSell(bal / 2, "exactly half");
        assertEq(gate.getPlea(id).amount, bal / 2);
    }

    /// Run 8.5's launch audit (L85-M-1): the share bands' edges are exact. At most 20% (35%) of the
    /// balance scores the better band and one wei over does not, on a balance that is not a multiple
    /// of 10,000.
    function test_oneWeiOverAShareBandScoresTheNextBand() public {
        address dave = makeAddr("dave");
        fund(dave);
        buy(dave, 1e18);
        uint256 bal = plea.balanceOf(dave);
        if (bal % 10_000 == 0) {
            vm.prank(dave);
            plea.transfer(bob, 1);
            bal -= 1;
        }
        assertGt(bal % 10_000, 0);
        uint256 fifth = bal / 5;
        uint256 band35 = bal * 7 / 20;
        assertEq(gate.factScore(dave, fifth) - gate.factScore(dave, fifth + 1), 7, "one wei over 20%");
        assertEq(gate.factScore(dave, band35) - gate.factScore(dave, band35 + 1), 6, "one wei over 35%");
        assertEq(gate.factScore(dave, bal * 2_000 / 10_000 + 1), gate.factScore(dave, bal * 2_001 / 10_000));
    }
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}

contract JudgeFindingsPleaZeroTest is JudgeFindingsTest {
    function deployImd() internal override {
        address high = address(type(uint160).max);
        deployCodeTo("Mocks.sol:MockIMD", "", high);
        imd = MockIMD(high);
    }
}
