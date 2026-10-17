// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SepoliaFixture} from "../utils/SepoliaFixture.sol";
import {MockIMD, MockIntake} from "../utils/Mocks.sol";
import {PLEA} from "src/PLEA.sol";
import {CabalGate} from "src/CabalGate.sol";
import {Seasons} from "src/Seasons.sol";
import {Tribunal} from "src/Tribunal.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";

/// @dev Exercises the real gate, Tribunal, Seasons, PLEA and pool. Only the external Intake and
/// its fee tokens are mocks. Expectations are driven by successful inputs, not copied from the
/// Tribunal's balance or case getters. Separate objectors make their cash flows fully observable.
contract TribunalSequenceHandler is Test {
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant STAKE = 0.35e18;
    uint256 constant FEE = 0.5e18;
    uint256 constant WINDOW = 20 minutes;
    uint256 constant INITIAL_CASH = 1_000e18;

    struct PleaModel {
        address seller;
        uint64 approvedAt;
        uint8 score;
        uint8 need;
        uint8 count;
        uint8 lowest;
        bool sustained;
        bool recorded;
        uint256[2] pending;
        address lastObjector;
    }

    struct ObjectionModel {
        uint256 pleaId;
        address actor;
        uint64 filedAt;
        bytes32 intakeId;
        Tribunal.Ruling ruling;
        bool completed;
        bool settled;
        uint8 score;
    }

    PLEA public immutable plea;
    CabalGate public immutable gate;
    Seasons public immutable seasons;
    Tribunal public immutable tribunal;
    MockIntake public immutable intake;
    MockIMD public immutable imd;
    MockIMD public immutable feeToken;
    bool public immutable mints;
    uint256 public immutable initialFeeSink;
    address[] public sellers;
    address[4] public objectors;
    uint256[] public pleaIds;
    mapping(uint256 => PleaModel) internal pleas;
    mapping(uint256 => ObjectionModel) internal objections;
    mapping(address => uint256) public deposits;
    mapping(address => uint256) public refunds;
    mapping(address => uint256) public feesPaid;
    uint256 public opened;
    uint256 public settled;
    uint256 public returnedStakes;
    uint256 public potStakes;
    uint256 public donations;
    uint256 public rulings;
    uint256 public voids;
    uint256 public missedCallbacks;
    uint256 public sales;
    uint256 public closes;
    uint64 public lastVerdict;
    uint256 internal nonce;

    constructor(
        PLEA p,
        CabalGate g,
        Seasons s,
        Tribunal t,
        MockIntake i,
        MockIMD poolImd,
        MockIMD fee,
        address[] memory actors
    ) {
        plea = p;
        gate = g;
        seasons = s;
        tribunal = t;
        intake = i;
        imd = poolImd;
        feeToken = fee;
        mints = t.mintOracleFee();
        sellers = actors;
        initialFeeSink = fee.balanceOf(i.PAY_TO());
        lastVerdict = g.lastVerdictAt();
        for (uint256 k; k < objectors.length; ++k) {
            address who = makeAddr(string.concat("Tribunal invariant objector ", vm.toString(k)));
            objectors[k] = who;
            poolImd.mint(who, INITIAL_CASH);
            vm.prank(who);
            poolImd.approve(address(t), type(uint256).max);
        }
    }

    /// @dev Only successful real gate approvals create model pleas. Cooldown and the dead-man
    /// are respected; arbitrary storage writes never manufacture an eligible plea.
    function approveFresh(uint256 sellerSeed, uint256 scoreSeed) public {
        if (!gate.cabalAlive()) return;
        address who = sellers[bound(sellerSeed, 0, sellers.length - 1)];
        uint256 previous = gate.pendingOf(who);
        if (previous != 0 && block.timestamp < uint256(gate.getPlea(previous).verdictAt) + 4 hours) return;
        if (block.timestamp < gate.lastExecutedAt(who) + 4 hours) return;
        uint256 amount = plea.balanceOf(who) / 10;
        if (amount > 2_500_000e18) amount = 2_500_000e18;
        vm.prank(who);
        uint256 id = gate.submitSell(amount, "A small sale for rent; the rest of my PLEA stays.");
        uint8 need = gate.getPlea(id).need;
        uint8 score = uint8(bound(scoreSeed, need, 45));
        bytes32 rid = gate.getPlea(id).intakeId;
        OracleAttestation.Attestation memory a = _attestation(score);
        assertTrue(intake.complete(rid, 0, abi.encode(rid, a, _sign(address(gate), a))), "gate callback");
        pleaIds.push(id);
        pleas[id] = PleaModel(who, uint64(block.timestamp), score, need, 0, 255, false, false, [uint256(0), 0], address(0));
        lastVerdict = uint64(block.timestamp);
    }

    function file(uint256 pleaSeed, uint256 actorSeed) public {
        uint256 id = _plea(pleaSeed);
        PleaModel storage p = pleas[id];
        address who = objectors[bound(actorSeed, 0, 3)];
        bytes memory error;
        // Up to two pending objections from different wallets (round 5, R5-A1-1); stale ones are
        // voided by the filing itself.
        bool stale0 = p.pending[0] != 0 && _stale(objections[p.pending[0]]);
        bool stale1 = p.pending[1] != 0 && _stale(objections[p.pending[1]]);
        uint256 live0 = stale0 ? 0 : p.pending[0];
        uint256 live1 = stale1 ? 0 : p.pending[1];
        uint256 waiting = (live0 != 0 ? 1 : 0) + (live1 != 0 ? 1 : 0);
        if (block.timestamp > uint256(p.approvedAt) + WINDOW) {
            error = abi.encodeWithSelector(Tribunal.WindowClosed.selector, id);
        } else if (p.recorded) {
            error = abi.encodeWithSelector(Tribunal.AlreadyRecorded.selector, id);
        } else if (p.sustained || p.count == 2) {
            error = abi.encodeWithSelector(Tribunal.CaseClosed.selector, id);
        } else if (p.count + waiting >= 2) {
            error = abi.encodeWithSelector(Tribunal.ObjectionPending.selector, live0 != 0 ? live0 : live1);
        } else if (
            (p.count != 0 && p.lastObjector == who) || (live0 != 0 && objections[live0].actor == who)
                || (live1 != 0 && objections[live1].actor == who)
        ) {
            error = abi.encodeWithSelector(Tribunal.SameObjector.selector);
        }
        if (error.length != 0) {
            vm.expectRevert(error);
            vm.prank(who);
            tribunal.object(id, "Please re-examine the actual text against the craft definition.");
            return;
        }
        vm.prank(who);
        uint256 oid = tribunal.object(id, "Please re-examine the actual text against the craft definition.");
        assertEq(oid, opened + 1, "failed attempts cannot allocate an id");
        if (stale0) _void(p.pending[0]);
        if (stale1) _void(p.pending[1]);
        ++opened;
        deposits[who] += STAKE;
        if (!mints) feesPaid[who] += FEE;
        bytes32 rid = tribunal.objection(oid).intakeId;
        objections[oid] =
            ObjectionModel(id, who, uint64(block.timestamp), rid, Tribunal.Ruling.Pending, false, false, 0);
        p.pending[p.pending[0] == 0 ? 0 : 1] = oid;
        assertEq(intake.failureOf(rid), tribunal.onObjectionFailure.selector, "Intake v2 failure hook");
        (address payer, address target, bytes4 selector,) = intake.requests(rid);
        assertEq(payer, address(tribunal));
        assertEq(target, address(tribunal));
        assertEq(selector, tribunal.onOracleResult.selector);
    }

    function rule(uint256 seed, uint256 scoreSeed) public {
        uint256 oid = _pending(seed, true);
        if (oid == 0) return;
        ObjectionModel storage o = objections[oid];
        uint8 score = uint8(bound(scoreSeed, 0, 45));
        OracleAttestation.Attestation memory a = _attestation(score);
        uint256 cash = imd.balanceOf(address(tribunal));
        bool live = block.timestamp <= uint256(o.filedAt) + WINDOW;
        bool delivered = intake.complete(o.intakeId, 0, abi.encode(o.intakeId, a, _sign(address(tribunal), a)));
        o.completed = true;
        assertEq(delivered, live, "fresh signed score must fit the 200k callback stipend");
        assertEq(imd.balanceOf(address(tribunal)), cash, "ruling stores only");
        assertEq(tribunal.consumed(a.requestId), live, "rejected answers do not burn nonces");
        if (!live) {
            ++missedCallbacks;
            return;
        }
        PleaModel storage p = pleas[o.pleaId];
        bool sustain = uint256(score) + 2 < p.need;
        o.score = score;
        o.ruling = sustain ? Tribunal.Ruling.Sustained : Tribunal.Ruling.Overruled;
        _clear(p, oid);
        ++p.count;
        p.lastObjector = o.actor;
        if (score < p.lowest) p.lowest = score;
        if (sustain) p.sustained = true; // a second pending objection may still be ruled after it
        ++rulings;
    }

    /// @dev A completed request with a lost failure callback is deliberately still Pending until
    /// expire or a replacement object() observes completion. Neither path refunds the oracle fee.
    function fail(uint256 seed, bool deliverFailure, bool refused) public {
        uint256 oid = _pending(seed, true);
        if (oid == 0) return;
        ObjectionModel storage o = objections[oid];
        uint256 cash = imd.balanceOf(address(tribunal));
        intake.setFailureHooks(deliverFailure);
        assertEq(intake.fail(o.intakeId, refused ? 1 : 2, bytes32("disagreed"), 0, 30), deliverFailure);
        intake.setFailureHooks(true);
        o.completed = true;
        if (deliverFailure) _void(oid);
        else ++missedCallbacks;
        assertEq(imd.balanceOf(address(tribunal)), cash, "failure callback stores only");
    }

    function expire(uint256 seed) public {
        uint256 oid = _pending(seed, false);
        if (oid == 0) return;
        if (!_stale(objections[oid])) {
            vm.expectRevert(Tribunal.NotStale.selector);
            tribunal.expire(oid);
            return;
        }
        tribunal.expire(oid);
        _void(oid);
    }

    function settle(uint256 seed, uint256 callerSeed) public {
        uint256 oid = bound(seed, 0, opened + 1);
        ObjectionModel storage o = objections[oid];
        address caller = objectors[bound(callerSeed, 0, 3)];
        if (o.ruling == Tribunal.Ruling.None || o.ruling == Tribunal.Ruling.Pending) {
            vm.expectRevert(abi.encodeWithSelector(Tribunal.NotRuled.selector, oid));
        } else if (o.settled) {
            vm.expectRevert(abi.encodeWithSelector(Tribunal.AlreadySettled.selector, oid));
        } else {
            uint256 season = _season(pleas[o.pleaId].approvedAt);
            uint256 feesBefore = seasons.seasonFees(season);
            uint256 rolloverBefore = seasons.rollover();
            vm.prank(caller);
            tribunal.settle(oid);
            o.settled = true;
            ++settled;
            if (o.ruling == Tribunal.Ruling.Overruled) {
                ++potStakes;
                if (seasons.closed(season)) {
                    assertEq(seasons.rollover(), rolloverBefore + STAKE, "closed pot rolls over");
                } else {
                    assertEq(seasons.seasonFees(season), feesBefore + STAKE, "stake follows plea season");
                }
            } else {
                ++returnedStakes;
                refunds[o.actor] += STAKE;
            }
            return;
        }
        vm.prank(caller);
        tribunal.settle(oid);
    }

    function record(uint256 seed) public {
        uint256 id = _plea(seed);
        PleaModel storage p = pleas[id];
        uint256 season = _season(p.approvedAt);
        if (p.recorded) {
            vm.expectRevert(abi.encodeWithSelector(Seasons.AlreadyRecorded.selector, id));
        } else if (seasons.closed(season)) {
            vm.expectRevert(abi.encodeWithSelector(Seasons.SeasonClosed.selector, season));
        } else if (_held(p)) {
            vm.expectRevert(abi.encodeWithSelector(Seasons.Held.selector, id));
        } else if (p.sustained) {
            vm.expectRevert(abi.encodeWithSelector(Seasons.ObjectionSustained.selector, id));
        } else {
            seasons.record(id);
            p.recorded = true;
            return;
        }
        seasons.record(id);
    }

    function close() public {
        uint256 next = seasons.nextToClose();
        (bool exists,, uint64 end, bool ended) = seasons.seasonBounds(next);
        if (!exists || !ended || block.timestamp < uint256(end) + 1 hours) return;
        // Pass all known pleas, including held, sustained, repeated and later-season entries.
        seasons.closeSeason(pleaIds);
        for (uint256 k; k < pleaIds.length; ++k) {
            PleaModel storage p = pleas[pleaIds[k]];
            uint256 season = _season(p.approvedAt);
            if (!p.recorded && season >= next && !_held(p) && !p.sustained) p.recorded = true;
        }
        assertTrue(seasons.closed(next));
        assertEq(seasons.nextToClose(), next + 1);
        ++closes;
    }

    function sell(uint256 seed) public {
        uint256 id = _plea(seed);
        CabalGate.Plea memory p = gate.getPlea(id);
        if (p.status != CabalGate.Status.Approved || block.timestamp > uint256(p.verdictAt) + 7 minutes) return;
        uint256 bal = plea.balanceOf(p.seller);
        vm.prank(p.seller);
        gate.executeSell(0);
        assertEq(plea.balanceOf(p.seller), bal - p.amount, "objections never prevent an approved sale");
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Executed));
        ++sales;
    }

    function donate(uint256 amountSeed) public {
        uint256 amount = bound(amountSeed, 1, 1e18);
        imd.mint(address(tribunal), amount);
        donations += amount;
    }

    function advance(uint256 seed, bool crossSeason) public {
        skip(crossSeason ? bound(seed, 4 hours, 6 hours) : bound(seed, 0, 10 minutes));
    }

    function assertCustody() external view {
        uint256 liabilities;
        for (uint256 id = 1; id <= opened; ++id) {
            ObjectionModel storage o = objections[id];
            Tribunal.Objection memory actual = tribunal.objection(id);
            assertEq(actual.settled, o.settled, "settlement is once only");
            if (!o.settled) liabilities += STAKE;
        }
        assertEq(imd.balanceOf(address(tribunal)), liabilities + donations, "every unpaid stake remains solvent");
        assertEq(liabilities, (opened - settled) * STAKE);
        assertEq(settled, returnedStakes + potStakes);
        assertEq(
            feeToken.balanceOf(intake.PAY_TO()), initialFeeSink + (pleaIds.length + opened) * FEE, "fees spent once"
        );
        if (mints) assertEq(feeToken.balanceOf(address(tribunal)), 0, "minted fee forwarded in full");
        for (uint256 k; k < 4; ++k) {
            address who = objectors[k];
            assertLe(refunds[who], deposits[who], "an objector cannot withdraw another stake");
            assertEq(imd.balanceOf(who), INITIAL_CASH - deposits[who] - feesPaid[who] + refunds[who]);
        }
    }

    function assertCases() external view {
        assertEq(tribunal.nextId(), opened + 1);
        assertEq(gate.lastVerdictAt(), lastVerdict, "only plea verdicts reset the dead-man");
        for (uint256 id = 1; id <= opened; ++id) {
            ObjectionModel storage o = objections[id];
            Tribunal.Objection memory actual = tribunal.objection(id);
            assertEq(actual.pleaId, o.pleaId);
            assertEq(actual.objector, o.actor);
            assertEq(actual.filedAt, o.filedAt);
            assertEq(actual.newScore, o.score);
            assertEq(uint8(actual.ruling), uint8(o.ruling), "terminal rulings never reopen");
            assertEq(tribunal.objectionOfIntake(o.intakeId), o.ruling == Tribunal.Ruling.Pending ? id : 0);
        }
        for (uint256 k; k < pleaIds.length; ++k) {
            uint256 id = pleaIds[k];
            PleaModel storage p = pleas[id];
            Tribunal.Case memory actual = tribunal.caseOf(id);
            assertEq(actual.count, p.count);
            assertLe(p.count, 2);
            assertEq(actual.pending[0], p.pending[0]);
            assertEq(actual.pending[1], p.pending[1]);
            if (p.pending[0] != 0 && p.pending[1] != 0) {
                assertTrue(objections[p.pending[0]].actor != objections[p.pending[1]].actor, "two wallets");
                assertEq(p.count, 0, "two pending objections only on an unruled case");
            }
            assertEq(actual.lastObjector, p.lastObjector);
            assertEq(actual.sustained, p.sustained);
            (bool held, bool sustained, uint8 lowest) = tribunal.standing(id);
            assertEq(held, _held(p));
            assertEq(sustained, p.sustained);
            assertEq(lowest, p.lowest, "lowest score only decreases across real rulings");
            (address seller, uint8 score, bool approved, uint64 at) = gate.result(id);
            assertEq(seller, p.seller);
            assertEq(score, p.score, "objections cannot rewrite the sale's original verdict");
            assertTrue(approved);
            assertEq(at, p.approvedAt);
            if (p.sustained) assertFalse(p.recorded);
        }
    }

    function assertPoints() external view {
        for (uint256 k; k < pleaIds.length; ++k) {
            PleaModel storage p = pleas[pleaIds[k]];
            assertEq(seasons.recorded(pleaIds[k]), p.recorded);
            if (!p.recorded) continue;
            assertFalse(_held(p));
            assertFalse(p.sustained);
            // Select the three largest effective scores by repeated maximum over history.
            // This is independent of Seasons' in-place minimum replacement algorithm.
            uint256 season = _season(p.approvedAt);
            uint256[3] memory chosen;
            uint256 sum;
            for (uint256 rank; rank < 3; ++rank) {
                uint256 bestId;
                uint8 bestScore;
                for (uint256 j; j < pleaIds.length; ++j) {
                    uint256 id = pleaIds[j];
                    PleaModel storage candidate = pleas[id];
                    if (!candidate.recorded || candidate.seller != p.seller || _season(candidate.approvedAt) != season) continue;
                    if (id == chosen[0] || id == chosen[1] || id == chosen[2]) continue;
                    uint8 score = candidate.lowest < candidate.score ? candidate.lowest : candidate.score;
                    if (score > bestScore) {
                        bestScore = score;
                        bestId = id;
                    }
                }
                chosen[rank] = bestId;
                sum += bestScore;
            }
            uint8[3] memory best = seasons.bestOf(season, p.seller);
            assertEq(uint256(best[0]) + best[1] + best[2], sum, "recorded points use the lowest panel, best three only");
        }
    }

    function _void(uint256 oid) internal {
        objections[oid].ruling = Tribunal.Ruling.Void;
        _clear(pleas[objections[oid].pleaId], oid);
        ++voids;
    }

    function _clear(PleaModel storage p, uint256 oid) internal {
        if (p.pending[0] == oid) p.pending[0] = 0;
        else if (p.pending[1] == oid) p.pending[1] = 0;
    }

    function _held(PleaModel storage p) internal view returns (bool) {
        if (p.sustained) return false;
        if (p.pending[0] != 0 && !_stale(objections[p.pending[0]])) return true;
        if (p.pending[1] != 0 && !_stale(objections[p.pending[1]])) return true;
        return p.count < 2 && block.timestamp <= uint256(p.approvedAt) + WINDOW;
    }

    function _stale(ObjectionModel storage o) internal view returns (bool) {
        return o.completed || block.timestamp > uint256(o.filedAt) + WINDOW;
    }

    function _plea(uint256 seed) internal view returns (uint256) {
        return pleaIds[bound(seed, 0, pleaIds.length - 1)];
    }

    function _pending(uint256 seed, bool requireUncompleted) internal view returns (uint256) {
        if (opened == 0) return 0;
        uint256 start = bound(seed, 1, opened);
        for (uint256 i; i < opened; ++i) {
            uint256 id = 1 + (start - 1 + i) % opened;
            if (objections[id].ruling == Tribunal.Ruling.Pending && (!requireUncompleted || !objections[id].completed)) return id;
        }
        return 0;
    }

    function _season(uint64 at) internal view returns (uint256) {
        return (uint256(at) - gate.startedAt()) / 18_000;
    }

    function _attestation(uint256 score) internal returns (OracleAttestation.Attestation memory a) {
        a.requestId = keccak256(abi.encode("sequence attestation", ++nonce));
        a.chainId = 1;
        a.questionHash = keccak256("mock resolved question");
        a.answerType = OracleAttestation.ANSWER_UINT256;
        a.answer = abi.encode(score);
        a.figure = score;
        a.panelSize = 30;
        a.quorum = 17;
        a.agreed = 20;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
    }

    function _sign(address consumer, OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, OracleAttestationConsumer(consumer).attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract TribunalInvariantTest is SepoliaFixture {
    TribunalSequenceHandler internal handler;

    function withTribunal() internal pure override returns (bool) {
        return true;
    }

    function setUp() public virtual override {
        super.setUp();
        for (uint256 i; i < users.length; ++i) {
            buy(users[i], 50e18);
        }
        skip(1 days);
        handler = new TribunalSequenceHandler(plea, gate, seasons, tribunal, intake, imd, oracleFeeToken(), users);
        for (uint256 i; i < users.length; ++i) {
            handler.approveFresh(i, 40);
        }
        // Start with a live liability so even a sequence beginning with time advancement matters.
        handler.file(0, 0);
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.approveFresh.selector;
        selectors[1] = handler.file.selector;
        selectors[2] = handler.rule.selector;
        selectors[3] = handler.fail.selector;
        selectors[4] = handler.expire.selector;
        selectors[5] = handler.settle.selector;
        selectors[6] = handler.record.selector;
        selectors[7] = handler.close.selector;
        selectors[8] = handler.sell.selector;
        selectors[9] = handler.donate.selector;
        selectors[10] = handler.advance.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_stakesAndFeesAreConserved() public view {
        handler.assertCustody();
    }

    function invariant_caseTransitionsAndSalesRemainIndependent() public view {
        handler.assertCases();
    }

    function invariant_onlyFinalEligibleScoresBecomePoints() public view {
        handler.assertPoints();
    }

    /// @dev Every generated history can unwind without an oracle response or privileged caller.
    /// Unsolicited donations remain, but no participant's stake remains locked after expiry.
    function afterInvariant() public {
        handler.advance(6 hours, true);
        uint256 n = handler.opened();
        for (uint256 id = 1; id <= n; ++id) {
            handler.expire(id);
        }
        for (uint256 id = 1; id <= n; ++id) {
            handler.settle(id, id % 4);
        }
        assertEq(handler.settled(), n);
        assertEq(imd.balanceOf(address(tribunal)), handler.donations());
        handler.assertCustody();
        handler.assertCases();
        handler.assertPoints();
    }

    /// @dev Deterministic witness that the handler actually reaches every money-moving ending,
    /// both callback delivery modes, a second ruling, a sustained sale, expiry and late settlement.
    function test_handlerReachesAllEndingsWithoutVacuity() public {
        handler.rule(1, 45);
        handler.file(0, 1);
        handler.rule(2, 44);
        handler.record(0);
        handler.file(1, 0);
        handler.rule(3, 0);
        handler.sell(1); // sustained points do not revoke the sale
        handler.file(2, 2);
        handler.fail(4, false, true);
        handler.file(2, 3); // replaces the completed request, automatically voiding #4
        handler.fail(5, true, false);
        handler.file(2, 2); // voids consume no ruling slots
        handler.advance(1_200, true); // bound to >= 4h; #6 expires and original season remains open
        handler.expire(6);
        handler.settle(3, 3);
        handler.settle(4, 0);
        handler.settle(5, 0);
        handler.settle(6, 0);
        handler.advance(6 hours, true);
        for (uint256 i; i < 8; ++i) {
            handler.close();
        }
        handler.settle(1, 0); // overrules settled after the plea's season closed
        handler.settle(2, 0);
        handler.settle(1, 1); // duplicate settlement is refused
        handler.donate(1);
        assertEq(handler.opened(), 6);
        assertEq(handler.rulings(), 3);
        assertEq(handler.voids(), 3);
        assertEq(handler.returnedStakes(), 4);
        assertEq(handler.potStakes(), 2);
        assertEq(handler.missedCallbacks(), 1);
        assertEq(handler.sales(), 1);
        assertGt(handler.closes(), 0);
        invariant_stakesAndFeesAreConserved();
        invariant_caseTransitionsAndSalesRemainIndependent();
        invariant_onlyFinalEligibleScoresBecomePoints();
    }
}

/// @dev Also exercise the shared-asset branch: oracle fees must not be mistaken for stake reserves.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract TribunalPaidFeeInvariantTest is TribunalInvariantTest {
    function oracleFeeToken() internal view override returns (MockIMD) {
        return imd;
    }
}
