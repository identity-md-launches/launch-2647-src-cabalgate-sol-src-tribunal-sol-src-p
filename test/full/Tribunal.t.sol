// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "../utils/Fixture.sol";
import {MockIMD} from "../utils/Mocks.sol";
import {Tribunal} from "../../src/Tribunal.sol";
import {Seasons} from "../../src/Seasons.sol";
import {CabalGate} from "../../src/CabalGate.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";

/// @notice Objection! end to end: sustained, overruled and void rulings, their payouts, the window,
/// the two-objection case, eligibility, the text rules and the second panel's question.
contract TribunalTest is Fixture {
    uint256 constant STAKE = 0.35e18;
    uint256 constant FEE = 0.5e18;
    uint256 constant WINDOW = 20 minutes;
    address dave = makeAddr("dave");

    function withTribunal() internal pure override returns (bool) {
        return true;
    }

    function setUp() public virtual override {
        super.setUp();
        fund(dave);
        buy(alice, 50e18);
        buy(bob, 50e18);
        buy(carol, 50e18);
        skip(1 days);
    }

    function need(uint256 id) internal view returns (uint8) {
        return gate.getPlea(id).need;
    }

    function approvedBy(address who) internal returns (uint256 id) {
        id = approvedPlea(who, 40);
        assertGe(40, need(id), "fixture: 40 must pass");
    }

    function ruling(uint256 id) internal view returns (Tribunal.Ruling) {
        return tribunal.objection(id).ruling;
    }

    function standing(uint256 pleaId) internal view returns (bool held, bool sustained, uint8 lowest) {
        return tribunal.standing(pleaId);
    }

    // ---------------------------------------------------------------- rulings

    function test_sustainedObjectionLeavesNoPointsAndReturnsTheStake() public {
        uint256 id = approvedBy(alice);
        MockIMD fee = oracleFeeToken();
        bool mints = tribunal.mintOracleFee();
        uint256 imdBefore = imd.balanceOf(bob);
        uint256 feeBefore = fee.balanceOf(bob);
        uint256 paidBefore = fee.balanceOf(intake.PAY_TO());
        uint256 oid = objectTo(bob, id);
        if (mints) {
            assertEq(imd.balanceOf(bob), imdBefore - STAKE, "the stake is pulled");
            assertEq(fee.balanceOf(bob), feeBefore, "Sepolia path: the Tribunal mints the test fee");
        } else {
            assertEq(imd.balanceOf(bob), imdBefore - STAKE - FEE, "mainnet path: stake and fee in IMD");
        }
        assertEq(fee.balanceOf(intake.PAY_TO()), paidBefore + FEE, "the Intake is paid");
        assertEq(imd.balanceOf(address(tribunal)), STAKE);
        (bool held,,) = standing(id);
        assertTrue(held, "held while the objection is pending");
        uint8 n = need(id);
        vm.expectEmit(true, true, false, true);
        emit Tribunal.Ruled(oid, id, true, 40, n - 3, keccak256(abi.encode("objection", oid)));
        assertTrue(rule(oid, n - 3), "the callback ran");
        assertEq(uint8(ruling(oid)), uint8(Tribunal.Ruling.Sustained));
        (bool held2, bool sustained, uint8 lowest) = standing(id);
        assertFalse(held2);
        assertTrue(sustained);
        assertEq(lowest, n - 3);
        vm.expectRevert(abi.encodeWithSelector(Seasons.ObjectionSustained.selector, id));
        seasons.record(id);
        skip(1 hours);
        vm.expectRevert(abi.encodeWithSelector(Seasons.ObjectionSustained.selector, id));
        seasons.record(id);
        tribunal.settle(oid);
        assertEq(imd.balanceOf(bob), imdBefore - (mints ? 0 : FEE), "stake back, the fee is spent");
        assertEq(imd.balanceOf(address(tribunal)), 0);
        vm.expectRevert(abi.encodeWithSelector(Tribunal.AlreadySettled.selector, oid));
        tribunal.settle(oid);
    }

    function test_overruledObjectionLowersTheScoreToTheLowestPanelAndFeedsThePot() public {
        uint256 id = approvedBy(alice);
        uint8 n = need(id);
        uint256 oid = objectTo(bob, id);
        uint256 potBefore = seasons.pot();
        // Below the need but inside the margin: not sustained, the plea keeps the lower score.
        uint8 newScore = n - 2;
        assertTrue(rule(oid, newScore));
        assertEq(uint8(ruling(oid)), uint8(Tribunal.Ruling.Overruled));
        (bool held, bool sustained, uint8 lowest) = standing(id);
        assertTrue(held, "the window is still open for a second objector");
        assertFalse(sustained);
        assertEq(lowest, newScore);
        skip(WINDOW + 1);
        seasons.record(id);
        assertEq(seasons.bestOf(0, alice)[0], newScore, "the recorded score is the lowest panel's");
        (, uint256 season,) = seasons.currentSeason();
        uint256 feesBefore = seasons.seasonFees(season);
        tribunal.settle(oid);
        assertEq(seasons.pot(), potBefore + STAKE, "the stake joins the prize pot");
        assertEq(seasons.seasonFees(season) - feesBefore, STAKE, "and is accounted to the running season");
    }

    function test_overruledAboveTheOriginalKeepsTheOriginalScore() public {
        uint256 id = approvedBy(alice);
        uint256 oid = objectTo(bob, id);
        assertTrue(rule(oid, 45));
        skip(WINDOW + 1);
        seasons.record(id);
        assertEq(seasons.bestOf(0, alice)[0], 40);
    }

    function test_marginEdge() public {
        uint256 id = approvedBy(alice);
        uint8 n = need(id);
        uint256 oid = objectTo(bob, id);
        assertTrue(rule(oid, n - 3)); // n - 3 + 2 < n: sustained
        assertEq(uint8(ruling(oid)), uint8(Tribunal.Ruling.Sustained));
        uint256 id2 = approvedBy(carol);
        uint256 oid2 = objectTo(bob, id2);
        assertTrue(rule(oid2, n - 2)); // n - 2 + 2 == n: not below, overruled
        assertEq(uint8(ruling(oid2)), uint8(Tribunal.Ruling.Overruled));
    }

    function test_voidObjectionReturnsTheStakeAndFreesTheSlot() public {
        uint256 id = approvedBy(alice);
        uint256 before = imd.balanceOf(bob);
        uint256 oid = objectTo(bob, id);
        bytes32 intakeId = tribunal.objection(oid).intakeId;
        vm.expectEmit(true, true, false, true);
        emit Tribunal.ObjectionVoid(oid, id, 2, bytes32("disagreed"));
        intake.fail(intakeId, 2, bytes32("disagreed"), 4, 29);
        assertEq(uint8(ruling(oid)), uint8(Tribunal.Ruling.Void));
        (bool held, bool sustained, uint8 lowest) = standing(id);
        assertTrue(held, "the window is still open");
        assertFalse(sustained);
        assertEq(lowest, tribunal.NO_SCORE());
        tribunal.settle(oid);
        assertEq(
            imd.balanceOf(bob),
            before - (tribunal.mintOracleFee() ? 0 : FEE),
            "void: the stake comes back, only the fee is spent"
        );
        // The same wallet may object again: a void ruling does not count.
        uint256 oid2 = objectTo(bob, id);
        assertTrue(rule(oid2, 44));
        assertEq(tribunal.caseOf(id).count, 1);
    }

    function test_expireByTimeAndByACompletedRequest() public {
        uint256 id = approvedBy(alice);
        uint256 oid = objectTo(bob, id);
        vm.expectRevert(Tribunal.NotStale.selector);
        tribunal.expire(oid);
        skip(20 minutes + 1);
        tribunal.expire(oid);
        assertEq(uint8(ruling(oid)), uint8(Tribunal.Ruling.Void));
        vm.expectRevert(Tribunal.NotPending.selector);
        tribunal.expire(oid);

        uint256 id2 = approvedBy(carol);
        uint256 oid2 = objectTo(bob, id2);
        intake.setFailureHooks(false); // Intake v1 behaviour: completed, no failure call
        intake.fail(tribunal.objection(oid2).intakeId, 1, bytes32("refused"), 0, 0);
        assertEq(uint8(ruling(oid2)), uint8(Tribunal.Ruling.Pending));
        (bool held,,) = standing(id2);
        assertTrue(held, "still inside the window");
        tribunal.expire(oid2);
        assertEq(uint8(ruling(oid2)), uint8(Tribunal.Ruling.Void));
    }

    function test_aStalePendingObjectionNeverHoldsPastTheWindow() public {
        // Stale by completion: the Intake completed the request (here with our callback refusing a
        // short panel) but no ruling landed. The hold ends with the window, and a late answer is
        // impossible because the Intake completes a request once.
        uint256 id = approvedBy(alice);
        uint256 oid = objectTo(bob, id);
        bytes32 rid = tribunal.objection(oid).intakeId;
        OracleAttestation.Attestation memory a = attestation(10, keccak256("short panel"));
        a.agreed = 16;
        assertFalse(intake.complete(rid, 0, abi.encode(rid, a, signFor(address(tribunal), a))), "callback reverted");
        (,,, bool completed) = intake.requests(rid);
        assertTrue(completed);
        assertEq(uint8(ruling(oid)), uint8(Tribunal.Ruling.Pending));
        (bool held,,) = standing(id);
        assertTrue(held, "the window is still open for another objector");
        skip(WINDOW + 1);
        (held,,) = standing(id);
        assertFalse(held, "stale by completion: nothing holds the plea");
        seasons.record(id);
        assertEq(seasons.bestOf(0, alice)[0], 40, "the original score: no panel ruled");
        tribunal.expire(oid);
        tribunal.settle(oid);

        // Stale by time: 20 minutes without an answer, the Intake still open.
        uint256 id2 = approvedBy(carol);
        skip(WINDOW - 1);
        uint256 oid2 = objectTo(bob, id2);
        skip(tribunal.PENDING_EXPIRY());
        (held,,) = standing(id2);
        assertTrue(held, "last second of the ruling");
        vm.expectRevert(abi.encodeWithSelector(Seasons.Held.selector, id2));
        seasons.record(id2);
        skip(1);
        (held,,) = standing(id2);
        assertFalse(held, "stale by time");
        seasons.record(id2);
        // the late answer is refused and changes nothing
        bytes32 rid2 = tribunal.objection(oid2).intakeId;
        OracleAttestation.Attestation memory late = attestation(0, keccak256("late"));
        assertFalse(intake.complete(rid2, 0, abi.encode(rid2, late, signFor(address(tribunal), late))));
        (, bool sustained,) = standing(id2);
        assertFalse(sustained);
        assertTrue(seasons.recorded(id2));
    }

    function test_aStalePendingObjectionIsVoidedByTheNextObjector() public {
        uint256 id = approvedBy(alice);
        uint256 oid = objectTo(bob, id);
        skip(20 minutes);
        // Bob's objection is 20 minutes old (stale next second); the window closes at the same time.
        // Carol no longer waits for it (round 5, R5-A1-1): she files beside it in the last second.
        uint256 oidC = objectTo(carol, id);
        assertEq(tribunal.caseOf(id).pending[0], oid);
        assertEq(tribunal.caseOf(id).pending[1], oidC);
        skip(1);
        assertEq(uint8(ruling(oid)), uint8(Tribunal.Ruling.Pending), "nobody voided it yet");
        (bool held,,) = standing(id);
        assertTrue(held, "carol's objection holds the points");
        assertEq(tribunal.status(id), string.concat("Plea #", vm.toString(id), unicode" · OBJECTION #", vm.toString(oidC), " pending"));
        skip(20 minutes);
        (held,,) = standing(id);
        assertFalse(held, "a stale objection never holds the points");
        // A request the Intake completed without an answer (v1 style, no failure call) is stale at
        // once: the next objector voids it and takes the slot inside the window.
        uint256 id2 = approvedBy(carol);
        uint256 oid2 = objectTo(bob, id2);
        intake.setFailureHooks(false);
        intake.fail(tribunal.objection(oid2).intakeId, 2, bytes32("disagreed"), 3, 28);
        skip(1 minutes);
        uint256 oid3 = objectTo(dave, id2);
        assertEq(uint8(ruling(oid2)), uint8(Tribunal.Ruling.Void));
        assertEq(uint8(ruling(oid3)), uint8(Tribunal.Ruling.Pending));
        assertEq(tribunal.caseOf(id2).pending[0], oid3);
        tribunal.settle(oid2); // bob's stake comes back
    }

    // ---------------------------------------------------------------- window and case

    function test_windowEdges() public {
        uint256 id = approvedBy(alice);
        uint64 at = gate.getPlea(id).verdictAt;
        vm.warp(at + WINDOW);
        uint256 oid = objectTo(bob, id);
        assertTrue(rule(oid, 44));
        uint256 id2 = approvedBy(carol);
        vm.warp(gate.getPlea(id2).verdictAt + WINDOW + 1);
        objectFails(bob, id2, abi.encodeWithSelector(Tribunal.WindowClosed.selector, id2));
        (bool held,,) = standing(id2);
        assertFalse(held);
    }

    function test_atMostTwoRulingsFromDifferentWallets() public {
        uint256 id = approvedBy(alice);
        uint256 o1 = objectTo(bob, id);
        objectFails(bob, id, Tribunal.SameObjector.selector);
        assertTrue(rule(o1, 42));
        objectFails(bob, id, Tribunal.SameObjector.selector);
        uint256 o2 = objectTo(carol, id);
        objectFails(dave, id, abi.encodeWithSelector(Tribunal.ObjectionPending.selector, o2));
        assertTrue(rule(o2, 39));
        (bool held,, uint8 lowest) = standing(id);
        assertFalse(held, "two rulings: nothing more can be filed, points may be recorded");
        assertEq(lowest, 39);
        objectFails(dave, id, abi.encodeWithSelector(Tribunal.CaseClosed.selector, id));
        seasons.record(id); // inside the window, yet free
        assertEq(seasons.bestOf(0, alice)[0], 39);
    }

    /// @dev Round 5, R5-A1-1: two objections from different wallets may be pending at once, so a
    /// sham filed in the window's last second cannot keep a rival out. A third waits for a void.
    function test_twoObjectionsMayBePendingAtOnce() public {
        uint256 id = approvedBy(alice);
        uint256 o1 = objectTo(bob, id);
        uint256 o2 = objectTo(carol, id);
        objectFails(dave, id, abi.encodeWithSelector(Tribunal.ObjectionPending.selector, o1));
        assertEq(
            tribunal.status(id),
            string.concat(
                "Plea #", vm.toString(id), unicode" · OBJECTIONS #", vm.toString(o1), " and #", vm.toString(o2), " pending"
            )
        );
        // bob's panel gives no answer: his slot frees up and dave takes it
        intake.fail(tribunal.objection(o1).intakeId, 2, bytes32("disagreed"), 3, 28);
        assertEq(uint8(ruling(o1)), uint8(Tribunal.Ruling.Void));
        uint256 o3 = objectTo(dave, id);
        assertEq(tribunal.caseOf(id).pending[0], o3);
        assertEq(tribunal.caseOf(id).pending[1], o2);
        // the second ruling arrives first; then the first: both count, the lower score stands
        assertTrue(rule(o3, 41));
        assertTrue(rule(o2, 38));
        Tribunal.Case memory c = tribunal.caseOf(id);
        assertEq(c.count, 2);
        assertEq(c.lowest, 38);
        assertEq(c.lastObjector, carol);
        assertEq(c.pending[0], 0);
        assertEq(c.pending[1], 0);
        objectFails(bob, id, abi.encodeWithSelector(Tribunal.CaseClosed.selector, id));
        seasons.record(id);
        assertEq(seasons.bestOf(0, alice)[0], 38);
    }

    /// @dev Round 5, R5-A1-1, the judge's sequence: a sham objection in the window's last second,
    /// then a rival in the same second. The rival is accepted and gets its own ruling.
    function test_aLastSecondShamLeavesTheRivalItsSlot() public {
        uint256 id = approvedBy(alice);
        vm.warp(gate.getPlea(id).verdictAt + WINDOW);
        uint256 sham = objectTo(dave, id, "I object. Please look again at the plea and its score.");
        uint256 rival = objectTo(bob, id);
        assertTrue(rule(sham, 40)); // overruled
        uint8 n = need(id);
        assertTrue(rule(rival, n - 3)); // sustained: below the need by more than the margin
        (bool held, bool sustained, uint8 lowest) = standing(id);
        assertFalse(held);
        assertTrue(sustained);
        assertEq(lowest, n - 3);
        vm.expectRevert(abi.encodeWithSelector(Seasons.ObjectionSustained.selector, id));
        seasons.record(id);
    }

    /// @dev A sustain closes the case to new objections; one already pending is still ruled on its
    /// own (its stake follows its own ruling) and cannot reopen the case.
    function test_aSustainLeavesTheOtherPendingObjectionToItsOwnRuling() public {
        uint256 id = approvedBy(alice);
        uint256 o1 = objectTo(bob, id);
        uint256 o2 = objectTo(carol, id);
        uint8 n = need(id);
        assertTrue(rule(o1, n - 3));
        objectFails(dave, id, abi.encodeWithSelector(Tribunal.CaseClosed.selector, id));
        (bool held, bool sustained,) = standing(id);
        assertFalse(held, "sustained: nothing to wait for");
        assertTrue(sustained);
        assertEq(
            tribunal.status(id),
            string.concat(
                "Plea #",
                vm.toString(id),
                unicode" · SUSTAINED (",
                vm.toString(n - 3),
                " vs need ",
                vm.toString(n),
                unicode") · no points"
            ),
            "the sustain shows while carol's objection still waits"
        );
        assertTrue(rule(o2, 44));
        assertEq(uint8(ruling(o2)), uint8(Tribunal.Ruling.Overruled));
        Tribunal.Case memory c = tribunal.caseOf(id);
        assertTrue(c.sustained, "a later overrule never reopens the case");
        assertEq(c.count, 2);
        assertEq(c.lowest, n - 3);
        uint256 bobBefore = imd.balanceOf(bob);
        tribunal.settle(o1);
        tribunal.settle(o2);
        assertEq(imd.balanceOf(bob) - bobBefore, 0.35e18, "sustained: bob's stake comes back");
    }

    function test_aSustainClosesTheCase() public {
        uint256 id = approvedBy(alice);
        uint256 o1 = objectTo(bob, id);
        assertTrue(rule(o1, 0));
        objectFails(carol, id, abi.encodeWithSelector(Tribunal.CaseClosed.selector, id));
    }

    // ---------------------------------------------------------------- eligibility

    function test_theSellerAndTheOwnersCannotObject() public {
        uint256 id = approvedBy(alice);
        objectFails(alice, id, Tribunal.NotEligible.selector);
        fund(OWNER);
        objectFails(OWNER, id, Tribunal.NotEligible.selector);
    }

    function test_anExcludedSellersPleaCannotBeObjectedTo() public {
        fund(OWNER);
        buy(OWNER, 50e18);
        skip(2 hours);
        uint256 id = approvedPlea(OWNER, 45);
        objectFails(bob, id, Tribunal.SellerExcluded.selector);
    }

    function test_anExcludedSellersPleaIsNeverHeld() public {
        fund(OWNER);
        buy(OWNER, 50e18);
        uint256 id = approvedPlea(OWNER, 45);
        (bool held, bool sustained, uint8 lowest) = tribunal.standing(id);
        assertFalse(held, "nobody may object, so nothing waits");
        assertFalse(sustained);
        assertEq(lowest, 255);
        assertEq(
            tribunal.status(id),
            string.concat(
                unicode"Plea #", vm.toString(id), unicode" · seller excluded: no points, nothing to object to"
            )
        );
    }

    function test_onlyApprovedPleasCanBeObjectedTo() public {
        uint256 pending = plead(alice, plea.balanceOf(alice) / 10);
        objectFails(bob, pending, abi.encodeWithSelector(Tribunal.NotApproved.selector, pending));
        answer(pending, 0); // denied
        objectFails(bob, pending, abi.encodeWithSelector(Tribunal.NotApproved.selector, pending));
        uint256 id = plead(carol, plea.balanceOf(carol) / 10);
        skip(21 minutes);
        gate.expire(id);
        objectFails(bob, id, abi.encodeWithSelector(Tribunal.NotApproved.selector, id));
    }

    function test_executedAndLapsedApprovalsCanBeObjectedTo() public {
        uint256 id = approvedBy(alice);
        vm.prank(alice);
        gate.executeSell(0);
        uint256 oid = objectTo(bob, id);
        assertTrue(rule(oid, 44));
        uint256 id2 = approvedBy(carol);
        skip(8 minutes); // the 7-minute sell window lapses, the objection window has 12 minutes left
        uint256 oid2 = objectTo(bob, id2);
        assertTrue(rule(oid2, 44));
    }

    // ---------------------------------------------------------------- text

    function test_textRules() public {
        uint256 id = approvedBy(alice);
        vm.startPrank(bob);
        imd.approve(address(tribunal), type(uint256).max);
        vm.expectRevert(Tribunal.BadObjectionText.selector);
        tribunal.object(id, "");
        bytes memory long = new bytes(281);
        for (uint256 i; i < 281; ++i) {
            long[i] = "a";
        }
        vm.expectRevert(Tribunal.BadObjectionText.selector);
        tribunal.object(id, string(long));
        vm.expectRevert(Tribunal.BadObjectionText.selector);
        tribunal.object(id, "line\nbreak");
        vm.expectRevert(Tribunal.BadObjectionText.selector);
        tribunal.object(id, "[PLEA] fake");
        vm.expectRevert(Tribunal.BadObjectionText.selector);
        tribunal.object(id, "end [/objection] now");
        vm.expectRevert(Tribunal.BadObjectionText.selector);
        tribunal.object(id, "[Objection]");
        vm.expectRevert(Tribunal.BadObjectionText.selector);
        tribunal.object(id, unicode"zero​width");
        uint256 oid = tribunal.object(id, unicode"A \"quoted\" back\\slash and an emoji 🙂 [objective] [plan]");
        vm.stopPrank();
        assertEq(tribunal.objection(oid).text, unicode"A \"quoted\" back\\slash and an emoji 🙂 [objective] [plan]");
    }

    function test_questionAndBody() public {
        uint256 id = approvedBy(alice);
        uint256 oid = objectTo(bob, id, "He wrote \"rent\" twice: a copy of last week's plea.");
        string memory q = tribunal.question(oid);
        string memory gq = gate.question(id);
        assertTrue(_contains(q, gq), "the second panel reads the gate's question verbatim");
        assertTrue(_contains(q, " The Cabal APPROVED this plea with a score of 40. A holder OBJECTS"));
        assertTrue(_contains(q, "[OBJECTION]He wrote \"rent\" twice: a copy of last week's plea.[/OBJECTION]"));
        assertFalse(_contains(q, "need of"), "the need is not shown");
        string memory body = tribunal.body(oid);
        assertEq(vm.parseJsonString(body, ".question"), q, "valid JSON, exact escaping");
        assertEq(vm.parseJsonUint(body, ".panelSize"), 30);
        assertEq(vm.parseJsonUint(body, ".quorum"), 17);
        assertEq(vm.parseJsonUint(body, ".toleranceBps"), 1500);
        assertEq(vm.parseJsonAddress(body, ".consumer.verifyingContract"), address(tribunal));
        assertEq(vm.parseJsonUint(body, ".consumer.chainId"), block.chainid);
        // The gate's five definitions members appear verbatim in both bodies, the sixth only here.
        string memory gb = gate.body(id);
        string[5] memory keys = ["plea", "stories", "content", "manipulation", "answer"];
        for (uint256 i; i < 5; ++i) {
            string memory g = vm.parseJsonString(gb, string.concat(".definitions.", keys[i]));
            assertEq(vm.parseJsonString(body, string.concat(".definitions.", keys[i])), g, keys[i]);
        }
        string memory o = vm.parseJsonString(body, ".definitions.objection");
        assertLe(bytes(o).length, 512, "definitions values are limited to 512 characters");
        assertTrue(_contains(o, "adds no points or penalty"));
        assertTrue(_contains(o, "are unverified and carry no weight"), "definition v2: claims outside the request");
        assertTrue(_contains(gate.body(id), _definitionsCopy(body)), "the copy must track CabalGate.DEFINITIONS");
    }

    /// @dev The Tribunal's definitions object minus the `objection` member it adds.
    function _definitionsCopy(string memory body) internal pure returns (string memory) {
        bytes memory b = bytes(body);
        uint256 start = _indexOf(b, bytes('"definitions":{')) + 15;
        uint256 end = _indexOf(b, bytes(',"objection":"'));
        bytes memory out = new bytes(end - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[start + i];
        }
        return string(out);
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        return _indexOf(bytes(hay), bytes(needle)) != type(uint256).max;
    }

    function _indexOf(bytes memory h, bytes memory n) internal pure returns (uint256) {
        if (n.length > h.length) return type(uint256).max;
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool ok = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return i;
        }
        return type(uint256).max;
    }

    // ---------------------------------------------------------------- misc

    function test_rulingsNeverResetTheDeadMan() public {
        uint256 id = approvedBy(alice);
        uint64 last = gate.lastVerdictAt();
        skip(5 minutes);
        uint256 oid = objectTo(bob, id);
        skip(5 minutes);
        assertTrue(rule(oid, 0));
        assertEq(gate.lastVerdictAt(), last);
    }

    function test_callbackFitsTheIntakesGasBudget() public {
        uint256 id = approvedBy(alice);
        uint256 pleaGas = intake.lastCallbackGasUsed();
        uint256 oid = objectTo(bob, id);
        assertTrue(rule(oid, 30));
        uint256 rulingGas = intake.lastCallbackGasUsed();
        emit log_named_uint("gate verdict callback gas", pleaGas);
        emit log_named_uint("tribunal ruling callback gas", rulingGas);
        assertLt(rulingGas, 150_000, "well under the Intake's 200k callback gas");
    }

    function test_statusText() public {
        uint256 id = approvedBy(alice);
        assertTrue(_contains(tribunal.status(id), "objections open until"));
        uint256 oid = objectTo(bob, id);
        assertTrue(_contains(tribunal.status(id), "OBJECTION #1 pending"));
        assertTrue(rule(oid, need(id) - 2));
        assertTrue(_contains(tribunal.status(id), "OVERRULED ("));
        assertTrue(_contains(tribunal.status(id), "counts "));
        skip(WINDOW + 1);
        assertTrue(_contains(tribunal.status(id), "objections closed"));
        uint256 id2 = approvedBy(carol);
        uint256 oid2 = objectTo(bob, id2);
        assertTrue(rule(oid2, 1));
        assertTrue(_contains(tribunal.status(id2), unicode"SUSTAINED (1 vs need"));
        assertTrue(_contains(tribunal.status(id2), "no points"));
        assertTrue(_contains(tribunal.status(99), "not approved"));
    }

    /// @dev Round 6 (R6-A1-1): the overruled line counts a seat holder's points (score x 1.2), the
    /// provisional figure before the recording and `Seasons.pointsOf` after it.
    function test_statusCountsTheSeatMultiplier() public {
        seat.mint(alice);
        uint256 id = approvedBy(alice);
        uint256 oid = objectTo(bob, id);
        uint8 n = need(id);
        assertTrue(rule(oid, n)); // overruled at the need
        uint8 pts = seasons.pointsFor(alice, n);
        assertEq(pts, uint8(uint256(n) * 12 / 10));
        assertTrue(_contains(tribunal.status(id), string.concat("counts ", vm.toString(pts), " points")));
        skip(WINDOW + 1);
        seasons.record(id);
        assertEq(seasons.pointsOf(id), pts);
        assertTrue(_contains(tribunal.status(id), string.concat("counts ", vm.toString(pts), " points")));
        seat.burn(alice); // the recorded figure stays what Seasons counted
        assertTrue(_contains(tribunal.status(id), string.concat("counts ", vm.toString(pts), " points")));
    }

    function test_settleNeedsARuling() public {
        uint256 id = approvedBy(alice);
        uint256 oid = objectTo(bob, id);
        vm.expectRevert(abi.encodeWithSelector(Tribunal.NotRuled.selector, oid));
        tribunal.settle(oid);
        vm.expectRevert(abi.encodeWithSelector(Tribunal.NotRuled.selector, 7));
        tribunal.settle(7);
    }
}

/// @notice Mainnet path: the oracle fee is pool IMD and the objector pays it with the stake.
contract TribunalMainnetFeeTest is TribunalTest {
    function oracleFeeToken() internal view override returns (MockIMD) {
        return imd;
    }

    function test_theObjectorPaysFeeAndStakeInImd() public {
        uint256 id = approvedBy(alice);
        uint256 before = imd.balanceOf(bob);
        uint256 paidBefore = imd.balanceOf(intake.PAY_TO());
        objectTo(bob, id);
        assertEq(imd.balanceOf(bob), before - STAKE - FEE);
        assertEq(imd.balanceOf(intake.PAY_TO()), paidBefore + FEE);
        assertFalse(tribunal.mintOracleFee());
    }
}
