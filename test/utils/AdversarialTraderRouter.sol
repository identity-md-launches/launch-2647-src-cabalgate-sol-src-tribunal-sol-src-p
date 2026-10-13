// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BuyRouter} from "./Mocks.sol";
import {PleaHook} from "src/PleaHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Uses the existing real PoolManager swap/settlement path. Only msgSender's response
/// is adversarial, including responses a Solidity address-returning function cannot encode.
contract AdversarialTraderRouter is BuyRouter {
    bytes public response;
    uint256 public behavior;
    uint256 public attemptedWrite;

    constructor(IPoolManager pm_, PleaHook hook_, IERC20 imd_, IERC20 plea_) BuyRouter(pm_, hook_, imd_, plea_) {}

    function configure(bytes memory response_, uint256 behavior_) external {
        response = response_;
        behavior = behavior_;
    }

    fallback() external {
        uint256 entryGas = gasleft();
        require(msg.sig == bytes4(keccak256("msgSender()")), "unexpected query");
        uint256 how = behavior;
        if (how == 1) revert("router cannot identify its caller");
        if (how == 2) {
            // Exhaust exactly the gas lent to this call without depending on loop optimization.
            assembly ("memory-safe") { invalid() }
        }
        if (how == 3) attemptedWrite = 1; // must fail under STATICCALL
        if (how == 4) require(entryGas <= 30_000 && entryGas > 29_000, "wrong gas stipend");
        if (how == 5) require(entryGas > 30_000, "needs more than the permitted stipend");
        bytes memory result = response;
        assembly ("memory-safe") { return(add(result, 32), mload(result)) }
    }
}
