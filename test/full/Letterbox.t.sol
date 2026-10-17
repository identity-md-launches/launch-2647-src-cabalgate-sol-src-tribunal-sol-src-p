// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ArtifactDeployment} from "../utils/ArtifactDeployment.sol";

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "../utils/Fixture.sol";
import {CabalGate} from "../../src/CabalGate.sol";
import {PLEA} from "../../src/PLEA.sol";
import {Letterbox} from "../../src/Letterbox.sol";
import {Seasons} from "../../src/Seasons.sol";
import {PleaHook} from "../../src/PleaHook.sol";
import {PleaLaunch} from "../../src/PleaLaunch.sol";
import {PleaDistributor} from "../../src/PleaDistributor.sol";
import {MockIMD} from "../utils/Mocks.sol";

/// Letters and auto-sell: plead by sending text to the Letterbox, fees paid in PLEA, escrow,
/// `deliver` by anyone for the tip, `settle` for every other ending.
contract LetterboxTest is Fixture {
    uint256 constant TIP = 0.25e18;
    uint256 constant AUTO_SELL_FEE = 0.35e18;

    function setUp() public virtual override {
        super.setUp();
        buy(alice, 50e18);
        buy(bob, 50e18);
        skip(1 days);
    }

    // ---------------------------------------------------------------- helpers

    function send(address who, bytes memory text) internal returns (bool ok, bytes memory ret) {
        vm.prank(who);
        (ok, ret) = address(letterbox).call(text);
    }

    function letter(address who, bytes memory text) internal returns (uint256 id) {
        (bool ok, bytes memory ret) = send(who, text);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return gate.lastPleaOf(who);
    }

    function assertLetterReverts(address who, bytes memory text, bytes memory err) internal {
        (bool ok, bytes memory ret) = send(who, text);
        assertFalse(ok, "letter should fail");
        assertEq(ret, err);
    }

    function escrowed(uint256 id) internal view returns (address writer, bool open, uint256 amount) {
        (writer, open, amount,) = letterbox.escrowOf(id);
    }

    // ---------------------------------------------------------------- function IDs

    /// @dev True if four bytes can start a valid letter: control-free UTF-8 (a character may be cut
    /// off at the end).
    function typeable(bytes4 sel) internal pure returns (bool) {
        uint256 i;
        while (i < 4) {
            uint8 c = uint8(sel[i]);
            if (c < 0x20 || c == 0x7f) return false;
            if (c < 0x80) {
                ++i;
                continue;
            }
            uint256 n;
            if (c >= 0xc2 && c <= 0xdf) n = 2;
            else if (c >= 0xe0 && c <= 0xef) n = 3;
            else if (c >= 0xf0 && c <= 0xf4) n = 4;
            else return false;
            for (uint256 k = 1; k < n; ++k) {
                if (i + k >= 4) return true;
                uint8 cc = uint8(sel[i + k]);
                if (cc & 0xc0 != 0x80) return false;
                if (k == 1) {
                    if ((c == 0xe0 && cc < 0xa0) || (c == 0xed && cc > 0x9f) || (c == 0xf0 && cc < 0x90)) return false;
                    if ((c == 0xf4 && cc > 0x8f) || (c == 0xc2 && cc <= 0x9f)) return false;
                }
            }
            i += n;
        }
        return true;
    }

    function test_noFunctionIdCanStartALetter() public view {
        string memory json = vm.readFile("out/Letterbox.sol/Letterbox.json");
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        assertGt(sigs.length, 8);
        for (uint256 i; i < sigs.length; ++i) {
            bytes4 sel = bytes4(keccak256(bytes(sigs[i])));
            assertFalse(typeable(sel), sigs[i]);
        }
        // The checker itself: ASCII text and a valid UTF-8 start are typeable, broken UTF-8 is not.
        assertTrue(typeable(bytes4("SELL")));
        assertTrue(typeable(bytes4(hex"c3a9e282")));
        assertFalse(typeable(bytes4(hex"3bd5d173")));
        assertFalse(typeable(bytes4(hex"41420a43")));
    }

    // ---------------------------------------------------------------- pleading by letter

    function test_letterPleadsTwentyPercentPaysFeesInPleaAndEscrows() public {
        uint256 bal = plea.balanceOf(alice);
        uint8 fact = gate.factScore(alice, bal * 20 / 100);
        uint256 intakeBefore = oimd.balanceOf(intake.PAY_TO());
        (uint256 feeImd, uint256 maxFeePlea) = letterbox.feesFor(false);
        assertEq(feeImd, TIP, "Sepolia: the oracle fee is minted, only the tip is bought");
        (, uint256 held,) = hook.basisOf(alice);

        uint256 id = letter(alice, "I bought on launch day and kept every token; I want a tenth to fix my bike.");

        CabalGate.Plea memory p = gate.getPlea(id);
        assertEq(p.seller, alice);
        assertEq(p.amount, bal * 20 / 100, "fixed 20%");
        assertEq(p.factScore, fact, "scored on the balance before anything moved");
        assertEq(p.flags, 3, "by letter, auto-sell");
        (address w, bool open, uint256 amount) = escrowed(id);
        assertEq(w, alice);
        assertTrue(open);
        assertEq(amount, bal * 20 / 100);
        assertEq(plea.balanceOf(address(letterbox)), bal * 20 / 100, "only the escrow stays");
        uint256 feePlea = bal - bal * 20 / 100 - plea.balanceOf(alice);
        assertGt(feePlea, 0);
        assertLe(feePlea, maxFeePlea, "fee swap within snapshot value + 10%");
        assertEq(imd.balanceOf(address(letterbox)), TIP, "the tip waits for the runner");
        assertEq(oimd.balanceOf(intake.PAY_TO()) - intakeBefore, 0.5e18, "the oracle fee reached the Intake");
        assertEq(oimd.balanceOf(address(letterbox)), 0);
        assertEq(plea.allowance(address(letterbox), address(gate)), 0);
        // The fee swap is a sale by alice: it reduces her buy record; the escrow does not.
        (, uint256 heldAfter,) = hook.basisOf(alice);
        assertLt(heldAfter, held);
        assertGt(heldAfter, held - bal * 20 / 100, "the escrowed fifth still counts as held");
    }

    function test_explorerLetterIsTheSameAsARawLetter() public {
        // The same text, sent as input data (alice) and typed into `letter` on an explorer (bob).
        string memory text = "A tenth for a new laptop; the other nine tenths stay with me all season.";
        uint256 raw = letter(alice, bytes(text));
        // Read after alice's letter: her fee sale moved the price, which is part of the fact score.
        uint256 balB = plea.balanceOf(bob);
        uint8 factB = gate.factScore(bob, balB * 20 / 100);
        vm.prank(bob);
        letterbox.letter(text);
        uint256 typed = gate.lastPleaOf(bob);
        CabalGate.Plea memory r = gate.getPlea(raw);
        CabalGate.Plea memory t = gate.getPlea(typed);
        assertEq(t.seller, bob);
        assertEq(t.text, r.text);
        assertEq(t.amount, balB * 20 / 100, "fixed 20%");
        assertEq(t.factScore, factB, "scored on the balance before anything moved");
        assertEq(t.flags, r.flags, "by letter, auto-sell");
        (address w, bool open, uint256 amount) = escrowed(typed);
        assertEq(w, bob);
        assertTrue(open);
        assertEq(amount, balB * 20 / 100);
        assertEq(imd.balanceOf(address(letterbox)), 2 * TIP);

        // APPEAL, SELL and NAME typed into `letter` work like the raw commands.
        answer(typed, 0);
        vm.prank(bob);
        letterbox.letter("APPEAL Plainly: the laptop is how I work, and I keep the rest.");
        uint256 a = gate.lastPleaOf(bob);
        assertTrue(gate.getPlea(a).isAppeal);
        assertEq(gate.getPlea(a).originalId, typed);
        // The same share of the balance as the original (slightly less PLEA: the fee sale shrank it).
        assertLe(gate.getPlea(a).amount, t.amount);
        assertLe(gate.getPlea(a).amount * 10_000 / gate.pleaBalance(a), 2_000, "still the 20% share band");
        assertEq(gate.getPlea(a).text, "Plainly: the laptop is how I work, and I keep the rest.");
        answer(a, 45);
        uint256 imdBefore = imd.balanceOf(bob);
        vm.prank(bob);
        letterbox.letter("SELL");
        assertEq(uint8(gate.getPlea(a).status), uint8(CabalGate.Status.Executed));
        assertTrue(seasons.recorded(a));
        assertGt(imd.balanceOf(bob) - imdBefore, TIP, "the sale and the writer's own tip");
        vm.prank(bob);
        letterbox.letter("NAME bob_by_explorer");
        assertEq(letterbox.nameOf(bob), "bob_by_explorer");

        // The same refusals: a stranger's SELL, and ETH.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Letterbox.NotOpen.selector, 0));
        letterbox.letter("SELL");
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        (bool ok,) = address(letterbox).call{value: 1}(abi.encodeCall(Letterbox.letter, ("money")));
        assertFalse(ok, "ETH is refused");
    }

    function test_letterCommandsParse() public {
        // A lower-case command and a command without a separator are plain pleas.
        uint256 id = letter(alice, "sell, please: my tenth for new shoes, the rest stays with me.");
        assertEq(gate.getPlea(id).text, "sell, please: my tenth for new shoes, the rest stays with me.");
        answer(id, 0);
        skip(4 hours);
        id = letter(alice, "SELLING is hard, but one tenth pays my rent; I keep the rest.");
        assertEq(gate.getPlea(id).text, "SELLING is hard, but one tenth pays my rent; I keep the rest.");
        // NAME sets the writer's name, nothing else.
        vm.prank(bob);
        (bool ok,) = address(letterbox).call("NAME bob_the_holder");
        assertTrue(ok);
        assertEq(letterbox.nameOf(bob), "bob_the_holder");
        assertEq(gate.lastPleaOf(bob), 0);
        assertLetterReverts(bob, "NAME Bad Name", abi.encodeWithSelector(Letterbox.BadName.selector));
    }

    function test_letterRefusesEthTinyBalancesAndBadText() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(letterbox).call{value: 1}("money");
        assertFalse(ok, "ETH is refused");
        // Empty text and markers fail in the gate, before anything is paid.
        assertLetterReverts(alice, "", abi.encodeWithSelector(CabalGate.BadPleaText.selector));
        assertLetterReverts(alice, "[PLEA] fake", abi.encodeWithSelector(CabalGate.BadPleaText.selector));
        assertEq(plea.balanceOf(address(letterbox)), 0);
        // A wallet whose fees would take more than 10% of its PLEA cannot plead by letter.
        address dust = makeAddr("dust");
        fund(dust);
        buy(dust, 0.01e18);
        (, uint256 maxFeePlea) = letterbox.feesFor(false);
        assertLt(plea.balanceOf(dust), maxFeePlea * 10);
        (ok,) = send(dust, "a small plea");
        assertFalse(ok);
    }

    function test_strangersCannotUseTheCourtEntryPoints() public {
        vm.expectRevert(PLEA.NotLetterbox.selector);
        plea.courtTake(alice, 1e18);
        vm.expectRevert(CabalGate.NotLetterbox.selector);
        gate.submitFor(alice, 1e18, 1e20, "x", 3, 0, 0);
        vm.expectRevert(CabalGate.NotLetterbox.selector);
        gate.appealFor(alice, 1, 1e18, 1e20, "x", 3, 0, 0);
        vm.expectRevert(CabalGate.NotLetterbox.selector);
        gate.executeSellFor(1, 0);
        vm.prank(address(letterbox));
        vm.expectRevert(CabalGate.BadFlags.selector);
        gate.submitFor(alice, 1e18, 1e20, "x", 1, 0, 0);
        // A direct send of PLEA to the Letterbox is refused like any other transfer.
        vm.prank(alice);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        plea.transfer(address(letterbox), 1e18);
    }

    // ---------------------------------------------------------------- deliver

    function test_anyoneDeliversAnApprovalForTheTip() public {
        uint256 id = letter(alice, "Ten percent for my dentist; ninety percent stays for the next season.");
        (,, uint256 amount) = escrowed(id);
        answer(id, 45);
        uint256 aliceImd = imd.balanceOf(alice);
        uint256 potBefore = imd.balanceOf(address(seasons));
        (, uint256 key,) = seasons.currentSeason();
        uint256 feesBefore = seasons.seasonFees(key);
        vm.prank(keeper);
        vm.recordLogs();
        uint256 out = letterbox.deliver(id);
        assertGt(out, 0);
        assertEq(_deliveredFee(vm.getRecordedLogs()), 0, "Delivered reports no fee for a letter");
        assertEq(imd.balanceOf(alice) - aliceImd, out, "the whole sale goes to the writer");
        assertLt(imd.balanceOf(address(seasons)) - potBefore, AUTO_SELL_FEE, "a letter pays no auto-sell fee");
        assertLt(seasons.seasonFees(key) - feesBefore, AUTO_SELL_FEE, "only the trade's 0.25% prize share");
        assertGe(out * 10_000, _spotValueOf(amount) * 9_500, "at least 95% of the snapshot value, whole");
        assertEq(imd.balanceOf(keeper), TIP, "the runner earns the tip");
        assertEq(imd.balanceOf(address(letterbox)), 0);
        assertEq(plea.balanceOf(address(letterbox)), 0);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Executed));
        assertTrue(seasons.recorded(id), "points recorded on delivery");
        (, bool open,, uint256 soldFor) = letterbox.escrowOf(id);
        assertFalse(open);
        assertEq(soldFor, out);
        assertGt(amount, 0);
        vm.expectRevert(abi.encodeWithSelector(Letterbox.NotOpen.selector, id));
        letterbox.deliver(id);
    }

    /// Run 7: only the site's auto-sell box pays the 0.35 IMD fee; a letter never does (its oracle
    /// fee and tip are already paid in PLEA, and the tip comes back on the writer's own SELL).
    function test_theSitesAutoSellBoxPaysTheFeeAndALetterDoesNot() public {
        uint256 potBefore = imd.balanceOf(address(seasons));
        (, uint256 key,) = seasons.currentSeason();
        uint256 feesBefore = seasons.seasonFees(key);
        uint256 fifth = plea.balanceOf(bob) / 5; // before the prank: a view call would consume it
        vm.prank(bob);
        uint256 siteId = letterbox.plead(fifth, "A fifth for a new roof; the rest keeps the house warm.");
        assertEq(gate.getPlea(siteId).flags, 2, "site box: auto-sell without the letter flag");
        answer(siteId, 45);
        uint256 bobImd = imd.balanceOf(bob);
        vm.recordLogs();
        vm.prank(keeper);
        uint256 out = letterbox.deliver(siteId);
        assertEq(_deliveredFee(vm.getRecordedLogs()), AUTO_SELL_FEE, "the site's box pays the fee");
        assertEq(imd.balanceOf(bob) - bobImd, out);
        assertGe(imd.balanceOf(address(seasons)) - potBefore, AUTO_SELL_FEE, "the auto-sell fee reached the pot");
        assertGe(seasons.seasonFees(key) - feesBefore, AUTO_SELL_FEE, "and is accounted to the running season");
        // The same writer's letter: no fee.
        skip(4 hours + 1);
        uint256 id = letter(bob, "A fifth for the chimney now; the rest of the roof is paid for.");
        assertEq(gate.getPlea(id).flags, 3, "letter: by letter and auto-sell");
        answer(id, 45);
        uint256 pot2 = imd.balanceOf(address(seasons));
        bobImd = imd.balanceOf(bob);
        vm.recordLogs();
        vm.prank(keeper);
        out = letterbox.deliver(id);
        assertEq(_deliveredFee(vm.getRecordedLogs()), 0, "a letter pays no auto-sell fee");
        assertEq(imd.balanceOf(bob) - bobImd, out, "the whole sale goes to the writer");
        assertLt(imd.balanceOf(address(seasons)) - pot2, AUTO_SELL_FEE, "only the trade's prize share");
        assertEq(imd.balanceOf(keeper), 2 * TIP, "the runner earned both tips");
    }

    /// Run 7: an over-long letter is refused by name, with its byte count and the limit.
    function test_anOverLongLetterIsRefusedByName() public {
        bytes memory text = new bytes(281);
        for (uint256 i; i < 281; ++i) {
            text[i] = "a";
        }
        assertLetterReverts(alice, text, abi.encodeWithSelector(Letterbox.LetterTooLong.selector, 281, 280));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Letterbox.LetterTooLong.selector, 281, 280));
        letterbox.plead(1_000_000e18, string(text));
        // 280 bytes pass the length check (the gate then judges the text itself).
        bytes memory ok = new bytes(280);
        for (uint256 i; i < 280; ++i) {
            ok[i] = "b";
        }
        uint256 id = letter(alice, ok);
        assertEq(bytes(gate.getPlea(id).text).length, 280);
        // Cyrillic: two bytes a character, so 141 characters are 282 bytes.
        bytes memory cyr;
        for (uint256 i; i < 141; ++i) {
            cyr = bytes.concat(cyr, unicode"я");
        }
        assertEq(cyr.length, 282);
        skip(4 hours + 1);
        assertLetterReverts(bob, cyr, abi.encodeWithSelector(Letterbox.LetterTooLong.selector, 282, 280));
    }

    function _deliveredFee(Vm.Log[] memory logs) internal pure returns (uint256 fee) {
        fee = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == Letterbox.Delivered.selector) {
                (,, fee) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
    }

    function _spotValueOf(uint256 amount) internal view returns (uint256) {
        return amount * hook.latestPrice() / (1 << 96);
    }

    function test_deliverNeedsAnApprovalInsideTheWindowAndTheMinimum() public {
        uint256 id = letter(alice, "A tenth for my sister's wedding gift; the rest of my bag is not for sale.");
        vm.expectRevert(CabalGate.NotApproved.selector);
        letterbox.deliver(id);
        answer(id, 45);
        // A snapshot that values the PLEA far above what the pool pays: below 95%, no sale.
        uint256 price = hook.latestPrice();
        vm.mockCall(address(hook), abi.encodeWithSelector(PleaHook.latestPrice.selector), abi.encode(price * 2));
        vm.expectPartialRevert(CabalGate.SlippageExceeded.selector);
        letterbox.deliver(id);
        vm.clearMockedCalls();
        skip(7 minutes + 1);
        vm.expectRevert(CabalGate.WindowLapsed.selector);
        letterbox.deliver(id);
    }

    function test_theSellLetterIsTheWritersOwnSale() public {
        uint256 id = letter(alice, "A tenth to pay for a course; I hold the rest and will plead again later.");
        answer(id, 45);
        vm.prank(alice);
        (bool ok,) = address(letterbox).call("SELL");
        assertTrue(ok);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Executed));
        assertEq(imd.balanceOf(address(letterbox)), 0, "the tip went back to the writer");
        assertTrue(seasons.recorded(id));
        assertLetterReverts(bob, "SELL", abi.encodeWithSelector(Letterbox.NotOpen.selector, 0));
    }

    /// The auto-sell fee is only ever taken from a sale: a denial refunds everything but the fee
    /// PLEA, and a plea worth less than twice the fee at the snapshot is refused up front.
    function test_autoSellFeeOnlyOnASaleAndNeverMoreThanHalfOfIt() public {
        uint256 pot = imd.balanceOf(address(seasons));
        uint256 id = letter(alice, "A tenth for my rent this month; the rest stays in my wallet for good.");
        answer(id, 0);
        letterbox.settle(id);
        assertLt(
            imd.balanceOf(address(seasons)) - pot,
            AUTO_SELL_FEE,
            "no auto-sell fee without a sale (only the trade's prize share)"
        );
        // The site's auto-sell: an amount worth less than 0.70 IMD at the snapshot is refused.
        uint256 price = hook.latestPrice();
        uint256 tooSmall = (0.7e18 - 1) * (1 << 96) / price;
        vm.prank(bob);
        vm.expectPartialRevert(Letterbox.TooSmallForTheFee.selector);
        letterbox.plead(tooSmall, "A sliver for a coffee; the rest stays.");
        uint256 justEnough = 0.72e18 * (1 << 96) / price;
        vm.prank(bob);
        uint256 small = letterbox.plead(justEnough, "A sliver for a coffee; the rest stays.");
        answer(small, 45);
        uint256 bobImd = imd.balanceOf(bob);
        uint256 out = letterbox.deliver(small);
        assertEq(imd.balanceOf(bob) - bobImd, out);
        assertGe(out * 2 + 1, AUTO_SELL_FEE * 2 * 95 / 100, "the writer keeps at least about half");
    }

    /// The judge's run-4 finding: a letter worth 0.70-0.75 IMD cleared the floor, but its appeal,
    /// clamped to the same share of a balance shrunk by the fee sale, landed under 0.70 IMD and was
    /// refused. The appeal is now raised back to the floor's worth (never above the original).
    function test_anAppealOfAFloorSizedLetterIsNotRefused() public {
        address w = makeAddr("floorWriter");
        fund(w);
        buy(w, 3.64e18);
        buy(bob, 1e18); // the hour's checkpoint
        uint256 price = hook.latestPrice();
        uint256 value20 = (plea.balanceOf(w) * 20 / 100) * price / (1 << 96);
        assertGe(value20, 0.7e18, "setup: the letter must clear the floor");
        assertLt(value20, 0.76e18, "setup: the letter must sit in the floor band");
        uint256 id = letter(w, "A fifth for the electrician; the rest stays until the lights go out.");
        uint256 original = gate.getPlea(id).amount;
        answer(id, 0);
        uint256 a = letter(w, "APPEAL The electrician does not wait; the rest still stays.");
        uint256 amount = gate.getPlea(a).amount;
        assertLe(amount, original, "never above the original");
        assertGe(amount * price / (1 << 96) + 1, 0.7e18, "raised back to the floor's worth");
        assertTrue(gate.getPlea(a).isAppeal);
        // The raise lands above 20% of the shrunken balance; the band stays the original's.
        assertGt(amount * 10_000 / plea.balanceOf(w), 2_000, "setup: the raise crosses the band");
        assertEq(gate.getPlea(a).need, gate.getPlea(id).need, "a floor raise keeps the original's share band");
        // appealAuto takes the same path.
        answer(a, 0);
    }

    function test_theGateRefusesAManualSaleOfAnEscrowedPlea() public {
        uint256 id = letter(alice, "A tenth for my rent this month; the rest stays in my wallet for good.");
        answer(id, 45);
        vm.prank(alice);
        vm.expectRevert(CabalGate.UseLetterbox.selector);
        gate.executeSell(0);
    }

    // ---------------------------------------------------------------- settle

    function test_settleReturnsEscrowAndTipAfterADenial() public {
        uint256 before = plea.balanceOf(alice);
        uint256 id = letter(alice, "I would like a tenth back to buy a guitar; I promise to keep the rest.");
        uint256 feePlea = before - gate.getPlea(id).amount - plea.balanceOf(alice);
        // Pending and fresh: a verdict can still come, so the gate will not let it expire.
        vm.expectRevert(CabalGate.NotStale.selector);
        letterbox.settle(id);
        answer(id, 0);
        uint256 imdBefore = imd.balanceOf(alice);
        vm.prank(carol);
        letterbox.settle(id);
        assertEq(plea.balanceOf(alice), before - feePlea, "escrow back, only the fee PLEA is gone");
        assertEq(imd.balanceOf(alice) - imdBefore, TIP, "tip back");
        vm.expectRevert(abi.encodeWithSelector(Letterbox.NotOpen.selector, id));
        letterbox.settle(id);
    }

    function test_noVerdictSettlesAtOnceAndTheNextLetterSettlesTheOldOne() public {
        uint256 id = letter(alice, "One tenth for a plane ticket home; nine tenths stay right here.");
        assertTrue(intake.fail(intakeIdOf(id), 2, bytes32("disagreed"), 13, 28));
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Expired));
        // No cooldown after a failure: the next letter settles the old escrow first.
        uint256 next = letter(alice, "Asking again, plainly: one tenth for the ticket, the rest stays.");
        assertGt(next, id);
        (, bool open,) = escrowed(id);
        assertFalse(open);
        (uint256 openId, uint256 count) = letterbox.openOf(alice);
        assertEq(openId, next);
        assertEq(count, 1);
    }

    function test_aLapsedApprovalSettlesAndStillCounts() public {
        uint256 id = letter(alice, "A tenth for my cat's surgery; the rest of the bag is staying.");
        answer(id, 40);
        skip(7 minutes + 1);
        letterbox.settle(id);
        assertTrue(seasons.recorded(id), "a lapsed approval still counts for its season");
        assertEq(plea.balanceOf(address(letterbox)), 0);
        assertEq(imd.balanceOf(address(letterbox)), 0);
    }

    function test_expiredPendingPleaSettlesAfterTwentyMinutes() public {
        uint256 id = letter(alice, "A tenth to pay a friend back; I keep the rest and my word.");
        skip(20 minutes + 1);
        letterbox.settle(id);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Expired));
    }

    // ---------------------------------------------------------------- appeals

    function test_appealByLetterKeepsTheOriginalShareAndPaysTheWall() public {
        uint256 id = letter(alice, "A tenth for school books; the rest is not for sale.");
        uint256 amount = gate.getPlea(id).amount;
        answer(id, 0);
        uint256 wall = hook.retainedImd();
        uint256 a = letter(alice, "APPEAL I was too brief: the books cost 40 IMD and I keep the rest.");
        CabalGate.Plea memory p = gate.getPlea(a);
        assertTrue(p.isAppeal);
        assertEq(p.originalId, id);
        assertLe(p.amount, amount, "at most the original amount: the original's share of the shrunk balance");
        assertGt(p.amount * 1000, amount * 990, "within 1% of it");
        assertLe(p.amount * 10_000 / gate.pleaBalance(a), 2_000, "still the 20% share band");
        assertEq(p.text, "I was too brief: the books cost 40 IMD and I keep the rest.");
        assertEq(hook.retainedImd() - wall, 0.35e18, "the wall share");
        assertEq(imd.balanceOf(address(letterbox)), TIP);
        (, bool openOld,) = escrowed(id);
        assertFalse(openOld, "the denied plea was settled first");
        answer(a, 45);
        letterbox.deliver(a);
        assertEq(uint8(gate.getPlea(a).status), uint8(CabalGate.Status.Executed));
        // No second appeal.
        skip(4 hours);
        assertLetterReverts(alice, "APPEAL again", abi.encodeWithSelector(CabalGate.NotDenied.selector));
    }

    /// An appeal the oracle never answered (failure or 20-minute expiry) may be retried, as the gate
    /// allows: the APPEAL letter appeals the denied plea again, not the expired appeal.
    function test_appealLetterRetriesAnAppealTheOracleNeverAnswered() public {
        uint256 id = letter(alice, "A tenth for rent; the rest stays with me all season.");
        answer(id, 0);
        uint256 a = letter(alice, "APPEAL Plainly: the rent is due on Friday, and I keep the rest.");
        assertTrue(intake.fail(intakeIdOf(a), 2, bytes32("disagreed"), 13, 28));
        assertFalse(gate.getPlea(id).appealed);
        uint256 retry = letter(alice, "APPEAL Once more: the rent is due on Friday; nine tenths stay.");
        CabalGate.Plea memory p = gate.getPlea(retry);
        assertTrue(p.isAppeal);
        assertEq(p.originalId, id);
        (, bool openOld,) = escrowed(a);
        assertFalse(openOld, "the expired appeal's escrow was settled first");
        answer(retry, 45);
        letterbox.deliver(retry);
        // An upheld appeal cannot be appealed again.
        skip(4 hours);
        uint256 d = letter(alice, "A tenth for rent; the rest stays with me all season.");
        answer(d, 0);
        uint256 u = letter(alice, "APPEAL The rent again.");
        answer(u, 0);
        assertLetterReverts(alice, "APPEAL once more", abi.encodeWithSelector(CabalGate.AlreadyAppealed.selector));
    }

    /// A command word alone is the command, never a plea: `NAME` clears the name (like `NAME `),
    /// `APPEAL` with nothing to appeal is refused, and no PLEA moves.
    function test_aBareCommandWordIsNotAPlea() public {
        uint256 before = plea.balanceOf(alice);
        vm.prank(alice);
        letterbox.setName("alice_1");
        (bool ok,) = send(alice, "NAME");
        assertTrue(ok);
        assertEq(letterbox.nameOf(alice), "");
        assertLetterReverts(alice, "APPEAL", abi.encodeWithSelector(Letterbox.NothingToAppeal.selector));
        assertEq(gate.lastPleaOf(alice), 0, "no plea was opened");
        assertEq(plea.balanceOf(alice), before);
        // With a denial to appeal, a bare APPEAL has no text and is refused by the gate.
        uint256 id = letter(alice, "A tenth for rent; the rest stays with me all season.");
        answer(id, 0);
        assertLetterReverts(alice, "APPEAL", abi.encodeWithSelector(CabalGate.BadPleaText.selector));
        assertLetterReverts(alice, "APPEAL\n", abi.encodeWithSelector(CabalGate.BadPleaText.selector));
        assertEq(gate.lastPleaOf(alice), id);
    }

    function test_siteAutoSellPleadsAnyValidAmount() public {
        uint256 amount = plea.balanceOf(alice) / 20;
        vm.prank(alice);
        uint256 id = letterbox.plead(amount, "Five percent for a gift; the rest stays.");
        assertEq(gate.getPlea(id).amount, amount);
        assertEq(gate.getPlea(id).flags, 2, "auto-sell, not a letter");
        answer(id, 0);
        vm.prank(alice);
        uint256 a = letterbox.appealAuto(id, "Five percent, still a gift, still keeping the rest.");
        assertEq(gate.getPlea(a).flags, 2);
        // Below the 0.70 IMD minimum value the Letterbox refuses before the gate's 1% minimum.
        uint256 amt101 = plea.balanceOf(bob) / 200;
        vm.prank(bob);
        vm.expectPartialRevert(Letterbox.TooSmallForTheFee.selector);
        letterbox.plead(amt101, "too small");
        address whale = makeAddr("whale");
        fund(whale);
        imd.mint(whale, 2_000e18);
        buy(whale, 2_000e18);
        uint256 halfPercent = plea.balanceOf(whale) / 200;
        vm.prank(whale);
        vm.expectRevert(CabalGate.AmountTooSmall.selector);
        letterbox.plead(halfPercent, "half a percent is too small for the gate");
    }

    // ---------------------------------------------------------------- status and leaderboard

    function test_statusTellsEachState() public {
        assertEq(letterbox.status(alice), "No plea yet. Next plea possible now.");
        uint256 id = letter(alice, "A tenth for my sister's school trip; the rest stays put.");
        string memory s = letterbox.status(alice);
        assertTrue(vm.contains(s, "PENDING"), s);
        answer(id, 40);
        s = letterbox.status(alice);
        assertTrue(vm.contains(s, "APPROVED (40 vs"), s);
        assertTrue(vm.contains(s, "selling automatically"), s);
        letterbox.deliver(id);
        s = letterbox.status(alice);
        assertTrue(vm.contains(s, "SOLD for "), s);
        assertTrue(vm.contains(s, "+40 points (season 1, rank 1)"), s);
        assertTrue(vm.contains(s, "Cooldown until "), s);
        skip(4 hours);
        uint256 d = letter(alice, "Another tenth, for the trip home this time; the rest stays.");
        answer(d, 0);
        s = letterbox.status(alice);
        assertTrue(vm.contains(s, "DENIED (0 vs"), s);
        assertTrue(vm.contains(s, "send APPEAL <text> before "), s);
        assertTrue(vm.contains(s, "call settle to get your PLEA back"), s);
        letterbox.settle(d);
        assertTrue(vm.contains(letterbox.status(alice), "PLEA and tip returned"), letterbox.status(alice));
    }

    function test_leaderboardListsTheSeason() public {
        uint256 id = letter(alice, "A tenth for my sister's school trip; the rest stays put.");
        answer(id, 40);
        letterbox.deliver(id);
        string memory b = letterbox.leaderboard();
        assertTrue(vm.contains(b, "Season 1"), b);
        assertTrue(vm.contains(b, "+ 10,000,000 PLEA"), b);
        assertTrue(vm.contains(b, "1. 0x"), b);
        assertTrue(vm.contains(b, "40 pts (needs 60)"), b);
        vm.prank(alice);
        letterbox.setName("alice_w");
        assertTrue(vm.contains(letterbox.leaderboard(), "1. alice_w"), letterbox.leaderboard());
    }

    function test_deadCabalRefusesLettersButSettles() public {
        uint256 id = letter(alice, "A tenth for my rent; the rest stays with me.");
        vm.warp(uint256(gate.lastVerdictAt()) + gate.DEADMAN());
        assertEq(letterbox.status(alice), "The Cabal is dead. PLEA trades freely.");
        skip(21 minutes);
        letterbox.settle(id);
        (bool ok,) = send(bob, "too late");
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- names

    /// A `NAME` letter and the site's `setName` follow the same rules: 3-20 characters a-z 0-9 _,
    /// unique, reserved words refused; a failed rename keeps the old name.
    function test_invalidNamesAndFailedRenamesPreserveTheOldReservation() public {
        vm.prank(alice);
        letterbox.setName("alice_1");
        string[12] memory invalid = [
            "a",
            "ab",
            "abcdefghijklmnopqrstu",
            "Alice",
            "bad name",
            "bad-name",
            "cabal",
            "admin",
            "imd",
            "plea",
            "owner",
            "a\nb"
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(Letterbox.BadName.selector);
            letterbox.setName(invalid[i]);
            assertLetterReverts(
                alice, bytes(string.concat("NAME ", invalid[i])), abi.encodeWithSelector(Letterbox.BadName.selector)
            );
            assertEq(letterbox.nameOf(alice), "alice_1");
            assertEq(letterbox.nameOwner(keccak256("alice_1")), alice);
        }
        vm.prank(bob);
        letterbox.setName("bob_2");
        vm.prank(alice);
        vm.expectRevert(Letterbox.NameTaken.selector);
        letterbox.setName("bob_2");
        assertLetterReverts(alice, "NAME bob_2", abi.encodeWithSelector(Letterbox.NameTaken.selector));
        assertEq(letterbox.nameOwner(keccak256("alice_1")), alice);
        assertEq(letterbox.nameOwner(keccak256("bob_2")), bob);
    }

    function testFuzz_namesAreUniqueIdempotentAndReleasedOnClear(uint256 seed, uint8 rawLength) public {
        uint256 length = bound(rawLength, 3, 20);
        bytes memory name = new bytes(length);
        name[0] = "_"; // avoids reserved words while exercising the whole remaining alphabet
        bytes memory alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_";
        for (uint256 i = 1; i < length; ++i) {
            name[i] = alphabet[uint256(keccak256(abi.encode(seed, i))) % alphabet.length];
        }
        vm.startPrank(alice);
        letterbox.setName(string(name));
        letterbox.setName(string(name));
        vm.stopPrank();
        assertEq(letterbox.nameOf(alice), string(name));
        assertEq(letterbox.nameOwner(keccak256(name)), alice);
        vm.prank(bob);
        vm.expectRevert(Letterbox.NameTaken.selector);
        letterbox.setName(string(name));
        letter(alice, "NAME "); // an empty NAME clears it
        assertEq(letterbox.nameOf(alice), "");
        vm.prank(bob);
        letterbox.setName(string(name));
        assertEq(letterbox.nameOwner(keccak256(name)), bob);
    }

    // ---------------------------------------------------------------- deployment after the launch

    /// The Letterbox is deployed after the launch through PleaLaunch, once, from the committed code;
    /// it reads its settings from PleaLaunch and PLEA registers it.
    function test_letterboxIsDeployedOnceFromTheCommittedCode() public {
        assertEq(address(letterbox), launch.letterbox());
        assertEq(address(letterbox), launch.predictLetterbox());
        assertEq(plea.letterbox(), address(letterbox));
        assertEq(launch.letterboxCodeHash(), keccak256(vm.getCode("Letterbox.sol:Letterbox")));
        vm.expectRevert(PleaLaunch.LetterboxAlreadyDeployed.selector);
        launch.deployLetterbox(vm.getCode("Letterbox.sol:Letterbox"));
        vm.prank(OWNER);
        vm.expectRevert(PLEA.NotLauncher.selector);
        plea.setLetterbox(alice);
    }

    function test_deployLetterboxRefusesOtherCode() public {
        PleaLaunch fresh = _freshLaunch();
        bytes memory other = abi.encodePacked(vm.getCode("Letterbox.sol:Letterbox"), uint256(1));
        vm.expectRevert(PleaLaunch.WrongInitCode.selector);
        fresh.deployLetterbox(other);
        vm.prank(makeAddr("anyone"));
        address lb = fresh.deployLetterbox(vm.getCode("Letterbox.sol:Letterbox"));
        assertEq(lb, fresh.predictLetterbox());
        assertEq(fresh.letterbox(), lb);
        assertEq(PLEA(fresh.plea()).letterbox(), lb, "registered by PLEA");
    }

    /// A second launch's contracts (PLEA, gate, seasons, distributor, PleaLaunch) in one call.
    function _freshLaunch() internal returns (PleaLaunch fresh) {
        PLEA p = PLEA(ArtifactDeployment.deploy("PLEA.sol:PLEA", abi.encode(OWNER)));
        CabalGate g = CabalGate(
            ArtifactDeployment.deploy(
                "CabalGate.sol:CabalGate",
                abi.encode(address(p), address(intake), address(oimd), address(imd), SIGNER, SEASON, DEADMAN)
            )
        );
        Seasons ss = Seasons(
            ArtifactDeployment.deploy(
                "Seasons.sol:Seasons", abi.encode(address(p), address(g), address(imd), address(0))
            )
        );
        PleaDistributor d = PleaDistributor(
            ArtifactDeployment.deploy("PleaDistributor.sol:PleaDistributor", abi.encode(address(p), OWNER))
        );
        fresh = PleaLaunch(
            ArtifactDeployment.deploy(
                "PleaLaunch.sol:PleaLaunch",
                abi.encode(
                    address(p),
                    address(g),
                    address(ss),
                    address(d),
                    address(pm),
                    address(imd),
                    address(stacker),
                    CREDIT_GAS,
                    T0 + 2 days,
                    address(oimd),
                    true,
                    keccak256(vm.getCode("Letterbox.sol:Letterbox")),
                    bytes32(0)
                )
            )
        );
    }
}

