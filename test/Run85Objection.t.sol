// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SepoliaFixture} from "./utils/SepoliaFixture.sol";
import {MockIMD, MockIntake} from "./utils/Mocks.sol";
import {PLEA} from "../src/PLEA.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {Seasons} from "../src/Seasons.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {PleaLaunch} from "../src/PleaLaunch.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";

/// @dev Run 8.5 rehearsal of Objection! under the default build profile (the full suite in
/// test/full/ is skipped by a bare `forge test`). Sepolia timings (18000 / 118800), the real gate,
/// Seasons, Tribunal, PLEA and pool; only the Intake, the fee tokens and the Stacker are mocks.
/// Every test here is a refusal or an edge; the happy path is only the setup.
contract Run85ObjectionTest is SepoliaFixture {
    uint256 constant STAKE = 0.35e18;
    uint256 constant FEE = 0.5e18;
    uint256 constant WINDOW = 20 minutes;

    address dave = makeAddr("dave");
    address erin = makeAddr("erin");

    function withTribunal() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        fund(dave);
        fund(erin);
        for (uint256 i; i < users.length; ++i) {
            buy(users[i], 50e18);
        }
        skip(1 days);
    }

    /// @dev An approved plea from `who` with the lowest passing score, so that a re-score below it
    /// by more than the margin is always available.
    function approvedAtNeed(address who) internal returns (uint256 id, uint8 need) {
        id = plead(who, plea.balanceOf(who) / 10);
        need = gate.getPlea(id).need;
        require(answer(id, need), "not delivered");
    }

    // ---------------------------------------------------------------- the agreed numbers

    function test_theAgreedObjectionNumbersAreCompiledIn() public view {
        assertEq(tribunal.OBJECTION_WINDOW(), 20 minutes);
        assertEq(tribunal.PENDING_EXPIRY(), 20 minutes);
        assertEq(tribunal.STAKE(), 0.35e18);
        assertEq(tribunal.ORACLE_FEE(), 0.5e18);
        assertEq(tribunal.MAX_OBJECTIONS(), 2);
        assertEq(tribunal.MARGIN(), 2);
        assertEq(tribunal.MAX_PLEA_SCORE(), 45);
        assertEq(tribunal.PANEL_SIZE(), 30);
        assertEq(tribunal.QUORUM(), 17);
        assertEq(tribunal.MAX_TEXT_BYTES(), 280);
        assertEq(gate.PASS_MARK(), 71);
        assertEq(gate.MAX_PLEA_SCORE(), 45);
        assertEq(gate.SEASON(), 18_000);
        assertEq(gate.DEADMAN(), 118_800);
        assertEq(seasons.SEAT_MULTIPLIER_BPS(), 12_000);
        // The Tribunal read its settings from the launch, not from a constructor argument.
        assertEq(address(tribunal.gate()), address(gate));
        assertEq(address(tribunal.seasons()), address(seasons));
        assertEq(address(tribunal.imd()), address(imd));
        assertEq(address(tribunal.oracleAsset()), address(oimd));
        assertTrue(tribunal.mintOracleFee(), "Sepolia mints the test oracle fee");
        assertEq(address(tribunal), launch.predictTribunal());
        assertEq(address(tribunal), launch.tribunal());
    }

    /// @dev The committed Tribunal deploys once, from the exact code, and seed waited for it.
    function test_theTribunalDeploysOnceFromTheCommittedCodeOnly() public {
        bytes memory code = vm.getCode("Tribunal.sol:Tribunal");
        vm.expectRevert(PleaLaunch.TribunalAlreadyDeployed.selector);
        launch.deployTribunal(code);
        vm.expectRevert(PleaLaunch.TribunalAlreadyDeployed.selector);
        launch.deployTribunal(bytes.concat(code, hex"00"));
    }

    // ---------------------------------------------------------------- the text rules

    /// @dev The text is checked before anything else, so a bad text is refused on any plea id,
    /// without a stake, a fee or a request.
    function refused(bytes memory text) internal {
        uint256 feeNonce = intake.nonce();
        vm.prank(dave);
        vm.expectRevert(Tribunal.BadObjectionText.selector);
        tribunal.object(1, string(text));
        assertEq(intake.nonce(), feeNonce, "a refused text asks no panel");
    }

    function test_textRefusesEmptyOverlongControlAndMalformedBytes() public {
        refused("");
        bytes memory long = new bytes(281);
        for (uint256 i; i < 281; ++i) {
            long[i] = "a";
        }
        refused(long);
        refused("tab\there");
        refused("new\nline");
        refused(hex"7f");
        refused(hex"c0af"); // overlong encoding of '/'
        refused(hex"e080af"); // overlong 3-byte
        refused(hex"f0808080"); // overlong 4-byte
        refused(hex"eda080"); // a surrogate (U+D800)
        refused(hex"f4908080"); // above U+10FFFF
        refused(hex"c3"); // a truncated sequence
        refused(hex"80"); // a lone continuation byte
    }

    /// @dev R7-A1-2 and R8-A1-1: every Unicode format, variation-selector and default-ignorable
    /// character is refused, so an objection cannot hide instructions from the panel.
    function test_textRefusesFormatVariationSelectorAndDefaultIgnorableCharacters() public {
        refused(unicode"soft­hyphen");
        refused(unicode"zero​width");
        refused(unicode"joiner‍");
        refused(bytes.concat("bidi", hex"e280ae", "override")); // U+202E right-to-left override
        refused(unicode"word⁠joiner");
        refused(unicode"bom﻿");
        refused(unicode"vs15︎");
        refused(unicode"vs16️");
        refused(bytes.concat("ivs", hex"f3a08480")); // U+E0100, a variation selector supplement
        refused(bytes.concat("tag", hex"f3a08181")); // U+E0041, a tag character
        refused(unicode"cgj͏");
        refused(unicode"hangul fillerᅟ");
        refused(unicode"halfwidth fillerﾠ");
        refused(unicode"mongolian᠎");
        refused(unicode"khmer឴");
        refused(unicode"arabic sign؀");
        refused(unicode"syriac܏");
        refused(unicode"interlinear￹");
        refused(bytes.concat("musical", hex"f09d85b3")); // U+1D173
        refused(bytes.concat("line", hex"e280a8", "separator")); // U+2028
        refused(bytes.concat("c1 control", hex"c285")); // U+0085
        refused(bytes.concat("egyptian", hex"f09390b0")); // U+13430
        refused("a [PLEA marker");
        refused("a [/plea marker");
        refused("an [Objection] marker");
        refused("an [/OBJECTION] marker");
    }

    function test_textAcceptsOrdinaryUnicodeUpToTheLimit() public {
        (uint256 id,) = approvedAtNeed(alice);
        bytes memory long = new bytes(280);
        for (uint256 i; i < 280; ++i) {
            long[i] = "x";
        }
        uint256 a = objectTo(dave, id, string(long));
        assertEq(bytes(tribunal.objection(a).text).length, 280);
        uint256 b = objectTo(erin, id, unicode"café, 日本語, emoji 🎉 and a [plan] in brackets: all fine");
        assertEq(b, a + 1);
    }

    // ---------------------------------------------------------------- who may object, and when

    function test_theSellerAndExcludedWalletsCannotObject() public {
        (uint256 id,) = approvedAtNeed(alice);
        objectFails(alice, id, Tribunal.NotEligible.selector);
        assertTrue(seasons.excluded(OWNER), "the owner never earns points and never objects");
        imd.mint(OWNER, 1e18);
        objectFails(OWNER, id, Tribunal.NotEligible.selector);
    }

    function test_onlyAnApprovalInItsWindowCanBeObjectedTo() public {
        objectFails(dave, 0, abi.encodeWithSelector(Tribunal.NotApproved.selector, 0));
        objectFails(dave, 99, abi.encodeWithSelector(Tribunal.NotApproved.selector, 99));
        uint256 pending = plead(bob, plea.balanceOf(bob) / 10);
        objectFails(dave, pending, abi.encodeWithSelector(Tribunal.NotApproved.selector, pending));
        require(answer(pending, 0), "not delivered"); // denied
        objectFails(dave, pending, abi.encodeWithSelector(Tribunal.NotApproved.selector, pending));
        (uint256 id,) = approvedAtNeed(alice);
        uint64 verdictAt = gate.getPlea(id).verdictAt;
        vm.warp(uint256(verdictAt) + WINDOW); // the last second is inside the window
        uint256 oid = objectTo(dave, id);
        assertEq(tribunal.objection(oid).pleaId, id);
        vm.warp(uint256(verdictAt) + WINDOW + 1);
        objectFails(erin, id, abi.encodeWithSelector(Tribunal.WindowClosed.selector, id));
    }

    function test_aRecordedPleaIsOutOfReach() public {
        (uint256 id,) = approvedAtNeed(alice);
        uint64 verdictAt = gate.getPlea(id).verdictAt;
        vm.expectRevert(abi.encodeWithSelector(Seasons.Held.selector, id));
        seasons.record(id);
        vm.warp(uint256(verdictAt) + WINDOW + 1);
        seasons.record(id);
        assertTrue(seasons.recorded(id));
        objectFails(dave, id, abi.encodeWithSelector(Tribunal.WindowClosed.selector, id));
    }

    function test_objectingNeedsTheStakeInPoolImd() public {
        (uint256 id,) = approvedAtNeed(alice);
        address poor = makeAddr("poor");
        imd.mint(poor, STAKE - 1);
        vm.startPrank(poor);
        imd.approve(address(tribunal), type(uint256).max);
        vm.expectRevert();
        tribunal.object(id, "I object.");
        vm.stopPrank();
        imd.mint(poor, 1);
        vm.prank(poor);
        tribunal.object(id, "I object.");
        assertEq(imd.balanceOf(poor), 0);
        assertEq(imd.balanceOf(address(tribunal)), STAKE);
        assertEq(oimd.balanceOf(address(tribunal)), 0, "the minted fee went to the Intake in full");
        assertEq(oimd.balanceOf(intake.PAY_TO()), FEE * 2, "one plea fee, one objection fee");
    }

    function test_twoPendingFromDifferentWalletsThenTheCaseIsFull() public {
        (uint256 id,) = approvedAtNeed(alice);
        uint256 a = objectTo(dave, id);
        objectFails(dave, id, Tribunal.SameObjector.selector);
        uint256 b = objectTo(erin, id);
        Tribunal.Case memory c = tribunal.caseOf(id);
        assertEq(c.pending[0], a);
        assertEq(c.pending[1], b);
        objectFails(carol, id, abi.encodeWithSelector(Tribunal.ObjectionPending.selector, a));
        // The first ruling frees a slot but the count now forbids a third wallet: one more at most.
        assertTrue(rule(a, 45));
        objectFails(carol, id, abi.encodeWithSelector(Tribunal.ObjectionPending.selector, b));
        assertTrue(rule(b, 45));
        objectFails(carol, id, abi.encodeWithSelector(Tribunal.CaseClosed.selector, id));
        (bool held, bool sustained, uint8 lowest) = tribunal.standing(id);
        assertFalse(held);
        assertFalse(sustained);
        assertEq(lowest, 45);
    }

    function test_aRuledObjectorCannotFileTheSecondOne() public {
        (uint256 id,) = approvedAtNeed(alice);
        uint256 a = objectTo(dave, id);
        assertTrue(rule(a, 45));
        objectFails(dave, id, Tribunal.SameObjector.selector);
        uint256 b = objectTo(erin, id);
        assertEq(tribunal.caseOf(id).pending[0], b, "the freed first slot is reused");
    }

    function test_aVoidObjectionFreesItsSlotForTheSameWallet() public {
        (uint256 id,) = approvedAtNeed(alice);
        uint256 a = objectTo(dave, id);
        assertTrue(intake.fail(tribunal.objection(a).intakeId, 2, bytes32("no quorum"), 10, 30));
        assertEq(uint8(tribunal.objection(a).ruling), uint8(Tribunal.Ruling.Void));
        assertEq(tribunal.caseOf(id).count, 0, "a void ruling takes no slot");
        uint256 b = objectTo(dave, id);
        assertEq(b, a + 1);
        tribunal.settle(a);
        assertEq(imd.balanceOf(dave), 100_000e18 - STAKE, "the void stake came back, the live one is held");
    }

    // ---------------------------------------------------------------- rulings

    function test_marginEdgesSustainOnlyBelowNeedMinusMargin() public {
        (uint256 id, uint8 need) = approvedAtNeed(alice);
        require(need >= 3 && need <= 45, "need in range");
        uint256 a = objectTo(dave, id);
        assertTrue(rule(a, need - 2)); // newScore + 2 == need: not below, overruled
        assertEq(uint8(tribunal.objection(a).ruling), uint8(Tribunal.Ruling.Overruled));
        uint256 b = objectTo(erin, id);
        assertTrue(rule(b, need - 3)); // newScore + 2 < need: sustained
        assertEq(uint8(tribunal.objection(b).ruling), uint8(Tribunal.Ruling.Sustained));
        (bool held, bool sustained, uint8 lowest) = tribunal.standing(id);
        assertFalse(held);
        assertTrue(sustained);
        assertEq(lowest, need - 3, "the recorded score is the lowest any panel gave");
        vm.expectRevert(abi.encodeWithSelector(Seasons.ObjectionSustained.selector, id));
        seasons.record(id);
        (, uint8 score, bool approved,) = gate.result(id);
        assertEq(score, need, "the sale's verdict is never rewritten");
        assertTrue(approved);
    }

    function test_aHigherReScoreNeverRaisesThePlea() public {
        (uint256 id, uint8 need) = approvedAtNeed(alice);
        uint256 a = objectTo(dave, id);
        assertTrue(rule(a, 45));
        (,, uint8 lowest) = tribunal.standing(id);
        assertEq(lowest, 45);
        (, uint8 score,,) = gate.result(id);
        assertEq(score, need);
        vm.warp(uint256(gate.getPlea(id).verdictAt) + WINDOW + 1);
        seasons.record(id);
        assertEq(seasons.pointsOf(id), need, "points use the lower of the two scores");
    }

    function test_aLateOrRepeatedRulingIsRefusedAndBurnsNoNonce() public {
        (uint256 id,) = approvedAtNeed(alice);
        uint256 a = objectTo(dave, id);
        bytes32 intakeId = tribunal.objection(a).intakeId;
        skip(WINDOW + 1);
        OracleAttestation.Attestation memory att = attestation(0, keccak256("late"));
        assertFalse(intake.complete(intakeId, 0, abi.encode(intakeId, att, signFor(address(tribunal), att))));
        assertFalse(tribunal.consumed(att.requestId));
        assertEq(uint8(tribunal.objection(a).ruling), uint8(Tribunal.Ruling.Pending));
        // Completed but unruled: stale, so anyone may void it and the objector takes the stake back.
        tribunal.expire(a);
        vm.expectRevert(Tribunal.NotPending.selector);
        tribunal.expire(a);
        tribunal.settle(a);
        assertEq(imd.balanceOf(dave), 100_000e18);
        vm.expectRevert(abi.encodeWithSelector(Tribunal.AlreadySettled.selector, a));
        tribunal.settle(a);
    }

    function test_onlyTheIntakeMayRuleOrFail() public {
        (uint256 id,) = approvedAtNeed(alice);
        uint256 a = objectTo(dave, id);
        bytes32 intakeId = tribunal.objection(a).intakeId;
        OracleAttestation.Attestation memory att = attestation(0, keccak256("forged"));
        bytes memory sig = signFor(address(tribunal), att);
        vm.prank(dave);
        vm.expectRevert(Tribunal.NotIntake.selector);
        tribunal.onOracleResult(intakeId, att, sig);
        vm.prank(dave);
        vm.expectRevert(Tribunal.NotIntake.selector);
        tribunal.onObjectionFailure(intakeId, 2, bytes32("x"), 0, 0, "");
        // The gate's signature domain is worthless here.
        bytes memory gateSig = sign(att);
        vm.prank(address(intake));
        vm.expectRevert();
        tribunal.onOracleResult(intakeId, att, gateSig);
        assertEq(uint8(tribunal.objection(a).ruling), uint8(Tribunal.Ruling.Pending));
    }

    function test_wrongPanelsAndOutOfRangeScoresAreRefused() public {
        (uint256 id,) = approvedAtNeed(alice);
        uint256 a = objectTo(dave, id);
        bytes32 intakeId = tribunal.objection(a).intakeId;
        OracleAttestation.Attestation memory att = attestation(46, keccak256("46"));
        assertFalse(intake.complete(intakeId, 0, abi.encode(intakeId, att, signFor(address(tribunal), att))));
        uint256 b = objectTo(erin, id);
        intakeId = tribunal.objection(b).intakeId;
        att = attestation(10, keccak256("thin panel"));
        att.agreed = 16;
        assertFalse(intake.complete(intakeId, 0, abi.encode(intakeId, att, signFor(address(tribunal), att))));
        assertEq(tribunal.caseOf(id).count, 0);
    }

    function test_settleNeedsARulingAndPaysEachSideOnce() public {
        (uint256 id, uint8 need) = approvedAtNeed(alice);
        vm.expectRevert(abi.encodeWithSelector(Tribunal.NotRuled.selector, 1));
        tribunal.settle(1);
        uint256 a = objectTo(dave, id);
        vm.expectRevert(abi.encodeWithSelector(Tribunal.NotRuled.selector, a));
        tribunal.settle(a);
        vm.expectRevert(Tribunal.NotStale.selector);
        tribunal.expire(a);
        assertTrue(rule(a, 45));
        uint256 season = (uint256(gate.getPlea(id).verdictAt) - gate.startedAt()) / 18_000;
        uint256 potBefore = seasons.seasonFees(season);
        uint256 seasonsImd = imd.balanceOf(address(seasons));
        tribunal.settle(a);
        assertEq(imd.balanceOf(address(seasons)), seasonsImd + STAKE, "an overruled stake feeds the pot");
        assertEq(seasons.seasonFees(season), potBefore + STAKE);
        assertEq(imd.balanceOf(address(tribunal)), 0);
        vm.expectRevert(abi.encodeWithSelector(Tribunal.AlreadySettled.selector, a));
        tribunal.settle(a);
        // Nobody but the Tribunal may label a pot payment as an objection stake.
        vm.expectRevert(Seasons.NotTribunal.selector);
        seasons.checkpointObjection(id, STAKE);
        assertEq(need, gate.getPlea(id).need);
    }

    function test_rulingsNeverResetTheDeadManNorTouchTheSale() public {
        (uint256 id,) = approvedAtNeed(alice);
        uint64 verdict = gate.lastVerdictAt();
        uint256 amount = gate.getPlea(id).amount;
        uint256 a = objectTo(dave, id);
        skip(5 minutes);
        assertTrue(rule(a, 0));
        assertEq(gate.lastVerdictAt(), verdict);
        uint256 before = plea.balanceOf(alice);
        vm.prank(alice);
        gate.executeSell(0);
        assertEq(plea.balanceOf(alice), before - amount, "a sustained objection never stops the approved sale");
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Executed));
        objectFails(erin, id, abi.encodeWithSelector(Tribunal.CaseClosed.selector, id));
    }
}

