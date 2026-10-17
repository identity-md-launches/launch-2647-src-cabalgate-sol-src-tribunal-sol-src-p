// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SepoliaFixture} from "../utils/SepoliaFixture.sol";
import {Tribunal} from "src/Tribunal.sol";
import {CabalGate} from "src/CabalGate.sol";

contract TribunalTextPropertiesTest is SepoliaFixture {
    function withTribunal() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        buy(alice, 50e18);
        skip(1 days);
        vm.prank(bob);
        imd.approve(address(tribunal), type(uint256).max);
    }

    /// @dev An independent JSON parser is the oracle for escaping. Both untrusted texts reach
    /// their maximum byte size, including quotes, backslashes and multibyte Unicode characters.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_utf8AndEscapesSurviveTheOracleBody(bytes32 entropy, uint16 sizeSeed) public {
        string memory original = _text(keccak256(abi.encode(entropy, "plea")), 280);
        uint256 pid = plead(alice, plea.balanceOf(alice) / 10, original);
        assertTrue(answer(pid, 40));
        string memory text = _text(entropy, bound(sizeSeed, 1, 280));
        vm.prank(bob);
        uint256 oid = tribunal.object(pid, text);
        assertEq(tribunal.objection(oid).text, text);
        string memory json = tribunal.body(oid);
        string memory question = vm.parseJsonString(json, ".question");
        assertEq(question, tribunal.question(oid));
        assertTrue(_contains(question, gate.question(pid)), "original question verbatim");
        assertTrue(_contains(question, string.concat("[OBJECTION]", text, "[/OBJECTION]")), "untrusted text preserved");
        assertLe(bytes(question).length, 2_000, "oracle question cap, including both maximum-length texts");
        assertLe(bytes(json).length, 16_384, "oracle body cap");
        assertEq(intake.bodyOf(tribunal.objection(oid).intakeId), bytes(json), "the Intake got exactly this JSON");
        assertEq(vm.parseJsonString(json, ".guards.min"), "0");
        assertEq(vm.parseJsonString(json, ".guards.max"), "45");
        assertEq(vm.parseJsonString(json, ".answerType"), "uint256");
        assertEq(vm.parseJsonUint(json, ".panelSize"), 30);
        assertEq(vm.parseJsonUint(json, ".quorum"), 17);
        assertEq(vm.parseJsonUint(json, ".toleranceBps"), 1500);
        string[5] memory keys = ["plea", "stories", "content", "manipulation", "answer"];
        string memory gateBody = gate.body(pid);
        for (uint256 i; i < keys.length; ++i) {
            string memory path = string.concat(".definitions.", keys[i]);
            string memory definition = vm.parseJsonString(json, path);
            assertEq(definition, vm.parseJsonString(gateBody, path));
            assertLe(bytes(definition).length, 512);
        }
        assertLe(bytes(vm.parseJsonString(json, ".definitions.objection")).length, 512);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_markerPrefixesAreRejectedBeforeAnyPayment(uint16 mask, uint16 offset, bool closing) public {
        uint256 pid = approvedPlea(alice, 40);
        bytes memory marker = bytes("objection");
        for (uint256 i; i < marker.length; ++i) {
            if (mask & (1 << i) != 0) marker[i] = bytes1(uint8(marker[i]) - 32);
        }
        bytes memory prefix = new bytes(bound(offset, 0, 269));
        for (uint256 i; i < prefix.length; ++i) {
            prefix[i] = "a";
        }
        // No closing bracket is required: even a marker prefix at the very end is rejected.
        string memory text = string.concat(string(prefix), closing ? "[/" : "[", string(marker));
        uint256 cash = imd.balanceOf(bob);
        uint256 feeSupply = oimd.totalSupply();
        vm.expectRevert(Tribunal.BadObjectionText.selector);
        vm.prank(bob);
        tribunal.object(pid, text);
        assertEq(imd.balanceOf(bob), cash);
        assertEq(oimd.totalSupply(), feeSupply);
        assertEq(tribunal.nextId(), 1);
        assertEq(tribunal.caseOf(pid).pending[0], 0);
    }

    function test_malformedUtf8ControlsAndInvisibleCharactersAreRejected() public {
        uint256 pid = approvedPlea(alice, 40);
        bytes[57] memory bad = [
            bytes(hex"00"),
            hex"09",
            hex"0a",
            hex"7f",
            hex"80",
            hex"c0af",
            hex"c2",
            hex"c285",
            hex"c2ad",
            hex"d89c",
            hex"e08080",
            hex"eda080",
            hex"e1a08e",
            hex"e2808b",
            hex"e280a8",
            hex"e280ae",
            hex"e281a0",
            hex"e281a4",
            hex"e281a6",
            hex"efbbbf",
            hex"efb880",
            hex"f0808080",
            hex"f4908080",
            hex"f5808080",
            hex"f3a08081",
            hex"f3a08480",
            hex"f09f99",
            hex"d880",
            hex"d885",
            hex"db9d",
            hex"dc8f",
            hex"e0a290",
            hex"e0a291",
            hex"e0a3a2",
            hex"e281aa",
            hex"e281af",
            hex"efbfb9",
            hex"efbfbb",
            hex"f09182bd",
            hex"f091838d",
            hex"f09390b0",
            hex"f09390bf",
            hex"f09bb2a3",
            hex"f09d85ba", // the format characters round 7 added (R7-A1-2)
            hex"cd8f",
            hex"e1859f",
            hex"e185a0",
            hex"e19eb4",
            hex"e19eb5",
            hex"e1a08b",
            hex"e1a08d",
            hex"e1a08f",
            hex"e281a5",
            hex"e385a4",
            hex"efbea0",
            hex"efbfb0",
            hex"efbfb8" // the default-ignorables round 8 added (R8-A1-1)
        ];
        for (uint256 i; i < bad.length; ++i) {
            string memory text = string(bytes.concat(bytes("ordinary prefix "), bad[i]));
            vm.expectRevert(Tribunal.BadObjectionText.selector);
            vm.prank(bob);
            tribunal.object(pid, text);
        }
        assertEq(tribunal.nextId(), 1);
        assertEq(imd.balanceOf(address(tribunal)), 0);
    }

    /// The Tribunal refuses exactly the objection texts the gate refuses as pleas: the two copies of
    /// the text rules agree (round 7 changed both, R7-A1-2).
    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_theTribunalRefusesExactlyWhatTheGateRefuses(uint256 seed) public {
        bytes memory t = _mixedText(seed);
        uint256 pid = approvedPlea(alice, 40);
        buy(carol, 50e18);
        uint256 amount = plea.balanceOf(carol) / 10;
        vm.prank(carol);
        (bool okGate, bytes memory retGate) =
            address(gate).call(abi.encodeCall(CabalGate.submitSell, (amount, string(t))));
        vm.prank(bob);
        (bool okTribunal, bytes memory retTribunal) =
            address(tribunal).call(abi.encodeCall(Tribunal.object, (pid, string(t))));
        assertEq(okTribunal, okGate, "the two text checks disagree");
        if (!okGate) {
            assertEq(bytes4(retGate), CabalGate.BadPleaText.selector);
            assertEq(bytes4(retTribunal), Tribunal.BadObjectionText.selector);
        }
    }

    /// @dev Plain letters joined with the characters at the edges of the refused ranges.
    function _mixedText(uint256 seed) internal pure returns (bytes memory t) {
        bytes[32] memory pal = [
            bytes("a"),
            bytes(" "),
            bytes("["),
            bytes("/"),
            bytes("PLEA"),
            bytes("objection"),
            hex"c3a9",
            hex"f09f9880",
            hex"c2ad",
            hex"d880",
            hex"d886",
            hex"db9d",
            hex"dc8f",
            hex"e0a291",
            hex"e0a3a2",
            hex"e281a5",
            hex"e281aa",
            hex"e281b0",
            hex"efbfbb",
            hex"efbfbc",
            hex"f09390bf",
            hex"f09d85bb",
            hex"eda080",
            hex"f3a08081",
            hex"e282",
            hex"f09bb2a3",
            hex"e1a08b",
            hex"e1a08a",
            hex"cd8f",
            hex"cd8e",
            hex"e385a4",
            hex"efbfb0"
        ];
        uint256 n = 1 + seed % 40;
        for (uint256 i; i < n; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            t = bytes.concat(t, seed % 2 == 0 ? pal[seed % pal.length] : pal[seed % 2]);
        }
    }

    function test_oneByteAnd280BytesAcceptButZeroAnd281Reject() public {
        uint256 pid = approvedPlea(alice, 40);
        vm.expectRevert(Tribunal.BadObjectionText.selector);
        vm.prank(bob);
        tribunal.object(pid, "");
        vm.prank(bob);
        uint256 first = tribunal.object(pid, "?");
        assertTrue(intake.fail(tribunal.objection(first).intakeId, 1, bytes32("body_refused"), 0, 0));
        tribunal.settle(first);
        string memory longest = _text(keccak256("byte boundary"), 280);
        assertEq(bytes(longest).length, 280);
        vm.prank(bob);
        uint256 second = tribunal.object(pid, longest);
        assertEq(bytes(tribunal.objection(second).text).length, 280);
        vm.expectRevert(Tribunal.BadObjectionText.selector);
        vm.prank(carol);
        tribunal.object(pid, string.concat(longest, "a"));
    }

    function _text(bytes32 entropy, uint256 length) internal pure returns (string memory) {
        bytes[12] memory alphabet = [
            bytes("a"),
            bytes(" "),
            bytes("\""),
            bytes("\\"),
            bytes("9"),
            bytes("?"),
            bytes("'"),
            bytes(unicode"é"),
            bytes(unicode"家"),
            bytes(unicode"🙂"),
            bytes(unicode"م"),
            bytes(unicode"Ж")
        ];
        bytes memory out;
        uint256 i;
        while (out.length < length) {
            bytes memory next = alphabet[uint256(keccak256(abi.encode(entropy, i++))) % alphabet.length];
            if (out.length + next.length > length) next = bytes("x");
            out = bytes.concat(out, next);
        }
        return string(out);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool same = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    same = false;
                    break;
                }
            }
            if (same) return true;
        }
        return false;
    }
}
