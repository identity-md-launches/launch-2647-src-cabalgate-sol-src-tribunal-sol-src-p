// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "../utils/Fixture.sol";
import {Tribunal} from "../../src/Tribunal.sol";
import {CabalGate} from "../../src/CabalGate.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../../src/OracleAttestation.sol";

/// @notice What the Tribunal refuses: strangers, replays, the gate's signatures, bad panels, late
/// and unknown callbacks, and objections that break the case rules.
contract TribunalAdversarialTest is Fixture {
    address mallory = makeAddr("mallory");

    function withTribunal() internal pure override returns (bool) {
        return true;
    }

    function setUp() public virtual override {
        super.setUp();
        buy(alice, 50e18);
        buy(bob, 50e18);
        skip(1 days);
    }

    function pleaAndObjection() internal returns (uint256 id, uint256 oid, bytes32 intakeId) {
        id = approvedPlea(alice, 40);
        oid = objectTo(bob, id);
        intakeId = tribunal.objection(oid).intakeId;
    }

    function att(uint256 oid, uint256 score) internal view returns (OracleAttestation.Attestation memory) {
        return attestation(score, keccak256(abi.encode("objection", oid)));
    }

    function test_onlyTheIntakeMayDeliverARuling() public {
        (, uint256 oid, bytes32 intakeId) = pleaAndObjection();
        OracleAttestation.Attestation memory a = att(oid, 0);
        bytes memory sig = signFor(address(tribunal), a);
        vm.prank(mallory);
        vm.expectRevert(Tribunal.NotIntake.selector);
        tribunal.onOracleResult(intakeId, a, sig);
        vm.prank(mallory);
        vm.expectRevert(Tribunal.NotIntake.selector);
        tribunal.onObjectionFailure(intakeId, 2, bytes32("x"), 0, 0, "");
        assertEq(uint8(tribunal.objection(oid).ruling), uint8(Tribunal.Ruling.Pending));
    }

    function test_unknownRequestsAreRefused() public {
        (, uint256 oid,) = pleaAndObjection();
        OracleAttestation.Attestation memory a = att(oid, 0);
        bytes memory sig = signFor(address(tribunal), a);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(Tribunal.UnknownRequest.selector, bytes32("nope")));
        tribunal.onOracleResult(bytes32("nope"), a, sig);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(Tribunal.UnknownRequest.selector, bytes32("nope")));
        tribunal.onObjectionFailure(bytes32("nope"), 2, bytes32("x"), 0, 0, "");
    }

    function test_theGatesSignatureIsWorthlessHereAndTheReverse() public {
        (uint256 id, uint256 oid, bytes32 intakeId) = pleaAndObjection();
        OracleAttestation.Attestation memory a = att(oid, 0);
        bytes memory gateSig = signFor(address(gate), a);
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        tribunal.onOracleResult(intakeId, a, gateSig);
        // And a Tribunal-signed attestation cannot answer a plea on the gate.
        uint256 id2 = plead(bob, plea.balanceOf(bob) / 10);
        OracleAttestation.Attestation memory b = attestation(45, keccak256(abi.encode("oracle", id2)));
        bytes32 gateIntakeId = intakeIdOf(id2);
        bytes memory tribunalSig = signFor(address(tribunal), b);
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        gate.onOracleResult(gateIntakeId, b, tribunalSig);
        id;
    }

    function test_aReplayedAttestationIsRefused() public {
        (, uint256 oid,) = pleaAndObjection();
        assertTrue(rule(oid, 44));
        uint256 id2 = approvedPlea(bob, 40);
        uint256 oid2 = objectTo(alice, id2);
        // The same request id signed again for the second objection.
        OracleAttestation.Attestation memory a = att(oid, 0);
        bytes memory sig = signFor(address(tribunal), a);
        bytes32 intakeId2 = tribunal.objection(oid2).intakeId;
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId));
        tribunal.onOracleResult(intakeId2, a, sig);
    }

    function test_wrongPanelsAndScoresAreRefused() public {
        (, uint256 oid, bytes32 intakeId) = pleaAndObjection();
        OracleAttestation.Attestation memory a = att(oid, 30);
        a.panelSize = 29;
        bytes memory sig = signFor(address(tribunal), a);
        vm.prank(address(intake));
        vm.expectRevert(Tribunal.WrongPanel.selector);
        tribunal.onOracleResult(intakeId, a, sig);
        a = att(oid, 30);
        a.agreed = 16;
        sig = signFor(address(tribunal), a);
        vm.prank(address(intake));
        vm.expectRevert(Tribunal.WrongPanel.selector);
        tribunal.onOracleResult(intakeId, a, sig);
        a = att(oid, 30);
        a.chainId = 11155111;
        sig = signFor(address(tribunal), a);
        vm.prank(address(intake));
        vm.expectRevert(Tribunal.WrongPanel.selector);
        tribunal.onOracleResult(intakeId, a, sig);
        a = att(oid, 46);
        sig = signFor(address(tribunal), a);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(Tribunal.ScoreOutOfRange.selector, 46));
        tribunal.onOracleResult(intakeId, a, sig);
        assertEq(uint8(tribunal.objection(oid).ruling), uint8(Tribunal.Ruling.Pending));
    }

    function test_aLateRulingIsRefused() public {
        (, uint256 oid, bytes32 intakeId) = pleaAndObjection();
        skip(20 minutes + 1);
        OracleAttestation.Attestation memory a = att(oid, 0);
        bytes memory sig = signFor(address(tribunal), a);
        vm.prank(address(intake));
        vm.expectRevert(Tribunal.TooLate.selector);
        tribunal.onOracleResult(intakeId, a, sig);
        assertFalse(rule(oid, 0), "the Intake's delivery fails too");
        tribunal.expire(oid);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(Tribunal.UnknownRequest.selector, intakeId));
        tribunal.onObjectionFailure(intakeId, 2, bytes32("x"), 0, 0, "");
    }

    function test_aFailureAfterARulingChangesNothing() public {
        (, uint256 oid, bytes32 intakeId) = pleaAndObjection();
        assertTrue(rule(oid, 44));
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(Tribunal.UnknownRequest.selector, intakeId));
        tribunal.onObjectionFailure(intakeId, 2, bytes32("x"), 0, 0, "");
        assertEq(uint8(tribunal.objection(oid).ruling), uint8(Tribunal.Ruling.Overruled));
    }

    function test_theStakeCannotBeDrainedByTheGateOrByDoubleSettling() public {
        (, uint256 oid,) = pleaAndObjection();
        uint256 id2 = approvedPlea(bob, 40);
        uint256 oid2 = objectTo(alice, id2);
        assertTrue(rule(oid, 0)); // sustained: bob's stake back
        assertTrue(rule(oid2, 44)); // overruled: alice's stake to the pot
        assertEq(imd.balanceOf(address(tribunal)), 0.7e18);
        tribunal.settle(oid);
        tribunal.settle(oid2);
        assertEq(imd.balanceOf(address(tribunal)), 0);
        vm.expectRevert(abi.encodeWithSelector(Tribunal.AlreadySettled.selector, oid));
        tribunal.settle(oid);
        vm.expectRevert(abi.encodeWithSelector(Tribunal.AlreadySettled.selector, oid2));
        tribunal.settle(oid2);
    }

    function test_objectingNeedsTheStakeAndTheFee() public {
        uint256 id = approvedPlea(alice, 40);
        vm.prank(mallory); // no IMD, no approval
        vm.expectRevert();
        tribunal.object(id, "I object.");
    }

    function test_agreedNumbers() public view {
        assertEq(tribunal.STAKE(), 0.35e18);
        assertEq(tribunal.ORACLE_FEE(), 0.5e18);
        assertEq(tribunal.MAX_OBJECTIONS(), 2);
        assertEq(tribunal.MARGIN(), 2);
    }

    address[] sellers;
    address[] objectors;
    uint256 unsettled;

    function testFuzz_stakeAccountingHolds(uint8[6] memory scores, uint8 modes) public {
        // Six objections on six pleas: ruled (score), voided, or left pending, in a random mix. The
        // Tribunal's IMD is exactly the unsettled stakes; a sustained plea is never recorded.
        sellers = [alice, bob, carol, makeAddr("d"), makeAddr("e"), makeAddr("f")];
        objectors = [bob, carol, alice, makeAddr("g"), makeAddr("h"), makeAddr("i")];
        for (uint256 i = 2; i < 6; ++i) {
            fund(sellers[i]);
            buy(sellers[i], 50e18);
        }
        for (uint256 i = 3; i < 6; ++i) {
            fund(objectors[i]);
        }
        skip(2 hours);
        for (uint256 i; i < 6; ++i) {
            _round(i, scores[i] % 46, (modes >> (i * 2)) & 3);
            skip(5 minutes);
        }
    }

    function _round(uint256 i, uint8 score, uint8 mode) internal {
        uint256 id = approvedPlea(sellers[i], 40);
        uint256 oid = objectTo(objectors[i], id);
        unsettled += 0.35e18;
        if (mode == 0) {
            assertTrue(rule(oid, score));
        } else if (mode == 1) {
            intake.fail(tribunal.objection(oid).intakeId, 2, bytes32("disagreed"), 1, 2);
        }
        if (mode <= 1) {
            tribunal.settle(oid);
            unsettled -= 0.35e18;
        }
        assertEq(imd.balanceOf(address(tribunal)), unsettled, "IMD equals the unsettled stakes");
        _checkStanding(id);
    }

    function _checkStanding(uint256 id) internal {
        (bool held, bool sustained, uint8 lowest) = tribunal.standing(id);
        if (sustained) {
            assertTrue(lowest + 2 < gate.getPlea(id).need);
            vm.expectRevert();
            seasons.record(id);
        } else if (held) {
            vm.expectRevert();
            seasons.record(id);
        }
    }
}