// ================================================================ invariants

/// @dev Drives the Tribunal with bounded inputs: objectors file, the Intake rules, refuses or
/// stays silent, anyone expires and settles, sellers sell, time passes. Ghost variables track
/// every stake paid in and out; the contract is read only to be checked.
contract ObjectionHandler is Test {
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant STAKE = 0.35e18;
    uint256 constant WINDOW = 20 minutes;
    uint256 constant CASH = 100e18;

    struct Obj {
        uint256 pleaId;
        address objector;
        uint64 filedAt;
        bytes32 intakeId;
        Tribunal.Ruling ruling;
        bool completed;
        bool settled;
        uint8 score;
    }

    struct Model {
        address seller;
        uint64 approvedAt;
        uint8 score;
        uint8 need;
        uint8 count;
        uint8 lowest;
        bool sustained;
        uint256[2] pending;
        address lastObjector;
    }

    PLEA immutable plea;
    CabalGate immutable gate;
    Seasons immutable seasons;
    Tribunal immutable tribunal;
    MockIntake immutable intake;
    MockIMD immutable imd;
    uint64 immutable verdictClock;
    uint256 immutable seasonsCashAtStart;

    address[] public objectors;
    uint256[] public pleaIds;
    mapping(uint256 => Model) internal pleas;
    mapping(uint256 => Obj) internal objs;
    mapping(address => uint256) public deposits;
    mapping(address => uint256) public refunds;
    uint256 public opened;
    uint256 public settled;
    uint256 public toPot;
    uint256 public rulings;
    uint256 public sustains;
    uint256 public voids;
    uint256 public sales;
    uint256 public refusedFilings;
    uint256 internal nonce;

    constructor(PLEA p, CabalGate g, Seasons s, Tribunal t, MockIntake i, MockIMD m, uint256[] memory ids) {
        plea = p;
        gate = g;
        seasons = s;
        tribunal = t;
        intake = i;
        imd = m;
        verdictClock = g.lastVerdictAt();
        seasonsCashAtStart = m.balanceOf(address(s));
        for (uint256 k; k < ids.length; ++k) {
            uint256 id = ids[k];
            (address seller, uint8 score,, uint64 at) = g.result(id);
            pleaIds.push(id);
            pleas[id] = Model(seller, at, score, g.getPlea(id).need, 0, 255, false, [uint256(0), 0], address(0));
        }
        for (uint256 k; k < 3; ++k) {
            address who = makeAddr(string.concat("objector ", vm.toString(k)));
            objectors.push(who);
            m.mint(who, CASH);
            vm.prank(who);
            m.approve(address(t), type(uint256).max);
        }
    }

    function file(uint256 pleaSeed, uint256 actorSeed) public {
        uint256 id = pleaIds[bound(pleaSeed, 0, pleaIds.length - 1)];
        Model storage p = pleas[id];
        address who = objectors[bound(actorSeed, 0, objectors.length - 1)];
        bool stale0 = p.pending[0] != 0 && _stale(objs[p.pending[0]]);
        bool stale1 = p.pending[1] != 0 && _stale(objs[p.pending[1]]);
        uint256 live0 = stale0 ? 0 : p.pending[0];
        uint256 live1 = stale1 ? 0 : p.pending[1];
        uint256 waiting = (live0 != 0 ? 1 : 0) + (live1 != 0 ? 1 : 0);
        bool mustFail = block.timestamp > uint256(p.approvedAt) + WINDOW || seasons.recorded(id) || p.sustained
            || p.count + waiting >= 2 || (p.count != 0 && p.lastObjector == who)
            || (live0 != 0 && objs[live0].objector == who) || (live1 != 0 && objs[live1].objector == who);
        vm.prank(who);
        try tribunal.object(id, "The craft definition was not applied: this text is boilerplate.") returns (
            uint256 oid
        ) {
            assertFalse(mustFail, "an objection the rules forbid was accepted");
            assertEq(oid, opened + 1);
            if (stale0) _void(p.pending[0]);
            if (stale1) _void(p.pending[1]);
            ++opened;
            deposits[who] += STAKE;
            objs[oid] = Obj(
                id,
                who,
                uint64(block.timestamp),
                tribunal.objection(oid).intakeId,
                Tribunal.Ruling.Pending,
                false,
                false,
                0
            );
            p.pending[p.pending[0] == 0 ? 0 : 1] = oid;
        } catch {
            assertTrue(mustFail, "an objection the rules allow was refused");
            ++refusedFilings;
        }
    }

    function rule(uint256 seed, uint256 scoreSeed) public {
        uint256 oid = _pending(seed);
        if (oid == 0) return;
        Obj storage o = objs[oid];
        uint8 score = uint8(bound(scoreSeed, 0, 45));
        OracleAttestation.Attestation memory a = _attestation(score);
        bool live = block.timestamp <= uint256(o.filedAt) + WINDOW;
        bool delivered = intake.complete(o.intakeId, 0, abi.encode(o.intakeId, a, _sign(a)));
        o.completed = true;
        assertEq(delivered, live, "a fresh ruling fits the stipend; a late one is refused");
        if (!live) return;
        Model storage p = pleas[o.pleaId];
        bool sustain = uint256(score) + 2 < p.need;
        o.score = score;
        o.ruling = sustain ? Tribunal.Ruling.Sustained : Tribunal.Ruling.Overruled;
        _clear(p, oid);
        ++p.count;
        p.lastObjector = o.objector;
        if (score < p.lowest) p.lowest = score;
        if (sustain) {
            p.sustained = true;
            ++sustains;
        }
        ++rulings;
    }

    function fail(uint256 seed, bool silent) public {
        uint256 oid = _pending(seed);
        if (oid == 0) return;
        Obj storage o = objs[oid];
        intake.setFailureHooks(!silent);
        assertEq(intake.fail(o.intakeId, 2, bytes32("no quorum"), 0, 30), !silent);
        intake.setFailureHooks(true);
        o.completed = true;
        if (!silent) _void(oid);
    }

    function expire(uint256 seed) public {
        if (opened == 0) return;
        uint256 oid = bound(seed, 1, opened);
        Obj storage o = objs[oid];
        bool pending = o.ruling == Tribunal.Ruling.Pending;
        if (!pending || !_stale(o)) {
            vm.expectRevert(pending ? Tribunal.NotStale.selector : Tribunal.NotPending.selector);
            tribunal.expire(oid);
            return;
        }
        tribunal.expire(oid);
        _void(oid);
    }

    function settle(uint256 seed) public {
        if (opened == 0) return;
        uint256 oid = bound(seed, 1, opened);
        Obj storage o = objs[oid];
        if (o.ruling == Tribunal.Ruling.Pending) {
            vm.expectRevert(abi.encodeWithSelector(Tribunal.NotRuled.selector, oid));
            tribunal.settle(oid);
            return;
        }
        if (o.settled) {
            vm.expectRevert(abi.encodeWithSelector(Tribunal.AlreadySettled.selector, oid));
            tribunal.settle(oid);
            return;
        }
        uint256 cash = imd.balanceOf(o.objector);
        uint256 pot = imd.balanceOf(address(seasons));
        tribunal.settle(oid);
        o.settled = true;
        ++settled;
        if (o.ruling == Tribunal.Ruling.Overruled) {
            toPot += STAKE;
            assertEq(imd.balanceOf(address(seasons)), pot + STAKE, "an overruled stake goes to the pot");
        } else {
            refunds[o.objector] += STAKE;
            assertEq(imd.balanceOf(o.objector), cash + STAKE, "a sustained or void stake comes back");
        }
    }

    function sell(uint256 seed) public {
        uint256 id = pleaIds[bound(seed, 0, pleaIds.length - 1)];
        CabalGate.Plea memory p = gate.getPlea(id);
        if (p.status != CabalGate.Status.Approved || block.timestamp > uint256(p.verdictAt) + 7 minutes) return;
        uint256 bal = plea.balanceOf(p.seller);
        vm.prank(p.seller);
        gate.executeSell(0);
        assertEq(plea.balanceOf(p.seller), bal - p.amount, "an approved sale never waits for the Tribunal");
        ++sales;
    }

    function advance(uint256 seed) public {
        skip(bound(seed, 1, 8 minutes));
    }

    // ---------------------------------------------------------------- the checks

    function checkCustody() external view {
        uint256 owed;
        for (uint256 oid = 1; oid <= opened; ++oid) {
            if (!objs[oid].settled) owed += STAKE;
            assertEq(tribunal.objection(oid).settled, objs[oid].settled);
        }
        assertEq(imd.balanceOf(address(tribunal)), owed, "the Tribunal holds exactly the unsettled stakes");
        assertEq(owed, (opened - settled) * STAKE);
        uint256 back;
        for (uint256 k; k < objectors.length; ++k) {
            address who = objectors[k];
            assertLe(refunds[who], deposits[who], "nobody gets back more than they staked");
            assertEq(imd.balanceOf(who), CASH - deposits[who] + refunds[who]);
            back += refunds[who];
        }
        assertEq(back + toPot, settled * STAKE, "every settled stake went to its objector or the pot");
        assertGe(imd.balanceOf(address(seasons)), seasonsCashAtStart + toPot, "the pot keeps every overruled stake");
    }

    function checkCases() external view {
        assertEq(tribunal.nextId(), opened + 1);
        assertEq(gate.lastVerdictAt(), verdictClock, "rulings never reset the dead-man");
        for (uint256 oid = 1; oid <= opened; ++oid) {
            Obj storage o = objs[oid];
            Tribunal.Objection memory actual = tribunal.objection(oid);
            assertEq(uint8(actual.ruling), uint8(o.ruling), "a ruling is final");
            assertEq(actual.objector, o.objector);
            assertEq(actual.pleaId, o.pleaId);
            if (o.ruling == Tribunal.Ruling.Sustained || o.ruling == Tribunal.Ruling.Overruled) {
                assertEq(actual.newScore, o.score);
                assertEq(
                    o.ruling == Tribunal.Ruling.Sustained,
                    uint256(o.score) + 2 < pleas[o.pleaId].need,
                    "sustained exactly when newScore + 2 < need"
                );
            }
        }
        for (uint256 k; k < pleaIds.length; ++k) {
            uint256 id = pleaIds[k];
            Model storage p = pleas[id];
            Tribunal.Case memory c = tribunal.caseOf(id);
            assertLe(c.count, 2, "at most two rulings per plea");
            assertEq(c.count, p.count);
            assertEq(c.sustained, p.sustained);
            assertEq(c.pending[0], p.pending[0]);
            assertEq(c.pending[1], p.pending[1]);
            if (c.pending[0] != 0 && c.pending[1] != 0) {
                assertTrue(objs[c.pending[0]].objector != objs[c.pending[1]].objector, "two wallets");
            }
            if (c.count == 2) assertTrue(objs[_ruled(id, 0)].objector != objs[_ruled(id, 1)].objector);
            (bool held, bool sustained, uint8 lowest) = tribunal.standing(id);
            assertEq(lowest, p.count == 0 ? 255 : p.lowest, "the recorded score is the lowest any panel gave");
            assertEq(sustained, p.sustained);
            assertEq(held, _held(p));
            if (p.sustained) assertFalse(seasons.recorded(id), "a sustained plea earns no points");
            (, uint8 score, bool approved, uint64 at) = gate.result(id);
            assertEq(score, p.score, "the sale's verdict is never rewritten");
            assertTrue(approved);
            assertEq(at, p.approvedAt);
        }
    }

    function _ruled(uint256 id, uint256 which) internal view returns (uint256 found) {
        uint256 seen;
        for (uint256 oid = 1; oid <= opened; ++oid) {
            Obj storage o = objs[oid];
            if (o.pleaId != id || o.ruling == Tribunal.Ruling.Pending || o.ruling == Tribunal.Ruling.Void) continue;
            if (seen == which) return oid;
            ++seen;
        }
    }

    function _held(Model storage p) internal view returns (bool) {
        if (p.sustained) return false;
        if (p.pending[0] != 0 && !_stale(objs[p.pending[0]])) return true;
        if (p.pending[1] != 0 && !_stale(objs[p.pending[1]])) return true;
        return p.count < 2 && block.timestamp <= uint256(p.approvedAt) + WINDOW;
    }

    function _stale(Obj storage o) internal view returns (bool) {
        return o.completed || block.timestamp > uint256(o.filedAt) + WINDOW;
    }

    function _void(uint256 oid) internal {
        objs[oid].ruling = Tribunal.Ruling.Void;
        _clear(pleas[objs[oid].pleaId], oid);
        ++voids;
    }

    function _clear(Model storage p, uint256 oid) internal {
        if (p.pending[0] == oid) p.pending[0] = 0;
        else if (p.pending[1] == oid) p.pending[1] = 0;
    }

    function _pending(uint256 seed) internal view returns (uint256) {
        if (opened == 0) return 0;
        uint256 start = bound(seed, 1, opened);
        for (uint256 i; i < opened; ++i) {
            uint256 oid = 1 + (start - 1 + i) % opened;
            if (objs[oid].ruling == Tribunal.Ruling.Pending && !objs[oid].completed) return oid;
        }
        return 0;
    }

    function _attestation(uint256 score) internal returns (OracleAttestation.Attestation memory a) {
        a.requestId = keccak256(abi.encode("run 8.5 objection", ++nonce));
        a.chainId = 1;
        a.questionHash = keccak256("question");
        a.answerType = OracleAttestation.ANSWER_UINT256;
        a.answer = abi.encode(score);
        a.figure = score;
        a.panelSize = 30;
        a.quorum = 17;
        a.agreed = 20;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(SIGNER_KEY, OracleAttestationConsumer(address(tribunal)).attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }
}

/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract Run85ObjectionInvariantTest is SepoliaFixture {
    ObjectionHandler handler;

    function withTribunal() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        uint256[] memory ids = new uint256[](users.length);
        for (uint256 i; i < users.length; ++i) {
            buy(users[i], 50e18);
        }
        skip(1 days);
        for (uint256 i; i < users.length; ++i) {
            ids[i] = approvedPlea(users[i], 45);
        }
        handler = new ObjectionHandler(plea, gate, seasons, tribunal, intake, imd, ids);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.file.selector;
        selectors[1] = handler.rule.selector;
        selectors[2] = handler.fail.selector;
        selectors[3] = handler.expire.selector;
        selectors[4] = handler.settle.selector;
        selectors[5] = handler.sell.selector;
        selectors[6] = handler.advance.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_theTribunalHoldsExactlyTheUnsettledStakes() public view {
        handler.checkCustody();
    }

    function invariant_casesRulingsAndSalesKeepTheAgreedRules() public view {
        handler.checkCases();
    }

    /// @dev After any history, every stake can be released without the oracle or a privileged caller.
    function afterInvariant() public {
        handler.advance(8 minutes);
        handler.advance(8 minutes);
        handler.advance(8 minutes);
        uint256 n = handler.opened();
        for (uint256 oid = 1; oid <= n; ++oid) {
            handler.expire(oid);
        }
        for (uint256 oid = 1; oid <= n; ++oid) {
            handler.settle(oid);
        }
        assertEq(handler.settled(), n);
        assertEq(imd.balanceOf(address(tribunal)), 0, "nothing stays locked");
        handler.checkCustody();
        handler.checkCases();
    }

    /// @dev The handler is not vacuous: one scripted history reaches every ending.
    function test_handlerReachesEveryEnding() public {
        handler.file(0, 0); // #1 on plea 0
        handler.file(0, 0); // same wallet: refused
        handler.file(0, 1); // #2 beside it
        handler.file(0, 2); // the case is full: refused
        handler.rule(1, 45); // overruled
        handler.rule(2, 0); // sustained
        handler.file(1, 0); // #3 on plea 1
        handler.fail(3, false); // void
        handler.file(1, 0); // #4: the void freed the slot for the same wallet
        handler.fail(4, true); // silent: still pending until expired
        handler.expire(4); // completed, so stale
        handler.file(2, 1); // #5 on plea 2
        handler.sell(2);
        handler.advance(8 minutes);
        handler.advance(8 minutes);
        handler.advance(8 minutes);
        handler.expire(5);
        for (uint256 oid = 1; oid <= 5; ++oid) {
            handler.settle(oid);
        }
        handler.settle(1);
        assertEq(handler.opened(), 5);
        assertEq(handler.refusedFilings(), 2);
        assertEq(handler.rulings(), 2);
        assertEq(handler.sustains(), 1);
        assertEq(handler.voids(), 3);
        assertEq(handler.sales(), 1);
        assertEq(handler.toPot(), 0.35e18);
        handler.checkCustody();
        handler.checkCases();
    }
}
