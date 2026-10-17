// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PleaHook} from "src/PleaHook.sol";
import {IStacker} from "src/interfaces/IStacker.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Exposes only the production resolver, without replacing any of its validation logic.
contract TraderResolverProbe is PleaHook {
    constructor(address manager_, address token_, address imd_, address stacker_, address owner_, address seasons_)
        PleaHook(IPoolManager(manager_), token_, IERC20(imd_), IStacker(stacker_), owner_, seasons_, 1_300_000)
    {}

    function resolve(address sender, bytes calldata data) external view returns (address) {
        return _resolveTrader(sender, data);
    }
}

contract MutableVaultDiscovery {
    bytes private response;
    bool private fails;

    function configure(bytes memory response_, bool fails_) external {
        response = response_;
        fails = fails_;
    }

    fallback() external {
        require(msg.sig == IStacker.SIMD.selector, "only vault discovery");
        require(!fails, "no SIMD getter");
        bytes memory result = response;
        assembly ("memory-safe") { return(add(result, 32), mload(result)) }
    }
}

/// forge-config: default.fuzz.runs = 256
contract TraderResolverBoundaryTest is Test {
    TraderResolverProbe internal probe;
    MutableVaultDiscovery internal discovery;
    address internal sender = makeAddr("direct wallet sender");
    address internal origin = makeAddr("unrelated transaction origin");
    address internal vault = makeAddr("vault discovered at deployment");
    address internal manager = makeAddr("resolver manager");
    address internal imd = makeAddr("resolver quote asset");

    function setUp() public {
        discovery = new MutableVaultDiscovery();
        discovery.configure(abi.encode(vault), false);
        probe = deployProbe(address(discovery));
    }

    function deployProbe(address stacker) internal returns (TraderResolverProbe deployed) {
        // Constructor hook validation still runs at a correctly flagged address.
        address at = address(uint160(0x1000028cc));
        deployCodeTo(
            "TraderResolverBoundary.t.sol:TraderResolverProbe",
            abi.encode(manager, makeAddr("resolver PLEA"), imd, stacker, address(this), makeAddr("resolver seasons")),
            at
        );
        deployed = TraderResolverProbe(at);
    }

    function test_plainWalletFallbackUsesSenderAndNeverTransactionOrigin() public {
        vm.prank(origin, origin);
        assertEq(probe.resolve(sender, ""), sender);
        assertEq(probe.resolve(sender, hex"ff"), sender);
        assertEq(probe.resolve(sender, abi.encode(address(0))), sender);
        assertEq(probe.resolve(sender, abi.encode(vault)), sender);
        assertEq(probe.resolve(sender, abi.encode(uint256(uint160(origin)) | (1 << 200))), sender);
        assertEq(probe.resolve(sender, abi.encode(origin)), origin, "explicit data still has priority");
    }

    function test_plainWalletInfrastructureIsExcludedEvenWithoutCode() public view {
        assertEq(manager.code.length, 0);
        assertEq(imd.code.length, 0);
        assertEq(vault.code.length, 0);
        assertEq(probe.resolve(manager, ""), address(0));
        assertEq(probe.resolve(imd, ""), address(0));
        assertEq(probe.resolve(vault, ""), address(0));
        assertEq(probe.resolve(address(0), ""), address(0));
    }

    function test_namedContractWalletIsAcceptedWhenItIsNotTheRouter() public view {
        assertGt(address(this).code.length, 0);
        assertEq(probe.resolve(sender, abi.encode(address(this))), address(this));
        // A contract sender with no msgSender() must not acquire a buy record by default.
        assertEq(probe.resolve(address(discovery), ""), address(0));
    }

    function test_vaultAddressIsCachedAndIsNotReadAgainDuringResolution() public {
        assertEq(probe.simd(), vault);
        discovery.configure("", true);
        assertEq(probe.simd(), vault);
        assertEq(probe.resolve(sender, abi.encode(vault)), sender, "cached vault remains excluded");
        discovery.configure(abi.encode(origin), false);
        assertEq(probe.simd(), vault, "a later discovery response cannot change the immutable");
        assertEq(probe.resolve(sender, abi.encode(origin)), origin);
    }

    function test_missingRevertingAndZeroVaultDiscoveryAllowsDeployment() public {
        probe = deployProbe(makeAddr("stacker not yet deployed"));
        assertEq(probe.simd(), address(0));
        discovery.configure("", true);
        probe = deployProbe(address(discovery));
        assertEq(probe.simd(), address(0));
        discovery.configure(abi.encode(address(0)), false);
        probe = deployProbe(address(discovery));
        assertEq(probe.simd(), address(0));
        assertEq(probe.resolve(sender, abi.encode(address(0))), sender);
    }

    function testFuzz_malformedVaultDiscoveryDoesNotRevertOrTruncate(uint8 rawLength, uint96 highBits) public {
        uint256 length = bound(rawLength, 0, 64);
        bytes memory response = new bytes(length);
        if (length >= 32) {
            uint256 word = uint256(uint160(vault)) | (bound(highBits, 1, type(uint96).max) << 160);
            assembly ("memory-safe") { mstore(add(response, 32), word) }
        }
        discovery.configure(response, false);
        probe = deployProbe(address(discovery));
        assertEq(probe.simd(), address(0), "invalid discovery must not blacklist an arbitrary low address");
        assertEq(probe.resolve(sender, abi.encode(vault)), vault);
    }
}
