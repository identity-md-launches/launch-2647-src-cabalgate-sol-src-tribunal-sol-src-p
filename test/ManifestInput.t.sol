// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ManifestFixture} from "./LaunchManifest.t.sol";
import {PleaLaunch} from "src/PleaLaunch.sol";
import {Tribunal} from "src/Tribunal.sol";

/// @notice Deploy bytes assembled from every actual launch.json argument. The existing manifest
/// fixture independently pins the intended values; comparing the two catches an edited static
/// argument or reference as well as a stale creation-code commitment.
contract ManifestInputTest is ManifestFixture {
    function test_everyManifestWordDeploysAtomicallyAndCommitsTheTribunal() public {
        bytes[5] memory fromJson = _readManifest();
        address[5] memory deployed = factory.deployAll(fromJson);
        for (uint256 i; i < 5; ++i) {
            assertEq(deployed[i], expected[i]);
        }
        _assertWiring();
        PleaLaunch launch = PleaLaunch(deployed[4]);
        bytes memory code = vm.getCode("Tribunal.sol:Tribunal");
        assertEq(keccak256(code), launch.tribunalCodeHash());
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(makeAddr("independent Tribunal deployer"));
        Tribunal tribunal = Tribunal(launch.deployTribunal(code));
        assertEq(address(tribunal), launch.predictTribunal());
        assertEq(tribunal.plea(), deployed[0]);
        assertEq(address(tribunal.gate()), deployed[1]);
        assertEq(address(tribunal.seasons()), deployed[2]);
        assertEq(address(tribunal.imd()), IMD);
        assertEq(address(tribunal.oracleAsset()), ORACLE_ASSET);
        assertEq(tribunal.mintOracleFee(), MINT_ORACLE_FEE);
        assertEq(tribunal.oracleSigner(), SIGNER);
    }

    function test_failedLastConstructorRollsBackAllEarlierDeploymentsAndCanRetry() public {
        bytes[5] memory fromJson = _readManifest();
        bytes memory finalCode = fromJson[4];
        fromJson[4] = hex"60006000fd"; // A failing last CREATE2 in the same factory transaction.
        vm.expectRevert();
        factory.deployAll(fromJson);
        for (uint256 i; i < 5; ++i) {
            assertEq(expected[i].code.length, 0, "no partial launch survives");
        }
        fromJson[4] = finalCode;
        factory.deployAll(fromJson);
        _assertWiring();
    }

    function _readManifest() internal view returns (bytes[5] memory fromJson) {
        string memory json = vm.readFile("launch.json");
        assertEq(vm.parseJsonString(json, ".kind"), "evm_contracts");
        assertFalse(vm.keyExistsJson(json, ".contracts[5]"), "exactly five launch applications");
        string[5] memory names = ["PLEA", "CabalGate", "Seasons", "PleaDistributor", "PleaLaunch"];
        uint256[5] memory argc = [uint256(1), 7, 4, 2, 13];
        for (uint256 i; i < 5; ++i) {
            string memory path = string.concat(".contracts[", vm.toString(i), "]");
            assertEq(vm.parseJsonString(json, string.concat(path, ".contract")), names[i], "deployment order");
            string[] memory args = vm.parseJsonStringArray(json, string.concat(path, ".constructorArgs"));
            assertEq(args.length, argc[i], "static constructor arity");
            bytes memory encoded;
            for (uint256 j; j < args.length; ++j) {
                bytes32 word;
                if (keccak256(bytes(args[j])) == keccak256(bytes("$owner"))) {
                    word = bytes32(uint256(uint160(owner)));
                } else if (bytes(args[j])[0] == "$") {
                    bool resolved;
                    for (uint256 k; k < i; ++k) {
                        if (keccak256(bytes(args[j])) == keccak256(bytes(string.concat("$contract:", names[k])))) {
                            word = bytes32(uint256(uint160(expected[k])));
                            resolved = true;
                            break;
                        }
                    }
                    assertTrue(resolved, "only backward application references are allowed");
                } else {
                    word = bytes32(vm.parseUint(args[j]));
                }
                encoded = bytes.concat(encoded, word);
            }
            fromJson[i] = bytes.concat(vm.getCode(string.concat(names[i], ".sol:", names[i])), encoded);
            assertEq(fromJson[i], codes[i], "manifest arguments must match the independent launch fixture");
        }
    }
}
