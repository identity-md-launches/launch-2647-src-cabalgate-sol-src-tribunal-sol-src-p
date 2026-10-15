// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ArtifactDeployment} from "./ArtifactDeployment.sol";

import {Fixture} from "./Fixture.sol";
import {MockIMD} from "./Mocks.sol";

/// @dev Real application contracts and v4 PoolManager; only external oracle/quote/Stacker services
/// are mocked. Deployment-only exact addresses and START are covered by LaunchManifest.t.sol.
abstract contract SepoliaFixture is Fixture {
    function setUp() public virtual override {
        super.setUp();
        assertEq(hook.pleaIsZero(), pleaFirst(), "test must exercise its advertised currency order");
    }

    function pleaFirst() internal pure virtual returns (bool) {
        return false;
    }

    function deployImd() internal override {
        MockIMD implementation = MockIMD(ArtifactDeployment.deploy("Mocks.sol:MockIMD", bytes("")));
        address quote = pleaFirst() ? address(type(uint160).max - 100) : address(uint160(1 << 32));
        vm.etch(quote, address(implementation).code);
        imd = MockIMD(quote);
    }

    function setTimings() internal override {
        SEASON = 18000;
        DEADMAN = 118800;
    }

    function creditGasBudget() internal pure override returns (uint256) {
        return 1300000;
    }
}
