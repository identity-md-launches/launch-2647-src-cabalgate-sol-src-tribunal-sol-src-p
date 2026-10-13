// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PleaLaunch} from "../src/PleaLaunch.sol";
import {Tribunal} from "../src/Tribunal.sol";

/// @notice After the launch: deploys the Tribunal (Objection!) through `PleaLaunch.deployTribunal`
/// (anyone, once). Env: LAUNCH.
/// forge script script/DeployTribunal.s.sol --rpc-url $RPC --private-key $KEY --broadcast
contract DeployTribunal is Script {
    function run() external {
        PleaLaunch launch = PleaLaunch(vm.envAddress("LAUNCH"));
        bytes memory code = type(Tribunal).creationCode;
        require(keccak256(code) == launch.tribunalCodeHash(), "creation code differs from the launch's commitment");
        console2.log("Tribunal will be", launch.predictTribunal());
        vm.startBroadcast();
        address tribunal = launch.deployTribunal(code);
        vm.stopBroadcast();
        console2.log("Tribunal", tribunal);
    }
}
