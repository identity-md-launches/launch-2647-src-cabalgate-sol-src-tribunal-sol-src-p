// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "../utils/Fixture.sol";
import {PleaLaunch} from "../../src/PleaLaunch.sol";
import {Tribunal} from "../../src/Tribunal.sol";
import {Seasons} from "../../src/Seasons.sol";
import {CabalGate} from "../../src/CabalGate.sol";

/// @notice How Seasons waits for the Tribunal: held points, sustained pleas, closes that skip held
/// pleas, letters that sell during a hold, and the timing bound inside the close grace.
contract TribunalSeasonsTest is Fixture {
    uint256 constant WINDOW = 20 minutes;

    function withTribunal() internal pure override returns (bool) {
        return true;
    }

    /// @dev Two-day seasons: a season end is reachable while the 33-hour Cabal still lives.
    function setTimings() internal override {
        SEASON = 2 days;
    }

    function setUp() public virtual override {
        super.setUp();
        buy(alice, 50e18);
        buy(bob, 50e18);
        buy(carol, 50e18);
        skip(1 days);
    }

    function test_theTimingBoundHoldsInsideTheCloseGrace() public view {
        assertLt(tribunal.OBJECTION_WINDOW() + tribunal.PENDING_EXPIRY(), seasons.CLOSE_GRACE());
    }

    function test_seasonsFindsTheTribunalThroughTheLauncher() public view {
        assertEq(launch.tribunal(), address(tribunal));
        assertEq(launch.predictTribunal(), address(tribunal));
        assertTrue(seasons.excluded(OWNER));
        assertFalse(seasons.excluded(alice));
    }

    function test_recordWaitsForTheWindowThenForAPendingObjection() public {
        uint256 id = approvedPlea(alice, 40);
        vm.expectRevert(abi.encodeWithSelector(Seasons.Held.selector, id));
        seasons.record(id);
        skip(WINDOW - 1);
        uint256 oid = objectTo(bob, id);
        skip(2);
        vm.expectRevert(abi.encodeWithSelector(Seasons.Held.selector, id)); // pending objection past the window
        seasons.record(id);
        assertTrue(rule(oid, 44));
        seasons.record(id);
        assertEq(seasons.bestOf(0, alice)[0], 40);
        assertTrue(seasons.recorded(id));
    }

    function test_recordIsFreeOnceTheWindowClosesWithNoObjection() public {
        uint256 id = approvedPlea(alice, 40);
        skip(WINDOW);
        vm.expectRevert(abi.encodeWithSelector(Seasons.Held.selector, id));
        seasons.record(id);
        skip(1);
        seasons.record(id);
        objectFails(bob, id, abi.encodeWithSelector(Tribunal.WindowClosed.selector, id));
    }

    function test_closeSeasonSkipsHeldPleasAndRecordsThemLater() public {
        // A plea approved just before the season ends is still held when the close could run.
        keepAlive(carol);
        uint256 end = uint256(gate.startedAt()) + SEASON;
        vm.warp(end - 10 minutes);
        uint256 id = approvedPlea(alice, 40);
        uint256 oid = objectTo(bob, id);
        vm.warp(end + 1 hours); // the close grace has passed; the objection is 20 minutes stale
        // Stale: no longer held, so the close records it (the ruling never came).
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        seasons.closeSeason(ids);
        assertTrue(seasons.recorded(id), "a stale objection does not keep a plea out of its season");
        assertEq(seasons.bestOf(0, alice)[0], 40);
        tribunal.expire(oid);
        tribunal.settle(oid);
    }

    function test_closeListsAHeldPleaOfTheRunningSeasonWithoutReverting() public {
        // Season 0 is closable; a plea of season 1 approved just now is held: the list skips it.
        keepAlive(carol);
        vm.warp(uint256(gate.startedAt()) + SEASON + 1 hours);
        uint256 id = approvedPlea(alice, 40);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        seasons.closeSeason(ids);
        assertFalse(seasons.recorded(id));
        skip(WINDOW + 1);
        seasons.record(id);
        assertEq(seasons.bestOf(1, alice)[0], 40);
    }

    function test_approvalInTheLastSecondIsRuledAndRecordedInsideTheGrace() public {
        keepAlive(carol);
        uint256 end = uint256(gate.startedAt()) + SEASON;
        vm.warp(end - 1);
        uint256 id = approvedPlea(alice, 40);
        vm.warp(end - 1 + WINDOW); // last second of the objection window
        uint256 oid = objectTo(bob, id);
        vm.warp(end - 1 + WINDOW + tribunal.PENDING_EXPIRY()); // last second of the ruling
        assertTrue(rule(oid, 38));
        assertLt(vm.getBlockTimestamp(), end + seasons.CLOSE_GRACE(), "ruled before the close could run");
        vm.warp(end + seasons.CLOSE_GRACE());
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        seasons.closeSeason(ids);
        assertTrue(seasons.recorded(id));
        assertEq(seasons.bestOf(0, alice)[0], 38);
    }

    function test_aVoidAtTheLastSecondLeavesNoRoomForASecondObjection() public {
        // Approval in the season's last second, objection in the window's last second, no ruling:
        // the slot frees at verdict + 40 min, but the window closed at + 20, so nobody can object
        // again and the close at + 60 records the original score.
        keepAlive(carol);
        uint256 end = uint256(gate.startedAt()) + SEASON;
        vm.warp(end - 1);
        uint256 id = approvedPlea(alice, 40);
        vm.warp(end - 1 + WINDOW);
        uint256 oid = objectTo(bob, id);
        vm.warp(end - 1 + WINDOW + tribunal.PENDING_EXPIRY());
        (bool held,,) = tribunal.standing(id);
        assertTrue(held, "the ruling's last second");
        vm.expectRevert(abi.encodeWithSelector(Seasons.Held.selector, id));
        seasons.record(id);
        skip(1);
        (held,,) = tribunal.standing(id);
        assertFalse(held, "stale by time: free");
        tribunal.expire(oid);
        objectFails(carol, id, abi.encodeWithSelector(Tribunal.WindowClosed.selector, id));
        objectFails(bob, id, abi.encodeWithSelector(Tribunal.WindowClosed.selector, id));
        assertLt(vm.getBlockTimestamp(), end + seasons.CLOSE_GRACE());
        uint256 stake = imd.balanceOf(bob);
        tribunal.settle(oid);
        assertEq(imd.balanceOf(bob) - stake, 0.35e18, "void: the stake comes back");
        vm.warp(end + seasons.CLOSE_GRACE());
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        seasons.closeSeason(ids);
        assertTrue(seasons.recorded(id));
        assertEq(seasons.bestOf(0, alice)[0], 40);
    }

    function test_twoRulingsAtTheEdgeStayInsideTheGrace() public {
        // An early overrule, then a second objection in the window's last second that never gets
        // an answer: the plea is free by verdict + 40 min with the first panel's lower score.
        keepAlive(carol);
        uint256 end = uint256(gate.startedAt()) + SEASON;
        vm.warp(end - 1);
        uint256 id = approvedPlea(alice, 40);
        uint8 n = gate.getPlea(id).need; // re-scored at the need: overruled, and never above 40
        uint256 first = objectTo(bob, id);
        assertTrue(rule(first, n));
        vm.warp(end - 1 + WINDOW);
        uint256 second = objectTo(carol, id);
        objectFails(bob, id, abi.encodeWithSelector(Tribunal.ObjectionPending.selector, second));
        vm.warp(end - 1 + WINDOW + tribunal.PENDING_EXPIRY() + 1);
        (bool held, bool sustained, uint8 lowest) = tribunal.standing(id);
        assertFalse(held);
        assertFalse(sustained);
        assertEq(lowest, n);
        vm.warp(end + seasons.CLOSE_GRACE());
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        seasons.closeSeason(ids);
        assertEq(seasons.bestOf(0, alice)[0], n);
        assertEq(uint8(tribunal.objection(second).ruling), uint8(Tribunal.Ruling.Pending), "nobody expired it");
        tribunal.expire(second);
        assertEq(uint8(tribunal.objection(second).ruling), uint8(Tribunal.Ruling.Void));
    }

    function test_theLetterboxStatusShowsHeldPendingAndSustainedPoints() public {
        uint256 amount = plea.balanceOf(alice) / 10;
        vm.prank(alice);
        uint256 id = letterbox.plead(amount, "Rent is due and I keep the rest.");
        assertTrue(answer(id, 40));
        vm.prank(keeper);
        letterbox.deliver(id);
        string memory until = _clock(uint256(gate.getPlea(id).verdictAt) + WINDOW);
        assertTrue(
            _has(letterbox.status(alice), string.concat("+40 points held until ", until, " (objections open)")),
            letterbox.status(alice)
        );
        skip(10 minutes);
        uint256 oid = objectTo(bob, id);
        skip(WINDOW - 10 minutes + 1); // window closed, the objection still pending
        assertTrue(_has(letterbox.status(alice), "+40 points held: an objection is pending"), letterbox.status(alice));
        string memory n = vm.toString(gate.getPlea(id).need); // re-scored at the need: overruled
        assertTrue(rule(oid, gate.getPlea(id).need));
        assertTrue(
            _has(letterbox.status(alice), string.concat("+", n, " points once recorded")), letterbox.status(alice)
        );
        seasons.record(id);
        assertTrue(
            _has(letterbox.status(alice), string.concat("+", n, " points (season 1, rank 1)")), letterbox.status(alice)
        );

        // a sustained objection
        uint256 amount2 = plea.balanceOf(carol) / 10;
        vm.prank(carol);
        uint256 id2 = letterbox.plead(amount2, "Taking a little profit, holding the rest for season two.");
        assertTrue(answer(id2, 40));
        vm.prank(keeper);
        letterbox.deliver(id2);
        uint256 oid2 = objectTo(bob, id2);
        assertTrue(rule(oid2, 0));
        assertTrue(_has(letterbox.status(carol), "no points: an objection was sustained"), letterbox.status(carol));
    }

    function _has(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool ok = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    function _clock(uint256 t) internal pure returns (string memory) {
        return string.concat(_two((t / 3600) % 24), ":", _two((t / 60) % 60), " UTC");
    }

    function _two(uint256 v) internal pure returns (string memory) {
        return v < 10 ? string.concat("0", vm.toString(v)) : vm.toString(v);
    }

    function test_aSustainedPleaIsNeverRecordedEvenByAClose() public {
        uint256 id = approvedPlea(alice, 40);
        uint256 oid = objectTo(bob, id);
        assertTrue(rule(oid, 0));
        vm.warp(uint256(gate.startedAt()) + SEASON + 1 hours);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        seasons.closeSeason(ids);
        assertFalse(seasons.recorded(id));
        assertEq(seasons.bestOf(0, alice)[0], 0);
    }

    function test_aLetterSellsDuringTheHoldAndItsPointsAreRecordedLater() public {
        // A site-style plea through the Letterbox (auto-sell): deliver sells inside the 7-minute
        // window while the objection window is still open; the points come later.
        uint256 amount = plea.balanceOf(alice) / 10;
        vm.prank(alice);
        uint256 id = letterbox.plead(amount, "Rent is due and I keep the rest.");
        assertTrue(answer(id, 40));
        vm.prank(keeper);
        letterbox.deliver(id);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Executed));
        assertFalse(seasons.recorded(id), "held: not recorded by the delivery");
        uint256 oid = objectTo(bob, id);
        assertTrue(rule(oid, 39));
        skip(WINDOW + 1);
        seasons.record(id);
        assertEq(seasons.bestOf(0, alice)[0], 39, "the lowest panel's score, recorded after the sale");
    }
}

