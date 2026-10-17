// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PLEA} from "src/PLEA.sol";
import {PleaDistributor} from "src/PleaDistributor.sol";
import {ArtifactDeployment} from "../utils/ArtifactDeployment.sol";
import {ClaimTree} from "../utils/ClaimTree.sol";

/// @dev Keeps PLEA's transfer restrictions on throughout this isolated distributor campaign.
contract Run7DistributionGate {
    function restricted() external pure returns (bool) {
        return true;
    }
}

contract Run7DistributionFactory {
    /// @dev One outer call preserves the constructor registration handshake on Forge 1.8.
    function deploy(address owner, address treasury, address reserve, address manager)
        external
        returns (PLEA token, PleaDistributor drop)
    {
        token = PLEA(ArtifactDeployment.deploy("PLEA.sol:PLEA", abi.encode(owner)));
        drop = PleaDistributor(
            ArtifactDeployment.deploy("PleaDistributor.sol:PleaDistributor", abi.encode(address(token), owner))
        );
        token.setLauncher(address(new Run7DistributionGate()), reserve, address(drop));
        token.init(treasury, manager);
    }
}

/// @dev The model starts BEFORE root publication. Root, handover, cancellation, renunciation,
/// invalid proofs, relayed claims and donations can interleave while the real PLEA is in custody.
contract Run7DistributionHandler is Test {
    PLEA public immutable token;
    PleaDistributor public immutable drop;
    address public immutable treasury;
    bytes32 public immutable committedRoot;
    address[4] public actors;
    address public expectedOwner;
    address public expectedPending;
    bool public published;
    bool[8] public claimed;
    uint256[4] public received;
    uint256 public donated;
    uint256 public paid;
    uint256 public rejected;
    uint256 public acceptedTransfers;
    uint256 public successfulClaims;

    constructor(PLEA token_, PleaDistributor drop_, address treasury_, address[4] memory actors_) {
        token = token_;
        drop = drop_;
        treasury = treasury_;
        actors = actors_;
        expectedOwner = actors_[0];
        committedRoot = ClaimTree.tree(actors_)[0];
    }

    function caller(uint256 seed, bool useOwner) internal view returns (address) {
        return useOwner && expectedOwner != address(0) ? expectedOwner : actors[seed % 4];
    }

    function unauthorized(address who) internal {
        ++rejected;
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who));
    }

    function nominate(uint256 callerSeed, uint256 nomineeSeed, bool useOwner, bool cancel) external {
        address who = caller(callerSeed, useOwner);
        address nominee = cancel ? address(0) : actors[nomineeSeed % 4];
        bool authorized = who == expectedOwner;
        if (!authorized) unauthorized(who);
        vm.prank(who);
        drop.transferOwnership(nominee);
        if (authorized) expectedPending = nominee;
    }

    function accept(uint256 callerSeed, bool usePending) external {
        address who = usePending && expectedPending != address(0) ? expectedPending : actors[callerSeed % 4];
        bool authorized = who == expectedPending;
        if (!authorized) unauthorized(who);
        vm.prank(who);
        drop.acceptOwnership();
        if (authorized) {
            expectedOwner = who;
            expectedPending = address(0);
            ++acceptedTransfers;
        }
    }

    function publish(uint256 callerSeed, bool useOwner, bool zeroRoot) external {
        address who = caller(callerSeed, useOwner);
        bool succeeds = who == expectedOwner && !published && !zeroRoot;
        if (who != expectedOwner) {
            unauthorized(who);
        } else if (published) {
            ++rejected;
            vm.expectRevert(PleaDistributor.RootAlreadySet.selector);
        } else if (zeroRoot) {
            ++rejected;
            vm.expectRevert(PleaDistributor.ZeroRoot.selector);
        }
        bytes32 root = zeroRoot ? bytes32(0) : published ? keccak256("replacement allocation") : committedRoot;
        vm.prank(who);
        drop.setMerkleRoot(root);
        if (succeeds) published = true;
    }

    function renounce(uint256 callerSeed, bool useOwner) external {
        address who = caller(callerSeed, useOwner);
        bool succeeds = who == expectedOwner && published;
        if (who != expectedOwner) {
            unauthorized(who);
        } else if (!published) {
            ++rejected;
            vm.expectRevert(PleaDistributor.RootNotSet.selector);
        }
        vm.prank(who);
        drop.renounceOwnership();
        if (succeeds) {
            expectedOwner = address(0);
            expectedPending = address(0);
        }
    }

    function claim(uint256 positionSeed, uint256 relayerSeed) external {
        uint256 p = positionSeed % 8;
        bytes32[] memory proof = ClaimTree.proof(actors, p);
        bool succeeds = published && !claimed[p];
        if (!published) {
            ++rejected;
            vm.expectRevert(PleaDistributor.RootNotSet.selector);
        } else if (claimed[p]) {
            ++rejected;
            vm.expectRevert(PleaDistributor.AlreadyClaimed.selector);
        }
        vm.prank(actors[relayerSeed % 4]);
        drop.claim(ClaimTree.index(p), actors[p % 4], ClaimTree.amount(p), proof);
        if (succeeds) {
            claimed[p] = true;
            received[p % 4] += ClaimTree.amount(p);
            paid += ClaimTree.amount(p);
            ++successfulClaims;
        }
    }

    function corruptClaim(uint256 positionSeed, uint256 fieldSeed) external {
        uint256 p = positionSeed % 8;
        uint256 index = ClaimTree.index(p);
        address recipient = actors[p % 4];
        uint256 amount = ClaimTree.amount(p);
        bytes32[] memory proof = ClaimTree.proof(actors, p);
        uint256 field = fieldSeed % 3;
        if (field == 0) recipient = actors[(p + 1) % 4];
        else if (field == 1) ++amount;
        else proof[0] ^= bytes32(uint256(1));
        ++rejected;
        vm.expectRevert(
            !published
                ? PleaDistributor.RootNotSet.selector
                : claimed[p] ? PleaDistributor.AlreadyClaimed.selector : PleaDistributor.InvalidProof.selector
        );
        vm.prank(actors[(p + 2) % 4]);
        drop.claim(index, recipient, amount, proof);
    }

    function donate(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, 0, token.balanceOf(treasury));
        vm.prank(treasury);
        token.transfer(address(drop), amount);
        donated += amount;
    }
}

