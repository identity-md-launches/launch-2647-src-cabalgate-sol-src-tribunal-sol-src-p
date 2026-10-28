// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {MockIMD} from "./utils/Mocks.sol";
import {PLEA} from "../src/PLEA.sol";
import {Seasons} from "../src/Seasons.sol";
import {PleaDistributor} from "../src/PleaDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {CurrencyLibrary} from "v4-core/types/Currency.sol";

/// @notice Reproductions of the mainnet import's informational findings. These tests preserve
/// the documented record-time multiplier and voluntary system-recipient behavior, and check
/// that neither lets a stranger redirect another user's escrow or Merkle entitlement.
contract MainnetImportReviewTest is Fixture {
    function setTimings() internal override {
        vm.chainId(1);
    }

    function withTribunal() internal pure override returns (bool) {
        return true;
    }

    function oracleFeeToken() internal view override returns (MockIMD) {
        return imd;
    }

    function creditGasBudget() internal pure override returns (uint256) {
        return 400_000;
    }

    // 4bef999a: any eligible recorder fixes the multiplier, using the seller's seat at that time.
    function test_rivalRecordsBeforeSellerAcquiresSeat() public {
        buy(alice, 100e18);
        uint256 id = approvedPlea(alice, 45);
        uint256 alicePlea = plea.balanceOf(alice);
        uint256 aliceImd = imd.balanceOf(alice);
        uint256 bobImd = imd.balanceOf(bob);
        seat.mint(bob); // The recorder's seat must not multiply the seller's score.

        skip(20 minutes);
        vm.expectRevert(abi.encodeWithSelector(Seasons.Held.selector, id));
        vm.prank(bob);
        seasons.record(id);
        skip(1);
        vm.prank(bob);
        seasons.record(id);
        assertEq(seasons.pointsOf(id), 45);

        seat.mint(alice);
        assertEq(seasons.pointsFor(alice, 45), 54);
        vm.expectRevert(abi.encodeWithSelector(Seasons.AlreadyRecorded.selector, id));
        vm.prank(alice);
        seasons.record(id);
        assertEq(seasons.pointsOf(id), 45);
        assertEq(seasons.topOf(0)[0].wallet, alice);
        assertEq(seasons.topOf(0)[0].points, 45);
        assertEq(plea.balanceOf(alice), alicePlea);
        assertEq(imd.balanceOf(alice), aliceImd);
        assertEq(imd.balanceOf(bob), bobImd);
    }

    function test_rivalRecordsSeatHolderBeforeSeatLeaves() public {
        buy(alice, 100e18);
        uint256 id = approvedPlea(alice, 45);
        seat.mint(alice);
        skip(20 minutes + 1);
        vm.prank(bob);
        seasons.record(id);
        seat.burn(alice);
        assertEq(seasons.pointsFor(alice, 45), 45);
        assertEq(seasons.pointsOf(id), 54);
        assertEq(seasons.topOf(0)[0].points, 54);
        vm.expectRevert(abi.encodeWithSelector(Seasons.AlreadyRecorded.selector, id));
        seasons.record(id);
    }

    function test_rivalCannotRecordWhileAnObjectionIsPending() public {
        buy(alice, 100e18);
        uint256 id = approvedPlea(alice, 45);
        skip(19 minutes);
        uint256 objectionId = objectTo(carol, id);
        skip(1 minutes + 1);
        vm.expectRevert(abi.encodeWithSelector(Seasons.Held.selector, id));
        vm.prank(bob);
        seasons.record(id);

        seat.mint(alice);
        assertTrue(rule(objectionId, 40));
        vm.prank(bob);
        seasons.record(id);
        assertEq(seasons.pointsOf(id), 48, "lowest score, multiplied at the first eligible record");
        assertEq(gate.getPlea(id).score, 45, "the original verdict is unchanged");
    }

    // 609fb315: the buyer chooses a sink. Warm the pool so this exercises the Stacker credit,
    // rather than the opening reserve / ERC-6909 paths of a completely unfunded mock manager.
    function test_namedLetterboxBuyCreatesNoEscrowAndCreditsTheNamedRecipient() public {
        buy(carol, 2e18);
        uint256 aliceImd = imd.balanceOf(alice);
        uint256 beforeCashback = hook.totalCashback();
        vm.prank(alice);
        assertEq(router.buyExactIn(100e18, abi.encode(address(letterbox))), 0);

        uint256 received = plea.balanceOf(address(letterbox));
        assertGt(received, 0);
        assertEq(plea.balanceOf(alice), 0);
        assertEq(imd.balanceOf(alice), aliceImd - 100e18);
        assertEq(simd.balanceOf(alice), 0);
        uint256 cashback = hook.totalCashback() - beforeCashback;
        assertGt(cashback, 0);
        assertEq(simd.balanceOf(address(letterbox)), cashback);
        assertEq(simd.byProject(address(letterbox), address(hook)), cashback);
        (uint256 id, uint256 count) = letterbox.openOf(address(letterbox));
        assertEq(id, 0);
        assertEq(count, 0);
        assertEq(gate.nextId(), 1, "the donation did not create a plea");
        (, uint256 held,) = hook.basisOf(address(letterbox));
        assertEq(held, received);
    }

    function test_namedLetterboxBuyCannotChangeAnotherWritersRefund() public {
        buy(carol, 100e18);
        vm.prank(carol);
        letterbox.letter("I need rent this month and will keep the rest of my PLEA.");
        (uint256 id,) = letterbox.openOf(carol);
        (address writer, bool open, uint256 escrow,) = letterbox.escrowOf(id);
        assertEq(writer, carol);
        assertTrue(open);
        uint256 carolPlea = plea.balanceOf(carol);
        uint256 carolImd = imd.balanceOf(carol);
        uint256 tips = imd.balanceOf(address(letterbox));

        vm.prank(alice);
        router.buyExactIn(100e18, abi.encode(address(letterbox)));
        uint256 donated = plea.balanceOf(address(letterbox)) - escrow;
        assertGt(donated, 0);
        assertEq(imd.balanceOf(address(letterbox)), tips);
        (writer, open, escrow,) = letterbox.escrowOf(id);
        assertEq(writer, carol);
        assertTrue(open);
        assertEq(escrow, gate.getPlea(id).amount);

        assertTrue(answer(id, 0));
        vm.prank(bob);
        letterbox.settle(id);
        assertEq(plea.balanceOf(carol), carolPlea + escrow);
        assertEq(imd.balanceOf(carol), carolImd + 0.25e18);
        assertEq(plea.balanceOf(address(letterbox)), donated);
        assertEq(imd.balanceOf(address(letterbox)), tips - 0.25e18);
        (, uint256 count) = letterbox.openOf(carol);
        assertEq(count, 0);
        assertEq(plea.balanceOf(alice), 0);
        assertEq(plea.balanceOf(bob), 0);
    }

    function test_namedSeasonsBuyBurnsWithTheUnpaidBonus() public {
        buy(carol, 2e18);
        uint256 bonus = plea.balanceOf(address(seasons));
        vm.prank(alice);
        router.buyExactIn(100e18, abi.encode(address(seasons)));
        uint256 donated = plea.balanceOf(address(seasons)) - bonus;
        uint256 cashback = simd.balanceOf(address(seasons));
        assertGt(donated, 0);
        assertGt(cashback, 0);

        skip(33 hours + 1 hours + 1);
        seasons.closeSeason(new uint256[](0));
        seasons.flushToWall();
        assertEq(plea.balanceOf(address(seasons)), 0);
        assertEq(seasons.bonusBurned(), bonus + donated);
        assertEq(simd.balanceOf(address(seasons)), cashback);
        assertEq(plea.balanceOf(alice), 0);
    }

    function test_namedDistributorBuyDoesNotIncreaseAMerkleEntitlement() public {
        buy(carol, 2e18);
        uint256 allocation = plea.balanceOf(address(distributor));
        vm.prank(OWNER);
        distributor.setMerkleRoot(keccak256(abi.encodePacked(uint256(0), bob, allocation)));
        vm.prank(alice);
        router.buyExactIn(100e18, abi.encode(address(distributor)));
        uint256 donated = plea.balanceOf(address(distributor)) - allocation;
        uint256 cashback = simd.balanceOf(address(distributor));
        assertGt(donated, 0);
        assertGt(cashback, 0);

        vm.prank(alice);
        distributor.claim(0, bob, allocation, new bytes32[](0));
        assertEq(plea.balanceOf(bob), allocation);
        assertEq(plea.balanceOf(address(distributor)), donated);
        assertEq(simd.balanceOf(address(distributor)), cashback);
        vm.expectRevert(PleaDistributor.AlreadyClaimed.selector);
        distributor.claim(0, bob, allocation, new bytes32[](0));
        vm.expectRevert(PleaDistributor.InvalidProof.selector);
        distributor.claim(1, alice, donated, new bytes32[](0));
    }

    function test_namedGateBuyRevertsWithoutSpendingTheBuyersFunds() public {
        buy(carol, 2e18);
        uint256 aliceImd = imd.balanceOf(alice);
        uint256 supply = plea.totalSupply();
        uint256 burned = hook.totalBurned();
        // The PoolManager wraps the token error, then wraps the failed afterSwap callback.
        // Require the actual transfer restriction, not an unrelated swap failure.
        bytes memory transferError = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(plea),
            IERC20.transfer.selector,
            abi.encodeWithSelector(PLEA.CabalIsWatching.selector),
            abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                transferError,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        vm.prank(alice);
        router.buyExactIn(100e18, abi.encode(address(gate)));
        assertEq(imd.balanceOf(alice), aliceImd);
        assertEq(plea.balanceOf(address(gate)), 0);
        assertEq(plea.balanceOf(alice), 0);
        assertEq(simd.balanceOf(address(gate)), 0);
        assertEq(plea.totalSupply(), supply);
        assertEq(hook.totalBurned(), burned);
    }
}