/// The owner of PLEA does not play: no points, prizes or bonus.
contract OwnerExclusionTest is Fixture {
    function setUp() public virtual override {
        super.setUp();
        fund(OWNER);
        buy(OWNER, 50e18);
        buy(alice, 50e18);
        skip(1 days);
    }

    function test_ownerPleasEarnNoPoints() public {
        uint256 id = plead(OWNER, plea.balanceOf(OWNER) / 10);
        answer(id, 45);
        vm.expectRevert(Seasons.OwnerExcluded.selector);
        seasons.record(id);
        // closeSeason skips it quietly (the season ends when the Cabal dies, 33 silent hours later).
        vm.warp(uint256(gate.lastVerdictAt()) + gate.DEADMAN() + 1 hours);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        seasons.closeSeason(ids);
        assertFalse(seasons.recorded(id));
    }

    /// The judge's run-4 finding: the exclusion used to follow PLEA's owner of the moment, so a two-step
    /// handover inside the team let the former owner (still paid the hook's 0.5%) collect a prize.
    function test_theLaunchOwnerStaysExcludedAfterAHandover() public {
        uint256 id = plead(OWNER, plea.balanceOf(OWNER) / 10);
        answer(id, 45);
        address second = makeAddr("second");
        vm.prank(OWNER);
        plea.transferOwnership(second);
        vm.prank(second);
        plea.acceptOwnership();
        assertEq(plea.owner(), second);
        assertEq(hook.owner(), OWNER, "the fee beneficiary never changes");
        vm.expectRevert(Seasons.OwnerExcluded.selector);
        seasons.record(id);
        // closeSeason drops it quietly: no prize, no bonus.
        vm.warp(uint256(gate.lastVerdictAt()) + gate.DEADMAN() + 1 hours);
        uint256 ownerPlea = plea.balanceOf(OWNER);
        uint256 ownerImd = imd.balanceOf(OWNER);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        seasons.closeSeason(ids);
        assertFalse(seasons.recorded(id));
        assertEq(plea.balanceOf(OWNER), ownerPlea, "no bonus reached the former owner");
        assertEq(imd.balanceOf(OWNER), ownerImd, "no prize reached the former owner");
    }

    function test_nobodyGetsAKeeperTip() public {
        imd.mint(address(this), 200e18);
        imd.approve(address(hook), 200e18);
        hook.fundWall(200e18);
        assertTrue(hook.pendingRebalance());
        uint256 before = imd.balanceOf(keeper);
        vm.prank(keeper);
        hook.rebalance();
        assertEq(imd.balanceOf(keeper), before, "rebalance pays no tip to anyone");
    }
}