/// @notice Kept in the default profile: exercise custody together with the run-7 Ownable2Step rule.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract Run7DistributorLifecycleTest is Test {
    PLEA internal token;
    PleaDistributor internal drop;
    Run7DistributionHandler internal handler;
    address[4] internal actors;
    address internal treasury;
    address internal reserve;

    function setUp() public {
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("run7 claimant ", vm.toString(i)));
        }
        treasury = makeAddr("run7 hook allocation");
        reserve = makeAddr("run7 seasons allocation");
        (token, drop) = new Run7DistributionFactory().deploy(actors[0], treasury, reserve, makeAddr("run7 manager"));
        handler = new Run7DistributionHandler(token, drop, treasury, actors);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.nominate.selector;
        selectors[1] = handler.accept.selector;
        selectors[2] = handler.publish.selector;
        selectors[3] = handler.renounce.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.corruptClaim.selector;
        selectors[6] = handler.donate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_rootAndAuthorityFollowOnlySuccessfulTransitions() public view {
        assertEq(drop.owner(), handler.expectedOwner());
        assertEq(drop.pendingOwner(), handler.expectedPending());
        assertEq(drop.merkleRoot(), handler.published() ? handler.committedRoot() : bytes32(0));
        if (!handler.published()) assertTrue(drop.owner() != address(0), "unpublished allocation must keep an owner");
        assertEq(token.owner(), actors[0], "distributor handovers must not change PLEA authority");
    }

    function invariant_noHandoverOrFailedClaimCanMoveTheAllocation() public view {
        uint256 recipientBalances;
        uint256 allocationPaid;
        for (uint256 i; i < 4; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.received(i), "leaf recipient is independent of relayer/owner");
            recipientBalances += token.balanceOf(actors[i]);
        }
        for (uint256 i; i < 8; ++i) {
            assertEq(drop.isClaimed(ClaimTree.index(i)), handler.claimed(i));
            if (handler.claimed(i)) allocationPaid += ClaimTree.amount(i);
        }
        assertEq(recipientBalances, allocationPaid);
        assertEq(allocationPaid, handler.paid());
        assertEq(token.balanceOf(address(drop)) + allocationPaid, 120_000_000e18 + handler.donated());
        assertEq(token.balanceOf(treasury) + handler.donated(), 820_000_000e18);
        assertEq(token.balanceOf(reserve), 60_000_000e18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function test_handoverBeforeRootThenRenunciationWithPendingNomineeLeavesClaimsLive() public {
        handler.claim(0, 3);
        handler.renounce(0, true);
        handler.publish(0, true, true);
        handler.nominate(0, 1, true, false);
        handler.publish(1, false, false); // a nomination does not grant root authority
        handler.accept(1, true);
        handler.publish(0, false, false); // old owner has lost root authority
        handler.publish(1, true, false);
        handler.claim(0, 2);
        handler.publish(1, true, false); // committed root is immutable
        handler.nominate(1, 2, true, false);
        handler.renounce(1, true);
        handler.accept(2, false); // renouncing cancels the outstanding nomination
        handler.corruptClaim(1, 0);
        handler.claim(0, 3); // replay must not pay again
        handler.donate(1);
        for (uint256 i = 1; i < 8; ++i) {
            handler.claim(i, (i + 1) % 4);
        }
        assertEq(handler.successfulClaims(), 8);
        assertEq(handler.acceptedTransfers(), 1);
        assertEq(handler.rejected(), 9);
        assertEq(drop.owner(), address(0));
        invariant_rootAndAuthorityFollowOnlySuccessfulTransitions();
        invariant_noHandoverOrFailedClaimCanMoveTheAllocation();
    }

    function test_replacingAndCancellingNomineesCannotStrandTheUnpublishedAllocation() public {
        handler.nominate(0, 1, true, false);
        handler.nominate(0, 2, true, false);
        handler.accept(1, false);
        handler.nominate(0, 0, true, true);
        handler.accept(2, false);
        handler.renounce(0, true);
        handler.publish(0, true, false);
        handler.claim(7, 3); // type(uint256).max bitmap index still works
        invariant_rootAndAuthorityFollowOnlySuccessfulTransitions();
        invariant_noHandoverOrFailedClaimCanMoveTheAllocation();
    }
}
