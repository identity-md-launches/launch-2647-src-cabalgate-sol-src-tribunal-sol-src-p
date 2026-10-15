// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PleaLaunch} from "../src/PleaLaunch.sol";
import {PleaHook} from "../src/PleaHook.sol";

/// @notice Mines PleaHook's CREATE2 salt off chain and calls `PleaLaunch.deployHook`.
/// Env: LAUNCH, POOL_MANAGER, IMD, STACKER, SEASONS, CREDIT_GAS (the launch's constructor values).
/// forge script script/MineSalt.s.sol --rpc-url $RPC --private-key $KEY --broadcast
contract MineSalt is Script {
    function run() external {
        PleaLaunch launch = PleaLaunch(vm.envAddress("LAUNCH"));
        bytes memory code = abi.encodePacked(
            vm.getCode("PleaHook.sol:PleaHook"),
            abi.encode(
                vm.envAddress("POOL_MANAGER"),
                launch.plea(),
                vm.envAddress("IMD"),
                vm.envAddress("STACKER"),
                launch.owner(),
                vm.envAddress("SEASONS"),
                vm.envUint("CREDIT_GAS")
            )
        );
        bytes32 h = keccak256(code);
        require(h == launch.hookInitCodeHash(), "init code differs from the launch's commitment");
        uint160 flags = launch.FLAGS();
        bytes32 salt;
        address hook;
        for (uint256 s;; ++s) {
            hook = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(launch), bytes32(s), h)))));
            if (uint160(hook) & 0x3fff == flags) {
                salt = bytes32(s);
                break;
            }
        }
        console2.log("salt", uint256(salt));
        console2.log("hook", hook);
        vm.startBroadcast();
        launch.deployHook(salt, code);
        vm.stopBroadcast();
    }
}
