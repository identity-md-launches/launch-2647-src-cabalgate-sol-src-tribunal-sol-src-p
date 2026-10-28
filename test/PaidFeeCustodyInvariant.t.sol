// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PaidFeeFixture} from "./PaidFeeAtomicity.t.sol";
import {PaidFeeCustodyHandler} from "./utils/PaidFeeCustodyHandler.sol";
import {ArtifactDeployment} from "./utils/ArtifactDeployment.sol";
import {ClaimTree} from "./utils/ClaimTree.sol";

/// @notice A default-profile campaign with real 15-day seasons, 33-hour dead-man, 400k credit gas,
/// 20,000 IMD opening cap, paid oracle fees, letters and objections all enabled together.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract PaidFeeCustodyInvariantTest is PaidFeeFixture {
    PaidFeeCustodyHandler internal handler;

    function setUp() public override {
        super.setUp();
        address dave = makeAddr("paid-fee fourth writer");
        fund(dave);
        buy(dave, 200e18);
        address[4] memory actors = [alice, bob, carol, dave];
        vm.prank(OWNER);
        distributor.setMerkleRoot(ClaimTree.tree(actors)[0]);
        PaidFeeCustodyHandler.Environment memory e = PaidFeeCustodyHandler.Environment({
            token: plea,
            gate: gate,
            box: letterbox,
            tribunal: tribunal,
            seasons: seasons,
            hook: hook,
            drop: distributor,
            imd: imd,
            simd: simd,
            intake: intake,
            router: router,
            actors: actors,
            runner: keeper,
            signerKey: SIGNER_KEY
        });
        handler = PaidFeeCustodyHandler(
            ArtifactDeployment.deploy("PaidFeeCustodyHandler.sol:PaidFeeCustodyHandler", abi.encode(e))
        );
        // Begin with both sorts of liabilities, so even a sequence starting with death/expiry
        // exercises real custody. A second letter remains pending for failure and timeout paths.
        handler.write(0, false);
        handler.answer(0, 45, false);
        handler.object(0, 1);
        handler.write(1, true);
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.claim.selector;
        selectors[2] = handler.write.selector;
        selectors[3] = handler.answer.selector;
        selectors[4] = handler.finishLetter.selector;
        selectors[5] = handler.object.selector;
        selectors[6] = handler.rule.selector;
        selectors[7] = handler.settleStake.selector;
        selectors[8] = handler.donate.selector;
        selectors[9] = handler.advance.selector;
        selectors[10] = handler.recordAndClose.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_everyOpenEscrowTipAndStakeRemainsBacked() public view {
        handler.assertCustody();
    }

    function invariant_supplyAllocationsAndEachWritersPleaAreConserved() public view {
        handler.assertConservation();
    }

    /// @dev Liveness after every random history: an unavailable oracle and absent owner cannot
    /// prevent refunds, stake settlement or the final season's close and unused-bonus burn.
    function afterInvariant() public {
        for (uint256 i; i < 7; ++i) {
            handler.advance(5 hours);
        }
        uint256 count = handler.letterCount();
        for (uint256 i; i < count; ++i) {
            handler.finishLetter(i, false);
        }
        uint256 stakes = handler.depositedStakes();
        for (uint256 i; i < stakes; ++i) {
            handler.settleStake(i);
        }
        handler.recordAndClose();
        handler.assertCustody();
        handler.assertConservation();
        (, uint256 open) = letterbox.openOf(address(0));
        assertEq(open, 0);
        assertEq(handler.paidStakes(), stakes);
        assertEq(imd.balanceOf(address(letterbox)), handler.boxDonations());
        assertEq(imd.balanceOf(address(tribunal)), handler.tribunalDonations());
        assertTrue(seasons.finished());
        assertEq(plea.balanceOf(address(seasons)), 0);
        assertEq(seasons.pot(), 0);
    }

    function test_sequenceWitnessReachesSalesRefundsStakesClaimsAndDeath() public {
        handler.rule(0, 45, false); // overrule: stake owes the season
        handler.object(0, 2); // a different wallet can use the second slot
        handler.rule(1, 0, false); // sustain: stake owes the objector
        handler.finishLetter(0, true); // sale is independent of sustained points
        handler.settleStake(0);
        handler.settleStake(1);
        handler.answer(1, 0, true); // pending site plea: unsigned failure returns its escrow
        handler.finishLetter(1, false);
        handler.write(2, false);
        handler.answer(2, 45, false);
        handler.object(2, 3);
        handler.rule(2, 0, true); // void objection: oracle fee spent, stake back
        handler.settleStake(2);
        handler.buy(2, 3e18, true); // reverting Stacker -> plain cashback
        handler.buy(3, 4e18, false); // healthy Stacker -> sIMD
        handler.claim(3, 0); // bitmap bit 255, relayed for dave
        handler.claim(4, 1); // bitmap bit 256, relayed for alice
        handler.claim(3, 2); // replay fails
        handler.donate(1, 1, false);
        handler.donate(2, 1e18, true);
        assertEq(handler.deliveries(), 1);
        assertEq(handler.refunds(), 1);
        assertEq(handler.rulings(), 2);
        assertEq(handler.voids(), 1);
        assertEq(handler.depositedStakes(), 3);
        assertEq(handler.paidStakes(), 3);
        assertGt(handler.plainCashback(), 0);
        invariant_everyOpenEscrowTipAndStakeRemainsBacked();
        invariant_supplyAllocationsAndEachWritersPleaAreConserved();
        afterInvariant();
        assertEq(handler.closes(), 1);
        assertTrue(handler.died());
    }
}
