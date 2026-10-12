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
/// re-runs the fourth's recipe. The setup follows the judge's: 110 whales that bought 100 IMD each a
/// day earlier, whose approved cap-sized sales inside one hour crash spot to well under half the
/// hour's checkpoint.
contract JudgeFindingsTest is Fixture {
    uint256 constant N = 110;
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
            buy(w, 100e18);
        }
        skip(1 days);
        keepAlive(bob); // the dead-man clock starts here; tests may skip another day
    }

    function _nextHourPlusOneMinute() internal {
        uint256 t = vm.getBlockTimestamp();
        vm.warp((t / 1 hours + 1) * 1 hours + 60);
    }

    /// Every whale sells min(35% of its balance, 2.5M PLEA) through an approved plea, all in one hour.
    function _crash() internal {
        for (uint256 i; i < N; ++i) {
            address w = whales[i];
            uint256 amt = plea.balanceOf(w) * 35 / 100;
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
        assertEq(plea.balanceOf(alice) - pleaBefore, 1_250_000e18, "and gets the bonus");
        vm.prank(alice);
        plea.acceptOwnership();
        assertEq(plea.owner(), alice);
    }

    /// Finding 7: the 50% ceiling and the 20% / 35% share bands, on a balance under the 2.5M cap.
    function test_fiftyPercentCeilingAndShareBands() public {
        address dave = makeAddr("dave");
        fund(dave);
        buy(dave, 1e18);
        skip(1 days);
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