/// @notice Round 6 (R6-A2-I1): with a committed Tribunal, trading waits for it as it waits for the
/// Letterbox, so no plea is ever recorded out of the Tribunal's reach. Before round 6 the owner could
/// seed first, and a plea approved and recorded in the gap could never be objected to.
contract TribunalLateDeployTest is Fixture {
    function withTribunal() internal pure override returns (bool) {
        return true;
    }

    function deployTribunalAtLaunch() internal pure override returns (bool) {
        return false;
    }

    function openTrading() internal override {
        assertEq(launch.tribunal(), address(0));
        vm.expectRevert(PleaLaunch.TribunalNotDeployed.selector);
        vm.prank(OWNER);
        launch.seed();
        vm.warp(launch.START());
        vm.expectRevert(PleaLaunch.TribunalNotDeployed.selector);
        launch.seed(); // nor anyone after START
        assertEq(gate.startedAt(), 0, "trading is still closed");
        tribunal = Tribunal(launch.deployTribunal(vm.getCode("Tribunal.sol:Tribunal")));
        super.openTrading();
    }

    function test_tradingWaitsForTheCommittedTribunal() public {
        assertTrue(launch.opened());
        assertEq(launch.tribunal(), address(tribunal));
        buy(alice, 50e18);
        skip(1 days);
        uint256 id = approvedPlea(alice, 40);
        vm.expectRevert(abi.encodeWithSelector(Seasons.Held.selector, id));
        seasons.record(id); // the first approval is held like any other
        uint256 oid = objectTo(bob, id);
        assertEq(tribunal.caseOf(id).pending[0], oid);
    }
}
