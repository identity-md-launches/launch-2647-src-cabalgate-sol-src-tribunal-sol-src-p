// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SepoliaFixture} from "../utils/SepoliaFixture.sol";
import {CabalGate} from "src/CabalGate.sol";
import {Seasons} from "src/Seasons.sol";
import {Tribunal} from "src/Tribunal.sol";

/// @notice Real gate, Tribunal, Seasons, Letterbox and pool at the run-7 five-hour season clock.
/// The NFT multiplier must never change either panel's verdict or the already executed sale.
/// forge-config: default.fuzz.runs = 64
contract Run7ObjectionPointsTest is SepoliaFixture {
    function withTribunal() internal pure override returns (bool) {
        return true;
    }

    function setUp() public virtual override {
        super.setUp();
        buy(alice, 50e18);
        buy(bob, 50e18);
        buy(carol, 50e18);
        skip(1 days);
    }

    function test_aSeatCannotTurnADenialIntoAnApprovalOrAnObjectablePlea() public {
        seat.mint(alice);
        uint256 id = plead(alice, small(alice));
        uint8 need = gate.getPlea(id).need;
        assertGe(seasons.pointsFor(alice, need - 1), need, "boost would pass if wrongly applied to judging");
        assertTrue(answer(id, need - 1));
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Denied));
        vm.expectRevert(abi.encodeWithSelector(Seasons.NotApproved.selector, id));
        seasons.record(id);
        objectFails(bob, id, abi.encodeWithSelector(Tribunal.NotApproved.selector, id));
        assertFalse(seasons.recorded(id));
    }

    function test_aBoostedScoreCannotRescueASustainedObjectionOrReverseASale() public {
        uint256 id = approvedPlea(alice, 45);
        uint8 need = gate.getPlea(id).need;
        vm.prank(alice);
        uint256 soldFor = gate.executeSell(0);
        assertGt(soldFor, 0);
        uint256 saleProceeds = imd.balanceOf(alice);
        uint256 remainingPlea = plea.balanceOf(alice);
        uint64 clock = gate.lastVerdictAt();
        uint256 objectorBefore = imd.balanceOf(bob);
        uint256 oid = objectTo(bob, id);
        seat.mint(alice);
        uint8 score = need - 3;
        assertGe(seasons.pointsFor(alice, score), need, "seat points exceed need but raw score fails the margin");
        assertTrue(rule(oid, score));
        assertEq(uint8(tribunal.objection(oid).ruling), uint8(Tribunal.Ruling.Sustained));
        vm.expectRevert(abi.encodeWithSelector(Seasons.ObjectionSustained.selector, id));
        seasons.record(id);
        tribunal.settle(oid);
        assertEq(imd.balanceOf(bob), objectorBefore);
        assertEq(imd.balanceOf(address(tribunal)), 0);
        assertEq(imd.balanceOf(alice), saleProceeds);
        assertEq(plea.balanceOf(alice), remainingPlea);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Executed));
        assertEq(gate.lastVerdictAt(), clock);
        assertEq(seasons.pointsOf(id), 0);
    }

    function test_twoRulingsUseTheLowestRawScoreThenTheSeatAtRecordTime() public {
        seat.mint(alice);
        uint256 id = approvedPlea(alice, 45);
        uint8 score = gate.getPlea(id).need - 2;
        uint64 clock = gate.lastVerdictAt();
        uint256 first = objectTo(bob, id);
        assertTrue(rule(first, score)); // equality at score + 2 == need is overruled
        objectFails(bob, id, Tribunal.SameObjector.selector);
        seat.burn(alice);
        uint256 second = objectTo(carol, id);
        assertTrue(rule(second, 45)); // later panel cannot restore points the earlier panel removed
        (bool held, bool sustained, uint8 lowest) = tribunal.standing(id);
        assertFalse(held, "two completed rulings close the case before the window ends");
        assertFalse(sustained);
        assertEq(lowest, score);
        seasons.record(id);
        assertEq(seasons.pointsOf(id), score, "no seat when finally recorded");
        seat.mint(alice);
        vm.expectRevert(abi.encodeWithSelector(Seasons.AlreadyRecorded.selector, id));
        seasons.record(id);
        (, uint256 season,) = seasons.currentSeason();
        uint256 fees = seasons.seasonFees(season);
        tribunal.settle(second);
        tribunal.settle(first); // settlement order is independent of ruling order
        assertEq(seasons.seasonFees(season), fees + 0.7e18);
        assertEq(imd.balanceOf(address(tribunal)), 0);
        assertEq(gate.lastVerdictAt(), clock);
        assertEq(seasons.pointsOf(id), score);
    }

    function test_pendingObjectionAtFiveHourBoundaryUsesSeatOnLateRecordAndStakeRollsOver() public {
        // One counted plea earlier in season five, then a second after the sale's four-hour cooldown.
        uint256 early = approvedPlea(alice, 45);
        vm.prank(alice);
        gate.executeSell(0);
        skip(20 minutes + 1);
        seasons.record(early);
        (, uint256 season, uint64 end) = seasons.currentSeason();
        assertEq(season, 5, "the six-season bonus boundary is exercised");
        vm.warp(uint256(end) - 1);
        uint256 late = approvedPlea(alice, 45);
        uint8 score = gate.getPlea(late).need - 2;
        uint64 clock = gate.lastVerdictAt();
        vm.warp(uint256(end) - 1 + 20 minutes);
        uint256 oid = objectTo(bob, late); // exactly the last permitted second
        vm.expectRevert(abi.encodeWithSelector(Seasons.Held.selector, late));
        seasons.record(late);
        seat.mint(alice); // no seat when approved or objected to
        vm.warp(uint256(end) - 1 + 40 minutes);
        assertTrue(rule(oid, score)); // exactly the last permitted ruling second
        vm.warp(uint256(end) + 1 hours);
        for (uint256 i; i < season; ++i) {
            seasons.closeSeason(new uint256[](0));
        }
        uint256[] memory ids = new uint256[](2);
        ids[0] = late;
        ids[1] = late; // close's late-record list is idempotent for duplicate IDs
        seasons.closeSeason(ids);
        assertEq(seasons.pointsOf(early), 45);
        assertEq(seasons.pointsOf(late), score + score / 5);
        assertEq(plea.balanceOf(address(seasons)), 0, "all six bonus seasons are closed");
        assertEq(seasons.nextToClose(), 6);
        uint256 rollover = seasons.rollover();
        uint256 currentFees = seasons.seasonFees(6);
        tribunal.settle(oid); // a closed plea's season receives rollover, never a second prize
        assertEq(seasons.rollover(), rollover + 0.35e18);
        assertEq(seasons.seasonFees(6), currentFees);
        assertEq(seasons.seasonFees(5), 0);
        assertEq(gate.lastVerdictAt(), clock);
        vm.expectRevert(abi.encodeWithSelector(Tribunal.AlreadySettled.selector, oid));
        tribunal.settle(oid);
    }

    function test_aLetterCanSellWhilePointsWaitThenUseANewSeatAfterVoid() public {
        uint256 balance = plea.balanceOf(alice);
        vm.prank(alice);
        letterbox.letter("A little for rent; my remaining PLEA stays with the Cabal.");
        uint256 id = gate.lastPleaOf(alice);
        assertEq(gate.getPlea(id).amount, balance * 20 / 100);
        assertTrue(answer(id, 45));
        uint256 oid = objectTo(bob, id);
        uint256 before = imd.balanceOf(alice);
        vm.prank(keeper);
        uint256 out = letterbox.deliver(id);
        assertEq(imd.balanceOf(alice) - before, out);
        assertFalse(seasons.recorded(id), "delivery must not bypass the Tribunal hold");
        uint256 remaining = plea.balanceOf(alice);
        seat.mint(alice);
        skip(20 minutes + 1);
        tribunal.expire(oid);
        tribunal.settle(oid);
        seasons.record(id);
        assertEq(seasons.pointsOf(id), 54);
        assertEq(plea.balanceOf(alice), remaining);
        assertEq(imd.balanceOf(alice) - before, out);
        assertEq(plea.balanceOf(address(letterbox)), 0);
        assertEq(imd.balanceOf(address(letterbox)), 0);
        vm.expectRevert(abi.encodeWithSelector(Seasons.AlreadyRecorded.selector, id));
        seasons.record(id);
    }

    function testFuzz_marginAlwaysUsesRawScoreAndMultiplierOnlyUsesTheRecordingSeat(
        uint8 rawScore,
        bool holderAtRuling,
        bool holderAtRecord
    ) public {
        uint256 id = approvedPlea(alice, 45);
        uint8 need = gate.getPlea(id).need;
        uint8 score = uint8(bound(rawScore, need - 5, 45));
        uint64 clock = gate.lastVerdictAt();
        uint256 objectorBefore = imd.balanceOf(bob);
        uint256 oid = objectTo(bob, id);
        if (holderAtRuling) seat.mint(alice);
        assertTrue(rule(oid, score));
        bool sustained = uint256(score) + 2 < need;
        assertEq(
            uint8(tribunal.objection(oid).ruling),
            uint8(sustained ? Tribunal.Ruling.Sustained : Tribunal.Ruling.Overruled)
        );
        if (holderAtRuling) seat.burn(alice);
        if (holderAtRecord) seat.mint(alice);
        skip(20 minutes + 1);
        if (sustained) vm.expectRevert(abi.encodeWithSelector(Seasons.ObjectionSustained.selector, id));
        seasons.record(id);
        assertEq(seasons.pointsOf(id), sustained ? 0 : score + (holderAtRecord ? score / 5 : 0));
        tribunal.settle(oid);
        assertEq(imd.balanceOf(bob), sustained ? objectorBefore : objectorBefore - 0.35e18);
        assertEq(imd.balanceOf(address(tribunal)), 0);
        assertEq(gate.lastVerdictAt(), clock);
    }
}

/// @dev Exercise the same coupled transitions with PLEA as currency0 as well as currency1.
/// forge-config: default.fuzz.runs = 64
contract Run7ObjectionPointsPleaFirstTest is Run7ObjectionPointsTest {
    function pleaFirst() internal pure override returns (bool) {
        return true;
    }
}
