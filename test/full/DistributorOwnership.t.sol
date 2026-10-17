// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ArtifactDeployment} from "../utils/ArtifactDeployment.sol";

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PLEA} from "../../src/PLEA.sol";
import {PleaDistributor} from "../../src/PleaDistributor.sol";

/// Run 7 (run-6 permissions low): the distributor's ownership moves in two steps, like PLEA's, and
/// cannot be renounced before the one-time root is set, so a wrong handover cannot strand the 12%.
contract DistributorOwnershipTest is Test {
    PleaDistributor distributor;
    address owner = makeAddr("distributor owner");
    address next = makeAddr("next owner");

    function setUp() public {
        PLEA plea = PLEA(ArtifactDeployment.deploy("PLEA.sol:PLEA", abi.encode(owner)));
        distributor = PleaDistributor(
            ArtifactDeployment.deploy("PleaDistributor.sol:PleaDistributor", abi.encode(address(plea), owner))
        );
    }

    function test_ownershipMovesInTwoSteps() public {
        vm.prank(owner);
        distributor.transferOwnership(next);
        assertEq(distributor.owner(), owner, "a nomination alone moves nothing");
        assertEq(distributor.pendingOwner(), next);
        vm.prank(owner);
        distributor.setMerkleRoot(bytes32(uint256(1)));
        vm.prank(next);
        distributor.acceptOwnership();
        assertEq(distributor.owner(), next);
        assertEq(distributor.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        distributor.setMerkleRoot(bytes32(uint256(2)));
    }

    function test_aMistypedNomineeCanBeReplacedBeforeAccepting() public {
        vm.prank(owner);
        distributor.transferOwnership(makeAddr("typo"));
        vm.prank(owner);
        distributor.transferOwnership(next);
        assertEq(distributor.pendingOwner(), next);
        vm.prank(makeAddr("typo"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("typo")));
        distributor.acceptOwnership();
    }

    function test_noRenounceBeforeTheRootIsSet() public {
        vm.prank(owner);
        vm.expectRevert(PleaDistributor.RootNotSet.selector);
        distributor.renounceOwnership();
        vm.prank(owner);
        distributor.setMerkleRoot(bytes32(uint256(1)));
        vm.prank(owner);
        distributor.renounceOwnership();
        assertEq(distributor.owner(), address(0), "ownerless once the root is set: nothing is left to do");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        distributor.setMerkleRoot(bytes32(uint256(2)));
    }

    function test_onlyTheOwnerRenounces() public {
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        distributor.renounceOwnership();
    }
}
