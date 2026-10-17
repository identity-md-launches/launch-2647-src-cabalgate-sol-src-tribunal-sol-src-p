// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SepoliaFixture} from "../utils/SepoliaFixture.sol";
import {MockIntake} from "../utils/Mocks.sol";
import {IIntake} from "src/interfaces/IPleaParts.sol";
import {Tribunal} from "src/Tribunal.sol";
import {Seasons} from "src/Seasons.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";

contract TribunalOracleBoundaryTest is SepoliaFixture {
    uint256 internal pleaId;
    uint256 internal objectionId;
    bytes32 internal requestId;
    uint256 constant STAKE = 0.35e18;

    function withTribunal() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        buy(alice, 50e18);
        buy(carol, 50e18);
        skip(1 days);
        pleaId = approvedPlea(alice, 40);
        objectionId = objectTo(bob, pleaId);
        requestId = tribunal.objection(objectionId).intakeId;
    }

    /// @dev Every reject is checked before a fresh, corrected attestation with the SAME UUID is
    /// delivered through the real mock Intake's 200k call. Reverting must undo _consume as well
    /// as the case transition; a swallowed validation error would fail the state snapshots.
    function test_invalidAttestationsAreAtomicAndDoNotConsumeTheRequest() public {
        for (uint256 mode; mode < 13; ++mode) {
            uint256 snapshot = vm.snapshotState();
            OracleAttestation.Attestation memory a = attestation(40, keccak256("correctable UUID"));
            bytes memory sig;
            bytes memory error;
            if (mode == 0) {
                a.expiresAt = uint64(block.timestamp - 1);
                error = abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt);
            } else if (mode == 1) {
                a.issuedAt = uint64(block.timestamp + 5 minutes + 1);
                error = abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt);
            } else if (mode == 2) {
                a.quorum = 16;
                error = abi.encodeWithSelector(Tribunal.WrongPanel.selector);
            } else if (mode == 3) {
                a.quorum = 21;
                a.agreed = 20; // above our minimum 17, below the signed quorum
                error = abi.encodeWithSelector(Tribunal.WrongPanel.selector);
            } else if (mode == 4) {
                a.answerType = OracleAttestation.ANSWER_BOOL;
                a.answer = abi.encode(true);
                error = abi.encodeWithSelector(OracleAttestationConsumer.WrongAnswerType.selector, uint8(3), uint8(0));
            } else if (mode == 5) {
                a.answer = new bytes(31); // one byte short of the canonical uint256
            } else if (mode == 6) {
                a.answer = abi.encode(type(uint256).max);
                error = abi.encodeWithSelector(Tribunal.ScoreOutOfRange.selector, type(uint256).max);
            } else if (mode == 7) {
                sig = signFor(address(tribunal), a);
                a.answer = abi.encode(0); // mutate after signing, keeping figure and UUID intact
                error = abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector);
            } else if (mode == 8) {
                // Read through the VM so via-IR cannot reuse CHAINID across the cheatcode.
                uint256 chain = vm.getChainId();
                vm.chainId(chain + 1);
                sig = signFor(address(tribunal), a);
                vm.chainId(chain);
                error = abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector);
            } else if (mode == 9) {
                (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, tribunal.attestationDigest(a));
                uint256 order = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
                sig = abi.encodePacked(r, bytes32(order - uint256(s)), v == 27 ? uint8(28) : uint8(27));
                error = abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector);
            } else if (mode == 10) {
                sig = hex"00";
                error = abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector);
            } else if (mode == 11) {
                a.panelSize = 29;
                error = abi.encodeWithSelector(Tribunal.WrongPanel.selector);
            } else {
                a.agreed = 16;
                error = abi.encodeWithSelector(Tribunal.WrongPanel.selector);
            }
            if (sig.length == 0) sig = signFor(address(tribunal), a);
            bytes32 beforeState = _stateHash();
            if (mode == 5) vm.expectRevert(); // ABI decoder has no custom error for a short word
            else vm.expectRevert(error);
            vm.prank(address(intake));
            tribunal.onOracleResult(requestId, a, sig);
            assertEq(_stateHash(), beforeState, "failed validation changed custody or the case");
            assertFalse(tribunal.consumed(a.requestId));
            assertEq(tribunal.objectionOfIntake(requestId), objectionId);

            OracleAttestation.Attestation memory corrected = attestation(40, a.requestId);
            assertTrue(
                intake.complete(requestId, 0, abi.encode(requestId, corrected, signFor(address(tribunal), corrected)))
            );
            assertTrue(tribunal.consumed(a.requestId));
            assertEq(uint8(tribunal.objection(objectionId).ruling), uint8(Tribunal.Ruling.Overruled));
            assertEq(imd.balanceOf(address(tribunal)), STAKE, "callbacks do not pay stakes");
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_signedValidityAndPendingDeadlineAreInclusiveAtTheirExactBoundaries() public {
        vm.warp(uint256(tribunal.objection(objectionId).filedAt) + 20 minutes);
        OracleAttestation.Attestation memory a = attestation(40, keccak256("inclusive deadline"));
        a.expiresAt = uint64(block.timestamp);
        bytes memory sig = signFor(address(tribunal), a);
        vm.expectRevert(Tribunal.NotStale.selector);
        tribunal.expire(objectionId);
        assertTrue(intake.complete(requestId, 0, abi.encode(requestId, a, sig)));
        assertEq(tribunal.caseOf(pleaId).count, 1);
    }

    function test_issuedAtToleratesExactlyFiveMinutesOfSignerClockDrift() public {
        OracleAttestation.Attestation memory a = attestation(40, keccak256("clock drift boundary"));
        a.issuedAt = uint64(block.timestamp + 5 minutes);
        assertTrue(intake.complete(requestId, 0, abi.encode(requestId, a, signFor(address(tribunal), a))));
        assertTrue(tribunal.consumed(a.requestId));
    }

    function test_validTribunalSignatureOnSomebodyElsesPaidRequestCannotRuleOurCase() public {
        bytes memory body = bytes(tribunal.body(objectionId));
        vm.prank(carol);
        oimd.approve(address(intake), type(uint256).max);
        vm.prank(carol);
        bytes32 foreign = intake.requestWithFailure(
            bytes32("oracle.request@oracle-1"),
            body,
            MockIntake.Callback(address(tribunal), tribunal.onOracleResult.selector),
            tribunal.onObjectionFailure.selector,
            address(oimd),
            0.5e18
        );
        OracleAttestation.Attestation memory a = attestation(0, keccak256("outsider's UUID"));
        bytes32 beforeState = _stateHash();
        assertFalse(intake.complete(foreign, 0, abi.encode(foreign, a, signFor(address(tribunal), a))));
        assertFalse(tribunal.consumed(a.requestId));
        assertEq(_stateHash(), beforeState, "paid foreign requests confer no authority");
        assertTrue(rule(objectionId, 40), "our request is still usable");
    }

    function test_unknownPaidFailureCannotVoidOurStake() public {
        vm.prank(carol);
        oimd.approve(address(intake), type(uint256).max);
        vm.prank(carol);
        bytes32 foreign = intake.requestWithFailure(
            bytes32("oracle.request@oracle-1"),
            bytes("{}"),
            MockIntake.Callback(address(tribunal), tribunal.onOracleResult.selector),
            tribunal.onObjectionFailure.selector,
            address(oimd),
            0.5e18
        );
        bytes32 beforeState = _stateHash();
        assertFalse(intake.fail(foreign, 1, bytes32("body_invalid"), 0, 0));
        assertEq(_stateHash(), beforeState);
        vm.expectRevert(abi.encodeWithSelector(Tribunal.NotRuled.selector, objectionId));
        tribunal.settle(objectionId);
    }

    function test_revertingRefundIsRetryableAndDoesNotBlockAnUnrelatedStake() public {
        assertTrue(rule(objectionId, 0));
        uint256 otherPlea = approvedPlea(carol, 40);
        uint256 other = objectTo(alice, otherPlea);
        assertTrue(rule(other, 45));
        bytes memory error = abi.encodeWithSignature("Error(string)", "recipient temporarily blocked");
        vm.mockCallRevert(address(imd), abi.encodeWithSignature("transfer(address,uint256)", bob, STAKE), error);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(error);
        tribunal.settle(objectionId);
        assertEq(_stateHash(), beforeState);
        assertFalse(tribunal.objection(objectionId).settled);
        tribunal.settle(other);
        assertEq(imd.balanceOf(address(tribunal)), STAKE, "unrelated pot payment succeeded");
        vm.clearMockedCalls();
        uint256 beforeBob = imd.balanceOf(bob);
        tribunal.settle(objectionId);
        assertEq(imd.balanceOf(bob), beforeBob + STAKE);
        assertEq(imd.balanceOf(address(tribunal)), 0);
    }

    function test_revertingCheckpointRollsBackBothTheTransferAndTheSettledFlag() public {
        assertTrue(rule(objectionId, 40));
        uint256 season = (gate.getPlea(pleaId).verdictAt - gate.startedAt()) / SEASON;
        uint256 fees = seasons.seasonFees(season);
        bytes memory error = abi.encodeWithSignature("Error(string)", "checkpoint failed");
        vm.mockCallRevert(address(seasons), abi.encodeCall(Seasons.checkpointObjection, (pleaId, STAKE)), error);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(error);
        tribunal.settle(objectionId);
        assertEq(_stateHash(), beforeState);
        assertEq(seasons.seasonFees(season), fees);
        vm.clearMockedCalls();
        tribunal.settle(objectionId);
        assertTrue(tribunal.objection(objectionId).settled);
        assertEq(seasons.seasonFees(season), fees + STAKE);
        assertEq(imd.balanceOf(address(tribunal)), 0);
    }

    function test_failedReplacementDoesNotVoidTheOldCaseOrTakeAnotherStake() public {
        intake.setFailureHooks(false);
        assertFalse(intake.fail(requestId, 2, bytes32("disagreed"), 0, 30));
        intake.setFailureHooks(true);
        vm.prank(carol);
        imd.approve(address(tribunal), type(uint256).max);
        bytes memory error = abi.encodeWithSignature("Error(string)", "Intake unavailable");
        vm.mockCallRevert(address(intake), abi.encodePacked(IIntake.requestWithFailure.selector), error);
        bytes32 beforeState = _stateHash();
        uint256 cash = imd.balanceOf(carol);
        uint256 minted = oimd.totalSupply();
        vm.expectRevert(error);
        vm.prank(carol);
        tribunal.object(pleaId, "The first request failed; please reconsider the craft.");
        assertEq(_stateHash(), beforeState, "automatic void is rolled back with the replacement");
        assertEq(imd.balanceOf(carol), cash);
        assertEq(oimd.totalSupply(), minted, "test fee mint also rolls back");
        assertEq(tribunal.nextId(), objectionId + 1);
        assertEq(tribunal.objectionOfIntake(requestId), objectionId);
        vm.clearMockedCalls();
        tribunal.expire(objectionId);
        tribunal.settle(objectionId);
        assertEq(imd.balanceOf(address(tribunal)), 0);
    }

    function _stateHash() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                tribunal.caseOf(pleaId),
                tribunal.objection(objectionId),
                tribunal.nextId(),
                imd.balanceOf(address(tribunal)),
                imd.balanceOf(bob),
                imd.balanceOf(address(seasons)),
                gate.getPlea(pleaId),
                gate.lastVerdictAt()
            )
        );
    }
}

