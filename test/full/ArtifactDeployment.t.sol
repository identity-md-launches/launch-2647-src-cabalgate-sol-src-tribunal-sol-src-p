// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArtifactDeployment} from "../utils/ArtifactDeployment.sol";

contract ArtifactConstructorProbe {
    error InvalidArguments(address owner, uint256 amount, string reason);

    address public immutable creator;
    address public immutable owner;
    uint256 public immutable amount;
    bytes32 public immutable commitment;

    constructor(address owner_, uint256 amount_, bytes32 commitment_) {
        if (amount_ == 0) revert InvalidArguments(owner_, amount_, "constructor rejected the supplied amount");
        creator = msg.sender;
        owner = owner_;
        amount = amount_;
        commitment = commitment_;
    }
}

contract ArtifactDeploymentTest is Test {
    function test_artifactCreationPreservesConstructorCallerArgumentsAndRuntime() public {
        address owner = makeAddr("explicit launch owner");
        bytes32 commitment = keccak256("committed creation code");
        ArtifactConstructorProbe direct = new ArtifactConstructorProbe(owner, 123, commitment);
        ArtifactConstructorProbe loaded = ArtifactConstructorProbe(
            ArtifactDeployment.deploy(
                "ArtifactDeployment.t.sol:ArtifactConstructorProbe", abi.encode(owner, 123, commitment)
            )
        );
        assertEq(loaded.creator(), address(this));
        assertEq(loaded.owner(), owner);
        assertEq(loaded.amount(), direct.amount());
        assertEq(loaded.commitment(), direct.commitment());
        assertEq(address(loaded).code, address(direct).code);
        assertEq(address(loaded).balance, 0);
        assertEq(
            vm.getCode("ArtifactDeployment.t.sol:ArtifactConstructorProbe"), type(ArtifactConstructorProbe).creationCode
        );
    }

    function test_artifactCreationBubblesFullConstructorRevertData() public {
        address owner = makeAddr("explicit launch owner");
        vm.expectRevert(
            abi.encodeWithSelector(
                ArtifactConstructorProbe.InvalidArguments.selector,
                owner,
                uint256(0),
                "constructor rejected the supplied amount"
            )
        );
        ArtifactDeployment.deploy(
            "ArtifactDeployment.t.sol:ArtifactConstructorProbe", abi.encode(owner, uint256(0), bytes32(0))
        );
    }
}
