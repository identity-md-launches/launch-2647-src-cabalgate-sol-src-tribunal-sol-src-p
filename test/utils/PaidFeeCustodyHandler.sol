// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PLEA} from "src/PLEA.sol";
import {CabalGate} from "src/CabalGate.sol";
import {Letterbox} from "src/Letterbox.sol";
import {Tribunal} from "src/Tribunal.sol";
import {Seasons} from "src/Seasons.sol";
import {PleaHook} from "src/PleaHook.sol";
import {PleaDistributor} from "src/PleaDistributor.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {MockIMD, MockSIMD, MockIntake, BuyRouter} from "./Mocks.sol";
import {ClaimTree} from "./ClaimTree.sol";

/// @dev One campaign interleaves the paid-fee Letterbox, objections, distributor, pool and final
/// season. Ghost liabilities are written from successful operations, never recomputed from the
/// escrow/settled flags they check. Expected application refusals are explicit; panics and unknown
/// errors fail the campaign. No minting, storage edits, mock calls or caller impersonation of a
/// protocol contract occur during a sequence. Only the local oracle authority is simulated.
contract PaidFeeCustodyHandler is Test {
    struct Environment {
        PLEA token;
        CabalGate gate;
        Letterbox box;
        Tribunal tribunal;
        Seasons seasons;
        PleaHook hook;
        PleaDistributor drop;
        MockIMD imd;
        MockSIMD simd;
        MockIntake intake;
        BuyRouter router;
        address[4] actors;
        address runner;
        uint256 signerKey;
    }

    struct LetterDebt {
        address writer;
        uint256 amount;
        bool open;
        bool sold;
    }

    struct StakeDebt {
        address objector;
        bool paid;
    }

    Environment internal e;
    uint256[] internal letters;
    mapping(uint256 => LetterDebt) public letterDebts;
    mapping(uint256 => StakeDebt) public stakeDebts;
    mapping(address => uint256) public startingPlea;
    mapping(address => uint256) public bought;
    mapping(address => uint256) public feePlea;
    mapping(address => uint256) public claimedPlea;
    mapping(address => uint256) public bonusPlea;
    bool[8] public claimed;
    uint256 public depositedStakes;
    uint256 public paidStakes;
    uint256 public boxDonations;
    uint256 public tribunalDonations;
    uint256 public plainCashback;
    uint256 public buys;
    uint256 public deliveries;
    uint256 public refunds;
    uint256 public rulings;
    uint256 public voids;
    uint256 public rejected;
    uint256 public closes;
    bool public died;
    uint256 public previousCap;
    uint256 private nonce;

    constructor(Environment memory env) {
        e = env;
        previousCap = e.hook.inventoryCap();
        for (uint256 i; i < 4; ++i) {
            startingPlea[e.actors[i]] = e.token.balanceOf(e.actors[i]);
            vm.prank(e.actors[i]);
            e.imd.approve(address(e.tribunal), type(uint256).max);
        }
    }

    function letterCount() external view returns (uint256) {
        return letters.length;
    }

    function letterId(uint256 pos) external view returns (uint256) {
        return letters[pos];
    }

    function buy(uint256 who, uint256 raw, bool failCredit) external {
        address actor = e.actors[who % 4];
        // Exercise a reverting credit, including a revert AFTER Stacker pulled the funds.
        e.simd.setPaused(failCredit);
        uint256 amount = bound(raw, 1e15, 20e18);
        uint256 cb = e.hook.totalCashback();
        uint256 credits = _credits(actor);
        uint256 cash = e.imd.balanceOf(actor);
        vm.prank(actor);
        uint256 out = e.router.buyExactIn(amount, abi.encode(actor));
        assertGt(out, 0);
        bought[actor] += out;
        ++buys;
        uint256 plain = _cashback(actor, cb, credits);
        assertEq(e.imd.balanceOf(actor), cash - amount + plain, "plain cashback reaches the buyer");
        _monotonic();
    }

    function claim(uint256 position, uint256 relayer) external {
        uint256 p = position % 8;
        address recipient = e.actors[p % 4];
        bytes32[] memory proof = ClaimTree.proof(e.actors, p);
        if (claimed[p]) {
            ++rejected;
            vm.expectRevert(PleaDistributor.AlreadyClaimed.selector);
        }
        vm.prank(e.actors[relayer % 4]);
        e.drop.claim(ClaimTree.index(p), recipient, ClaimTree.amount(p), proof);
        if (!claimed[p]) {
            claimed[p] = true;
            claimedPlea[recipient] += ClaimTree.amount(p);
        }
    }

    function write(uint256 who, bool site) external {
        address actor = e.actors[who % 4];
        (uint256 previous,) = e.box.openOf(actor);
        // Replacement-letter atomicity is tested separately. Keeping this step to one new
        // liability makes the custody model independent of the Letterbox's settlement code.
        if (previous != 0) return;
        uint256 balance = e.token.balanceOf(actor);
        uint256 amount = balance / (site ? 10 : 5);
        if (amount > 2_500_000e18) amount = 2_500_000e18;
        uint256 cb = e.hook.totalCashback();
        uint256 credits = _credits(actor);
        uint256 cash = e.imd.balanceOf(actor);
        bytes memory data = site
            ? abi.encodeCall(Letterbox.plead, (amount, "Rent is due. I keep the rest through this season."))
            : abi.encodeCall(Letterbox.letter, ("Rent is due. I keep the rest through this season."));
        vm.prank(actor);
        (bool ok, bytes memory reason) = address(e.box).call(data);
        if (!ok) {
            bytes4 err = _selector(reason);
            assertTrue(
                err == CabalGate.Cooldown.selector || err == CabalGate.CabalNotWatching.selector
                    || err == CabalGate.CannotPass.selector || err == CabalGate.FeeTooHigh.selector
                    || err == Letterbox.FeeTooHigh.selector || err == Letterbox.TooSmallForTheFee.selector,
                "unexpected letter failure"
            );
            assertEq(e.token.balanceOf(actor), balance);
            assertEq(e.imd.balanceOf(actor), cash);
            assertEq(e.hook.totalCashback(), cb);
            ++rejected;
            return;
        }
        (uint256 id,) = e.box.openOf(actor);
        uint256 remaining = e.token.balanceOf(actor);
        assertLe(remaining + amount, balance);
        feePlea[actor] += balance - remaining - amount;
        letterDebts[id] = LetterDebt(actor, amount, true, false);
        letters.push(id);
        assertEq(e.gate.getPlea(id).amount, amount);
        assertEq(e.gate.getPlea(id).need + e.gate.getPlea(id).factScore, 69);
        uint256 plain = _cashback(actor, cb, credits);
        assertEq(e.imd.balanceOf(actor), cash + plain, "fee sale cashback reaches its writer");
        _monotonic();
    }

    function answer(uint256 which, uint256 rawScore, bool failure) external {
        if (letters.length == 0) return;
        uint256 id = letters[which % letters.length];
        CabalGate.Plea memory p = e.gate.getPlea(id);
        (,,, bool completed) = e.intake.requests(p.intakeId);
        if (p.status != CabalGate.Status.Pending || completed) return;
        uint256 cash = e.imd.balanceOf(address(e.box));
        if (failure) {
            assertTrue(e.intake.fail(p.intakeId, 2, bytes32("no consensus"), 16, 30));
            assertEq(uint8(e.gate.getPlea(id).status), uint8(CabalGate.Status.Expired));
        } else {
            uint256 score = bound(rawScore, 0, 45);
            bool live = e.gate.cabalAlive() && block.timestamp <= uint256(p.submittedAt) + 20 minutes;
            assertEq(_answer(address(e.gate), p.intakeId, score), live, "200k oracle callback");
            if (live) {
                assertEq(
                    uint8(e.gate.getPlea(id).status),
                    uint8(score >= p.need ? CabalGate.Status.Approved : CabalGate.Status.Denied)
                );
            }
        }
        assertEq(e.imd.balanceOf(address(e.box)), cash, "a callback cannot spend tips");
        _monotonic();
    }

    function finishLetter(uint256 which, bool sell) external {
        if (letters.length == 0) return;
        uint256 id = letters[which % letters.length];
        LetterDebt storage debt = letterDebts[id];
        if (!debt.open) return;
        address actor = debt.writer;
        uint256 tokens = e.token.balanceOf(actor);
        uint256 cash = e.imd.balanceOf(actor);
        uint256 tip = e.imd.balanceOf(e.runner);
        uint256 cb = e.hook.totalCashback();
        uint256 credits = _credits(actor);
        vm.prank(e.runner);
        (bool ok, bytes memory result) =
            address(e.box).call(sell ? abi.encodeCall(Letterbox.deliver, (id)) : abi.encodeCall(Letterbox.settle, (id)));
        if (!ok) {
            bytes4 err = _selector(result);
            assertTrue(
                err == CabalGate.NotApproved.selector || err == CabalGate.WindowLapsed.selector
                    || err == CabalGate.NotStale.selector || err == Letterbox.NotSettleable.selector
                    || err == CabalGate.SlippageExceeded.selector,
                "unexpected ending failure"
            );
            assertEq(e.token.balanceOf(actor), tokens);
            assertEq(e.imd.balanceOf(actor), cash);
            ++rejected;
            return;
        }
        debt.open = false;
        debt.sold = sell;
        uint256 plain = _cashback(actor, cb, credits);
        if (sell) {
            ++deliveries;
            assertEq(e.token.balanceOf(actor), tokens);
            assertEq(e.imd.balanceOf(actor), cash + abi.decode(result, (uint256)) + plain);
            assertEq(e.imd.balanceOf(e.runner), tip + 0.25e18);
            assertEq(uint8(e.gate.getPlea(id).status), uint8(CabalGate.Status.Executed));
        } else {
            ++refunds;
            assertEq(e.token.balanceOf(actor), tokens + debt.amount);
            assertEq(e.imd.balanceOf(actor), cash + 0.25e18);
            assertEq(e.imd.balanceOf(e.runner), tip);
        }
        _monotonic();
    }

    function object(uint256 which, uint256 who) external {
        if (letters.length == 0) return;
        uint256 id = letters[which % letters.length];
        address actor = e.actors[who % 4];
        uint256 cash = e.imd.balanceOf(actor);
        vm.prank(actor);
        (bool ok, bytes memory result) = address(e.tribunal)
            .call(abi.encodeCall(Tribunal.object, (id, "Please reconsider the reason given for this sale.")));
        if (!ok) {
            bytes4 err = _selector(result);
            assertTrue(
                err == Tribunal.NotApproved.selector || err == Tribunal.WindowClosed.selector
                    || err == Tribunal.AlreadyRecorded.selector || err == Tribunal.NotEligible.selector
                    || err == Tribunal.CaseClosed.selector || err == Tribunal.ObjectionPending.selector
                    || err == Tribunal.SameObjector.selector,
                "unexpected objection failure"
            );
            assertEq(e.imd.balanceOf(actor), cash);
            ++rejected;
            return;
        }
        uint256 oid = abi.decode(result, (uint256));
        ++depositedStakes;
        assertEq(oid, depositedStakes);
        stakeDebts[oid] = StakeDebt(actor, false);
        assertEq(e.imd.balanceOf(actor), cash - 0.85e18);
    }

    function rule(uint256 which, uint256 rawScore, bool failure) external {
        if (depositedStakes == 0) return;
        uint256 oid = 1 + which % depositedStakes;
        Tribunal.Objection memory o = e.tribunal.objection(oid);
        (,,, bool completed) = e.intake.requests(o.intakeId);
        if (o.ruling != Tribunal.Ruling.Pending || completed) return;
        uint256 cash = e.imd.balanceOf(address(e.tribunal));
        uint256 clock = e.gate.lastVerdictAt();
        if (failure) {
            assertTrue(e.intake.fail(o.intakeId, 1, bytes32("refused"), 0, 30));
            assertEq(uint8(e.tribunal.objection(oid).ruling), uint8(Tribunal.Ruling.Void));
            ++voids;
        } else {
            uint256 score = bound(rawScore, 0, 45);
            bool live = block.timestamp <= uint256(o.filedAt) + 20 minutes;
            assertEq(_answer(address(e.tribunal), o.intakeId, score), live);
            if (live) {
                bool sustained = score + 2 < e.gate.getPlea(o.pleaId).need;
                assertEq(
                    uint8(e.tribunal.objection(oid).ruling),
                    uint8(sustained ? Tribunal.Ruling.Sustained : Tribunal.Ruling.Overruled)
                );
                ++rulings;
            }
        }
        assertEq(e.gate.lastVerdictAt(), clock, "objections cannot extend the dead-man");
        assertEq(e.imd.balanceOf(address(e.tribunal)), cash, "callbacks never transfer stake");
    }

    function settleStake(uint256 which) external {
        if (depositedStakes == 0) return;
        uint256 oid = 1 + which % depositedStakes;
        Tribunal.Objection memory o = e.tribunal.objection(oid);
        if (o.ruling == Tribunal.Ruling.Pending) {
            (,,, bool completed) = e.intake.requests(o.intakeId);
            if (completed || block.timestamp > uint256(o.filedAt) + 20 minutes) {
                e.tribunal.expire(oid);
                ++voids;
                o = e.tribunal.objection(oid);
            }
        }
        if (o.ruling == Tribunal.Ruling.Pending) {
            vm.expectRevert(abi.encodeWithSelector(Tribunal.NotRuled.selector, oid));
            e.tribunal.settle(oid);
            ++rejected;
            return;
        }
        if (stakeDebts[oid].paid) {
            vm.expectRevert(abi.encodeWithSelector(Tribunal.AlreadySettled.selector, oid));
            e.tribunal.settle(oid);
            ++rejected;
            return;
        }
        address recipient = o.ruling == Tribunal.Ruling.Overruled ? address(e.seasons) : stakeDebts[oid].objector;
        uint256 before = e.imd.balanceOf(recipient);
        vm.prank(e.runner);
        e.tribunal.settle(oid);
        assertEq(e.imd.balanceOf(recipient), before + 0.35e18);
        stakeDebts[oid].paid = true;
        ++paidStakes;
    }

    function donate(uint256 who, uint256 raw, bool toTribunal) external {
        uint256 amount = bound(raw, 1, 1e18);
        vm.prank(e.actors[who % 4]);
        e.imd.transfer(toTribunal ? address(e.tribunal) : address(e.box), amount);
        if (toTribunal) tribunalDonations += amount;
        else boxDonations += amount;
    }

    function advance(uint256 raw) external {
        skip(bound(raw, 0, 5 hours));
        _monotonic();
    }

    function recordAndClose() external {
        // Permissionless keepers may supply duplicate, stale and already recorded ids.
        for (uint256 i; i < letters.length; ++i) {
            uint256 id = letters[i];
            (,, bool approved,) = e.gate.result(id);
            (bool held, bool sustained,) = e.tribunal.standing(id);
            if (!approved || held || sustained || e.seasons.recorded(id)) continue;
            uint256 season = (uint256(e.gate.getPlea(id).verdictAt) - e.gate.startedAt()) / 15 days;
            if (!e.seasons.closed(season)) e.seasons.record(id);
        }
        uint256 n = e.seasons.nextToClose();
        (bool exists,, uint64 end, bool ended) = e.seasons.seasonBounds(n);
        if (exists && ended && block.timestamp >= uint256(end) + 1 hours) {
            uint256[4] memory before;
            for (uint256 i; i < 4; ++i) {
                before[i] = e.token.balanceOf(e.actors[i]);
            }
            e.seasons.closeSeason(letters);
            for (uint256 i; i < 4; ++i) {
                bonusPlea[e.actors[i]] += e.token.balanceOf(e.actors[i]) - before[i];
            }
            ++closes;
        }
        if (e.seasons.finished()) e.seasons.flushToWall();
        _monotonic();
    }

    function assertCustody() external view {
        uint256 escrow;
        uint256 count;
        for (uint256 i; i < letters.length; ++i) {
            uint256 id = letters[i];
            LetterDebt storage debt = letterDebts[id];
            (address writer, bool open, uint256 amount, uint256 sold) = e.box.escrowOf(id);
            assertEq(writer, debt.writer);
            assertEq(open, debt.open, "closed escrows never reopen");
            assertEq(amount, debt.amount);
            assertEq(sold > 0, debt.sold);
            if (debt.open) {
                escrow += debt.amount;
                ++count;
            }
        }
        (, uint256 actualCount) = e.box.openOf(address(0));
        assertEq(actualCount, count);
        assertEq(e.token.balanceOf(address(e.box)), escrow);
        assertEq(e.imd.balanceOf(address(e.box)), count * 0.25e18 + boxDonations);
        assertEq(e.imd.balanceOf(address(e.tribunal)), (depositedStakes - paidStakes) * 0.35e18 + tribunalDonations);
        for (uint256 id = 1; id <= depositedStakes; ++id) {
            assertEq(e.tribunal.objection(id).settled, stakeDebts[id].paid);
        }
        assertEq(e.imd.balanceOf(e.intake.PAY_TO()), (letters.length + depositedStakes) * 0.5e18);
        assertEq(e.token.balanceOf(address(e.gate)), 0);
        assertEq(e.imd.balanceOf(address(e.gate)), 0);
        assertEq(e.token.allowance(address(e.box), address(e.gate)), 0);
        assertEq(e.imd.allowance(address(e.box), address(e.gate)), 0);
        assertEq(e.imd.allowance(address(e.tribunal), address(e.intake)), 0);
        assertEq(e.imd.allowance(address(e.hook), address(e.hook.stacker())), 0);
    }

    function assertConservation() external view {
        uint256 paidClaims;
        uint256 paidBonus;
        uint256 credits = plainCashback;
        uint256 pleaHeld;
        uint256 imdHeld;
        for (uint256 k; k < 4; ++k) {
            address actor = e.actors[k];
            uint256 committed;
            for (uint256 i; i < letters.length; ++i) {
                LetterDebt storage debt = letterDebts[letters[i]];
                if (debt.writer == actor && (debt.open || debt.sold)) committed += debt.amount;
            }
            assertEq(
                e.token.balanceOf(actor) + committed + feePlea[actor],
                startingPlea[actor] + bought[actor] + claimedPlea[actor] + bonusPlea[actor],
                "writer PLEA ledger"
            );
            paidClaims += claimedPlea[actor];
            paidBonus += bonusPlea[actor];
            credits += _credits(actor);
            pleaHeld += e.token.balanceOf(actor);
            imdHeld += e.imd.balanceOf(actor);
        }
        // Sum physical ERC-20 custody once. The v4 claims above are claims against the manager's
        // physical IMD, not additional supply, and must not be added a second time here.
        address[11] memory system = [
            address(e.drop),
            address(e.seasons),
            address(e.box),
            address(e.tribunal),
            address(e.gate),
            address(e.hook),
            address(e.hook.poolManager()),
            address(e.hook.stacker()),
            e.hook.owner(),
            e.intake.PAY_TO(),
            e.runner
        ];
        for (uint256 i; i < system.length; ++i) {
            pleaHeld += e.token.balanceOf(system[i]);
            imdHeld += e.imd.balanceOf(system[i]);
        }
        assertEq(pleaHeld, e.token.totalSupply(), "every live PLEA token has an accounted holder");
        assertEq(imdHeld, e.imd.totalSupply(), "no IMD leaves the modeled participants");
        assertEq(e.token.balanceOf(address(e.drop)) + paidClaims, 120_000_000e18);
        assertEq(e.token.balanceOf(address(e.seasons)) + paidBonus + e.seasons.bonusBurned(), 60_000_000e18);
        assertEq(e.token.totalSupply() + e.hook.totalBurned() + e.seasons.bonusBurned(), 1_000_000_000e18);
        assertEq(credits, e.hook.totalCashback(), "cashback is staked, paid plain, or a backed v4 claim");
        uint256 ownerClaims =
            IPoolManager(address(e.hook.poolManager())).balanceOf(e.hook.owner(), uint256(uint160(address(e.imd))));
        assertEq(e.imd.balanceOf(e.hook.owner()) + ownerClaims, e.hook.totalOwnerFees());
        for (uint256 p; p < 8; ++p) {
            assertEq(e.drop.isClaimed(ClaimTree.index(p)), claimed[p]);
        }
        assertLe(e.hook.inventoryCap(), previousCap);
        assertGe(e.hook.inventoryCap(), 900_000e18);
        if (died) assertFalse(e.gate.cabalAlive());
    }

    function _answer(address consumer, bytes32 rid, uint256 score) internal returns (bool) {
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256(abi.encode("paid fee sequence", ++nonce));
        a.chainId = 1;
        a.questionHash = keccak256(e.intake.bodyOf(rid));
        a.answerType = OracleAttestation.ANSWER_UINT256;
        a.answer = abi.encode(score);
        a.figure = score;
        a.panelSize = 30;
        a.quorum = 17;
        a.agreed = 17;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(e.signerKey, OracleAttestationConsumer(consumer).attestationDigest(a));
        return e.intake.complete(rid, 0, abi.encode(rid, a, abi.encodePacked(r, s, v)));
    }

    function _credits(address actor) internal view returns (uint256) {
        return e.simd.balanceOf(actor)
            + IPoolManager(address(e.hook.poolManager())).balanceOf(actor, uint256(uint160(address(e.imd))));
    }

    function _cashback(address actor, uint256 before, uint256 credits) internal returns (uint256 plain) {
        plain = (e.hook.totalCashback() - before) - (_credits(actor) - credits);
        plainCashback += plain;
    }

    function _monotonic() internal {
        assertLe(e.hook.inventoryCap(), previousCap, "inventory cap can only fall");
        previousCap = e.hook.inventoryCap();
        if (died) assertFalse(e.gate.cabalAlive(), "death cannot reverse");
        if (!e.gate.cabalAlive()) died = true;
    }

    function _selector(bytes memory reason) internal pure returns (bytes4 sel) {
        if (reason.length >= 4) {
            assembly ("memory-safe") { sel := mload(add(reason, 32)) }
        }
    }
}
