// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SepoliaFixture} from "./utils/SepoliaFixture.sol";
import {Tribunal} from "src/Tribunal.sol";

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
        bytes[27] memory bad = [
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
            hex"f09f99"
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
