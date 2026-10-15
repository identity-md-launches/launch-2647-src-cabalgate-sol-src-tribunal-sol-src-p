// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @dev Real CREATE from the configured artifact, without duplicating its bytecode in each suite.
/// The constructor sees the calling test or script as msg.sender, exactly as with `new`.
/// Constructor revert data is preserved for the existing negative deployment tests.
library ArtifactDeployment {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function deploy(string memory artifact, bytes memory arguments) internal returns (address deployed) {
        bytes memory code = bytes.concat(VM.getCode(artifact), arguments);
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
            if iszero(deployed) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
    }
}
