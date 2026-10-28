// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ArtifactDeployment} from "../test/utils/ArtifactDeployment.sol";

import {Script, console2} from "forge-std/Script.sol";
import {PLEA} from "../src/PLEA.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {Seasons} from "../src/Seasons.sol";
import {PleaDistributor} from "../src/PleaDistributor.sol";
import {Letterbox} from "../src/Letterbox.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {PleaLaunch} from "../src/PleaLaunch.sol";

/// @notice What the IMD launch does, as one script, for local runs and gas checks (a fork or anvil).
/// The real launch deploys the same five contracts in this order in one transaction (launch.json);
/// the Letterbox follows in its own transaction through `PleaLaunch.deployLetterbox`, as here.
/// Env: OWNER, INTAKE, ORACLE_ASSET, IMD, ORACLE_SIGNER, SEASON, DEADMAN, SEAT (the seat NFT: Seasons' 1.2x),
/// POOL_MANAGER, STACKER, CREDIT_GAS, START, MINT_ORACLE_FEE.
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        PLEA plea = PLEA(ArtifactDeployment.deploy("PLEA.sol:PLEA", abi.encode(vm.envAddress("OWNER"))));
        CabalGate gate = CabalGate(
            ArtifactDeployment.deploy(
                "CabalGate.sol:CabalGate",
                abi.encode(
                    address(plea),
                    vm.envAddress("INTAKE"),
                    vm.envAddress("ORACLE_ASSET"),
                    vm.envAddress("IMD"),
                    vm.envAddress("ORACLE_SIGNER"),
                    vm.envUint("SEASON"),
                    vm.envUint("DEADMAN")
                )
            )
        );
        Seasons seasons = Seasons(
            ArtifactDeployment.deploy(
                "Seasons.sol:Seasons",
                abi.encode(address(plea), address(gate), vm.envAddress("IMD"), vm.envAddress("SEAT"))
            )
        );
        PleaDistributor distributor = PleaDistributor(
            ArtifactDeployment.deploy(
                "PleaDistributor.sol:PleaDistributor", abi.encode(address(plea), vm.envAddress("OWNER"))
            )
        );
        PleaLaunch launch = PleaLaunch(
            ArtifactDeployment.deploy(
                "PleaLaunch.sol:PleaLaunch",
                abi.encode(
                    address(plea),
                    address(gate),
                    address(seasons),
                    address(distributor),
                    vm.envAddress("POOL_MANAGER"),
                    vm.envAddress("IMD"),
                    vm.envAddress("STACKER"),
                    vm.envUint("CREDIT_GAS"),
                    vm.envUint("START"),
                    vm.envAddress("ORACLE_ASSET"),
                    vm.envBool("MINT_ORACLE_FEE"),
                    keccak256(vm.getCode("Letterbox.sol:Letterbox")),
                    keccak256(vm.getCode("Tribunal.sol:Tribunal"))
                )
            )
        );
        address letterbox = launch.deployLetterbox(vm.getCode("Letterbox.sol:Letterbox"));
        address tribunal = launch.deployTribunal(vm.getCode("Tribunal.sol:Tribunal"));
        vm.stopBroadcast();
        console2.log("PLEA", address(plea));
        console2.log("CabalGate", address(gate));
        console2.log("Seasons", address(seasons));
        console2.log("PleaDistributor", address(distributor));
        console2.log("PleaLaunch", address(launch));
        console2.log("Letterbox", letterbox);
        console2.log("Tribunal", tribunal);
    }
}