/// @notice The protocol's independent fixed vector is checked on Tribunal itself, at the exact
/// vector address. A valid protocol signature gets as far as the application's panel rejection;
/// a supported uint256 answer then executes under the Intake's actual callback stipend.
contract TribunalProtocolVectorTest is SepoliaFixture {
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    Tribunal internal consumer;
    bytes32 internal intakeId;

    function withTribunal() internal pure override returns (bool) {
        return true;
    }

    function afterSeed() internal override {
        skip(1);
    }

    function setUp() public override {
        super.setUp();
        // deployCodeTo runs the actual argument-free constructor at the vector address. Its
        // caller supplies the real launch getters, including the gate's vector signer.
        vm.prank(address(launch));
        deployCodeTo("Tribunal.sol:Tribunal", VECTOR_CONSUMER);
        consumer = Tribunal(VECTOR_CONSUMER);
        buy(alice, 1e18);
        uint256 id = approvedPlea(alice, 45);
        vm.prank(bob);
        imd.approve(VECTOR_CONSUMER, type(uint256).max);
        vm.prank(bob);
        uint256 oid = consumer.object(id, "Please re-evaluate the quality of this text.");
        intakeId = consumer.objection(oid).intakeId;
    }

    function test_canonicalProtocolDigestSignatureAndCallbackSelectors() public {
        OracleAttestation.Attestation memory a = _vector();
        assertEq(consumer.attestationDigest(a), VECTOR_DIGEST);
        assertEq(consumer.onOracleResult.selector, bytes4(0x510379c7));
        assertEq(
            consumer.onObjectionFailure.selector,
            bytes4(keccak256("onObjectionFailure(bytes32,uint8,bytes32,uint16,uint16,bytes)"))
        );
        // The fixed vector is a five-seat bytes32[] answer, so Tribunal must reject its panel
        // AFTER authenticating the unchanged protocol signature (not with BadSignature).
        vm.expectRevert(Tribunal.WrongPanel.selector);
        vm.prank(address(intake));
        consumer.onOracleResult(intakeId, a, VECTOR_SIGNATURE);
        assertFalse(consumer.consumed(a.requestId));
    }

    function test_supportedVectorAnswerIsDeliveredUnderTwoHundredThousandGas() public {
        OracleAttestation.Attestation memory a = _vector();
        a.answerType = OracleAttestation.ANSWER_UINT256;
        a.answer = abi.encode(uint256(40));
        a.figure = 40;
        a.panelSize = 30;
        a.quorum = 17;
        a.agreed = 20;
        assertTrue(intake.complete(intakeId, 0, abi.encode(intakeId, a, signFor(VECTOR_CONSUMER, a))));
        assertTrue(consumer.consumed(a.requestId));
        assertEq(uint8(consumer.objection(1).ruling), uint8(Tribunal.Ruling.Overruled));
        assertFalse(consumer.objection(1).settled);
        assertEq(imd.balanceOf(VECTOR_CONSUMER), 0.35e18);
    }

    function _vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: 1800000000,
            expiresAt: 1800003600
        });
    }
}