/// The mainnet path: the oracle fee asset is the pool IMD, so a letter buys the oracle fee with PLEA
/// together with the tip (no minting), and the Letterbox refuses to mint on chain id 1.
contract LetterboxMainnetPathTest is Fixture {
    function oracleFeeToken() internal view override returns (MockIMD) {
        return imd;
    }

    function setUp() public virtual override {
        super.setUp();
        buy(alice, 50e18);
        skip(1 days);
    }

    function test_letterBuysTheOracleFeeAndTheTipWithPlea() public {
        (uint256 feeImd, uint256 maxFeePlea) = letterbox.feesFor(false);
        assertEq(feeImd, 0.5e18 + 0.25e18, "oracle fee + tip");
        uint256 bal = plea.balanceOf(alice);
        uint256 intakeBefore = imd.balanceOf(intake.PAY_TO());
        vm.prank(alice);
        (bool ok,) = address(letterbox).call("One tenth for a new phone; nine tenths stay with me all season.");
        assertTrue(ok);
        uint256 id = gate.lastPleaOf(alice);
        assertEq(imd.balanceOf(intake.PAY_TO()) - intakeBefore, 0.5e18, "the Intake was paid in IMD");
        assertEq(imd.balanceOf(address(letterbox)), 0.25e18, "only the tip stays");
        uint256 feePlea = bal - bal * 20 / 100 - plea.balanceOf(alice);
        assertLe(feePlea, maxFeePlea);
        (feeImd,) = letterbox.feesFor(true);
        assertEq(feeImd, 0.5e18 + 0.35e18 + 0.25e18, "an appeal also buys the wall share");
        answer(id, 0);
        uint256 wall = hook.retainedImd();
        vm.prank(alice);
        (ok,) = address(letterbox).call("APPEAL The phone is how I work; I keep the rest.");
        assertTrue(ok);
        assertEq(hook.retainedImd() - wall, 0.35e18);
        assertEq(imd.balanceOf(address(letterbox)), 0.25e18);
    }

    function test_mintingTheFeeIsRefusedOnMainnet() public {
        vm.chainId(1);
        LetterboxSettings mint = new LetterboxSettings(plea, gate, seasons, imd, oimd, true);
        vm.expectRevert(Letterbox.MintOnMainnet.selector);
        mint.deploy();
        LetterboxSettings other = new LetterboxSettings(plea, gate, seasons, imd, oimd, false);
        vm.expectRevert(Letterbox.OracleAssetNotImd.selector);
        other.deploy();
    }

    /// Round 2 (R2-A2-1 / R2-A2-2): a manifest that mints the pool IMD, or names an oracle asset other
    /// than the gate's, would deploy a Letterbox that can never send a letter; both are refused.
    function test_aMismatchedOracleAssetOrMintingThePoolImdIsRefused() public {
        LetterboxSettings mintPool = new LetterboxSettings(plea, gate, seasons, imd, imd, true);
        vm.expectRevert(Letterbox.MintWithPoolImd.selector);
        mintPool.deploy();
        // The gate of this fixture pulls its fee in the pool IMD; a Letterbox minting another token.
        LetterboxSettings mismatch = new LetterboxSettings(plea, gate, seasons, imd, oimd, true);
        vm.expectRevert(Letterbox.OracleAssetMismatch.selector);
        mismatch.deploy();
    }
}

/// @dev Stands in for PleaLaunch: holds the settings a Letterbox reads from its deployer.
contract LetterboxSettings {
    address public plea;
    address public gate;
    address public seasons;
    address public imd;
    address public oracleAsset;
    bool public mintOracleFee;

    constructor(PLEA p, CabalGate g, Seasons s, MockIMD i, MockIMD o, bool m) {
        (plea, gate, seasons, imd, oracleAsset, mintOracleFee) =
        (address(p), address(g), address(s), address(i), address(o), m);
    }

    function deploy() external returns (address) {
        return address(Letterbox(payable(ArtifactDeployment.deploy("Letterbox.sol:Letterbox", bytes("")))));
    }
}
