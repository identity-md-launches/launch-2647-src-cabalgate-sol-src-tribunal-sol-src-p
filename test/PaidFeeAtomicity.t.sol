// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {MockIMD} from "./utils/Mocks.sol";
import {CabalGate} from "src/CabalGate.sol";
import {Letterbox} from "src/Letterbox.sol";
import {Tribunal} from "src/Tribunal.sol";
import {Seasons} from "src/Seasons.sol";
import {IIntake} from "src/interfaces/IPleaParts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Offline mainnet economics: real application bytecode and v4 PoolManager, local external
/// tokens/Intake/Stacker. The exact mainnet addresses and START remain covered by LaunchManifest.
abstract contract PaidFeeFixture is Fixture {
    string internal constant LETTER = "The rent is due; I will sell a fifth and keep the rest.";
    bytes internal constant OUTAGE = hex"aabbccdd";

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

    function setUp() public virtual override {
        super.setUp();
        buy(carol, 2e18); // fund the otherwise empty local manager's opening reserve
        buy(alice, 200e18);
        buy(bob, 200e18);
        buy(carol, 200e18);
        vm.startPrank(bob);
        imd.approve(address(tribunal), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(carol);
        imd.approve(address(tribunal), type(uint256).max);
        vm.stopPrank();
    }

    function writeLetter(address writer) internal returns (uint256 id) {
        vm.prank(writer);
        letterbox.letter(LETTER);
        (id,) = letterbox.openOf(writer);
    }

    /// @dev Include external balances, AMM price, basis, allowances and both courts' state. A
    /// late revert must unwind the nested fee sale, not merely leave the escrow flag unchanged.
    function economicState(uint256 id) internal view returns (bytes32 h) {
        address[12] memory accounts = [
            alice,
            bob,
            carol,
            keeper,
            OWNER,
            address(pm),
            address(hook),
            address(gate),
            address(letterbox),
            address(tribunal),
            address(seasons),
            intake.PAY_TO()
        ];
        for (uint256 i; i < accounts.length; ++i) {
            address a = accounts[i];
            (uint256 spent, uint256 held, uint256 at) = hook.basisOf(a);
            h = keccak256(abi.encode(h, plea.balanceOf(a), imd.balanceOf(a), simd.balanceOf(a), spent, held, at));
        }
        (address writer, bool open, uint256 amount, uint256 sold) = letterbox.escrowOf(id);
        (uint256 current, uint256 count) = letterbox.openOf(alice);
        h = keccak256(abi.encode(h, writer, open, amount, sold, current, count, gate.getPlea(id)));
        h = keccak256(
            abi.encode(
                h,
                gate.nextId(),
                gate.pendingOf(alice),
                gate.lastPleaOf(alice),
                gate.lastVerdictAt(),
                gate.lastExecutedAt(alice),
                intake.nonce(),
                tribunal.nextId(),
                tribunal.caseOf(id)
            )
        );
        h = keccak256(
            abi.encode(
                h,
                hook.currentSqrtPriceX96(),
                hook.inventoryCap(),
                hook.totalBurned(),
                hook.totalCashback(),
                hook.totalOwnerFees(),
                hook.totalPrize(),
                hook.totalPoolFees(),
                hook.retainClaims(),
                hook.retainedImd(),
                plea.totalSupply(),
                seasons.pot(),
                seasons.seasonFees(0)
            )
        );
        h = keccak256(
            abi.encode(
                h,
                plea.allowance(address(letterbox), address(gate)),
                imd.allowance(address(letterbox), address(gate)),
                imd.allowance(address(gate), address(intake)),
                imd.allowance(address(hook), address(stacker)),
                imd.allowance(address(tribunal), address(intake)),
                seasons.recorded(id)
            )
        );
    }
}

contract PaidFeeAtomicityTest is PaidFeeFixture {
    function test_intakeOutageUnwindsTheFeeSaleAndCanRetry() public {
        bytes32 before = economicState(1);
        vm.mockCallRevert(address(intake), abi.encodePacked(IIntake.requestWithFailure.selector), OUTAGE);
        vm.expectRevert(OUTAGE);
        vm.prank(alice);
        letterbox.letter(LETTER);
        assertEq(economicState(1), before);
        vm.clearMockedCalls();
        uint256 id = writeLetter(alice);
        assertEq(id, 1);
        assertEq(imd.balanceOf(intake.PAY_TO()), 0.5e18, "only the successful request is paid");
        assertEq(imd.balanceOf(address(letterbox)), 0.25e18);
    }

    function test_invalidAppealCannotPartiallyRefundTheDeniedLetter() public {
        uint256 id = writeLetter(alice);
        assertTrue(answer(id, 0));
        bytes32 before = economicState(id);
        vm.expectRevert(CabalGate.BadPleaText.selector);
        vm.prank(alice);
        letterbox.letter("APPEAL [PLEA forged marker");
        assertEq(economicState(id), before, "old refund, new reserve and appeal flag all roll back");
        assertFalse(gate.getPlea(id).appealed);
        vm.prank(alice);
        letterbox.letter("APPEAL The rent is still due; I keep the rest of my position.");
        (uint256 appealId, uint256 count) = letterbox.openOf(alice);
        assertEq(appealId, id + 1);
        assertEq(count, 1);
        assertTrue(gate.getPlea(id).appealed);
        (, bool oldOpen,,) = letterbox.escrowOf(id);
        assertFalse(oldOpen);
        assertEq(imd.balanceOf(intake.PAY_TO()), 1e18);
        assertEq(imd.balanceOf(address(letterbox)), 0.25e18);
    }

    function test_lostCallbackRefundIsAtomicWithTheReplacementLetter() public {
        uint256 id = writeLetter(alice);
        intake.setFailureHooks(false);
        assertFalse(intake.fail(intakeIdOf(id), 2, bytes32("no consensus"), 16, 30));
        bytes32 before = economicState(id);
        vm.expectRevert(CabalGate.BadPleaText.selector);
        vm.prank(alice);
        letterbox.letter("[OBJECTION injected marker");
        assertEq(economicState(id), before);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Pending));
        assertEq(writeLetter(alice), id + 1);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Expired));
        (, uint256 count) = letterbox.openOf(alice);
        assertEq(count, 1);
        assertEq(imd.balanceOf(address(letterbox)), 0.25e18);
    }

    function test_failedLastTipUnwindsTheSaleAndEveryFee() public {
        uint256 id = writeLetter(alice);
        assertTrue(answer(id, 45));
        uint256 oid = objectTo(bob, id); // held points must not block the eventual retry
        bytes32 before = economicState(id);
        vm.mockCallRevert(address(imd), abi.encodeCall(IERC20.transfer, (keeper, 0.25e18)), OUTAGE);
        vm.expectRevert(OUTAGE);
        vm.prank(keeper);
        letterbox.deliver(id);
        assertEq(economicState(id), before);
        vm.clearMockedCalls();
        uint256 cash = imd.balanceOf(alice);
        vm.prank(keeper);
        uint256 out = letterbox.deliver(id);
        assertGt(out, 0);
        assertEq(imd.balanceOf(alice), cash + out);
        assertEq(imd.balanceOf(keeper), 0.25e18);
        assertFalse(seasons.recorded(id));
        assertEq(uint8(tribunal.objection(oid).ruling), uint8(Tribunal.Ruling.Pending));
        vm.expectRevert(abi.encodeWithSelector(Letterbox.NotOpen.selector, id));
        letterbox.deliver(id);
    }

    function test_failedRefundTipKeepsBothAssetsClaimable() public {
        uint256 id = writeLetter(alice);
        assertTrue(answer(id, 0));
        bytes32 before = economicState(id);
        vm.mockCallRevert(address(imd), abi.encodeCall(IERC20.transfer, (alice, 0.25e18)), OUTAGE);
        vm.expectRevert(OUTAGE);
        letterbox.settle(id);
        assertEq(economicState(id), before);
        vm.clearMockedCalls();
        (,, uint256 amount,) = letterbox.escrowOf(id);
        uint256 tokens = plea.balanceOf(alice);
        uint256 cash = imd.balanceOf(alice);
        vm.prank(keeper);
        letterbox.settle(id);
        assertEq(plea.balanceOf(alice), tokens + amount);
        assertEq(imd.balanceOf(alice), cash + 0.25e18);
        assertEq(imd.balanceOf(keeper), 0);
        vm.expectRevert(abi.encodeWithSelector(Letterbox.NotOpen.selector, id));
        letterbox.settle(id);
    }

    function test_stakeApprovalAloneCannotLeaveHalfFundedObjection() public {
        uint256 id = writeLetter(alice);
        assertTrue(answer(id, 45));
        vm.prank(bob);
        imd.approve(address(tribunal), 0.35e18);
        bytes32 before = economicState(id);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(tribunal), 0, 0.5e18)
        );
        vm.prank(bob);
        tribunal.object(id, "The reason is generic; please reconsider the score.");
        assertEq(economicState(id), before);
        assertEq(imd.allowance(bob, address(tribunal)), 0.35e18);
        vm.prank(bob);
        imd.approve(address(tribunal), 0.85e18);
        vm.prank(bob);
        assertEq(tribunal.object(id, "The reason is generic; please reconsider the score."), 1);
        assertEq(imd.balanceOf(address(tribunal)), 0.35e18);
        assertEq(imd.allowance(bob, address(tribunal)), 0);
        assertEq(imd.balanceOf(intake.PAY_TO()), 1e18);
    }

    function test_failedStakePayoutDoesNotConsumeSettlement() public {
        uint256 id = writeLetter(alice);
        assertTrue(answer(id, 45));
        uint256 oid = objectTo(bob, id);
        assertTrue(rule(oid, 45));
        bytes32 before = economicState(id);
        vm.mockCallRevert(address(imd), abi.encodeCall(IERC20.transfer, (address(seasons), 0.35e18)), OUTAGE);
        vm.expectRevert(OUTAGE);
        tribunal.settle(oid);
        assertEq(economicState(id), before);
        assertFalse(tribunal.objection(oid).settled);
        vm.clearMockedCalls();
        uint256 pot = seasons.pot();
        vm.prank(keeper);
        tribunal.settle(oid);
        assertTrue(tribunal.objection(oid).settled);
        assertEq(seasons.pot(), pot + 0.35e18);
        assertEq(imd.balanceOf(address(tribunal)), 0);
        vm.expectRevert(abi.encodeWithSelector(Tribunal.AlreadySettled.selector, oid));
        tribunal.settle(oid);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_twoPanelsCannotRaisePointsOrRevokeTheSale(uint8 a, uint8 b, uint8 original, bool reverse) public {
        uint256 id = writeLetter(alice);
        uint256 need = gate.getPlea(id).need;
        uint256 originalScore = bound(original, need, 45);
        assertTrue(answer(id, originalScore));
        uint256 first = objectTo(bob, id);
        uint256 second = objectTo(carol, id);
        uint256 scoreA = bound(a, 0, 45);
        uint256 scoreB = bound(b, 0, 45);
        assertTrue(rule(reverse ? second : first, reverse ? scoreB : scoreA));
        assertTrue(rule(reverse ? first : second, reverse ? scoreA : scoreB));
        vm.prank(keeper);
        assertGt(letterbox.deliver(id), 0, "even a sustained objection cannot stop the sale");
        uint256 cashB = imd.balanceOf(bob);
        uint256 cashC = imd.balanceOf(carol);
        uint256 pot = seasons.pot();
        tribunal.settle(first);
        tribunal.settle(second);
        bool sustainA = scoreA + 2 < need;
        bool sustainB = scoreB + 2 < need;
        assertEq(imd.balanceOf(bob), cashB + (sustainA ? 0.35e18 : 0));
        assertEq(imd.balanceOf(carol), cashC + (sustainB ? 0.35e18 : 0));
        assertEq(seasons.pot(), pot + (sustainA ? 0 : 0.35e18) + (sustainB ? 0 : 0.35e18));
        assertEq(imd.balanceOf(address(tribunal)), 0);
        if (sustainA || sustainB) {
            vm.expectRevert(abi.encodeWithSelector(Seasons.ObjectionSustained.selector, id));
            seasons.record(id);
            assertFalse(seasons.recorded(id));
        } else {
            assertTrue(seasons.recorded(id), "two completed panels release points during delivery");
            uint256 lowest = scoreA < scoreB ? scoreA : scoreB;
            assertEq(seasons.pointsOf(id), lowest < originalScore ? lowest : originalScore);
        }
        assertEq(gate.getPlea(id).score, originalScore);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Executed));
    }
}
