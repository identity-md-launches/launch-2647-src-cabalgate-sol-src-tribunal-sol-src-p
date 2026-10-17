// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "../utils/Fixture.sol";
import {CabalGate} from "../../src/CabalGate.sol";

/// The mainnet gas pass changed how the gate escapes the judges' question, how it reads the bytes of
/// a plea text, and how the hook finds its latest and 24-hour-old prices. Each is held here to the
/// behaviour of the code it replaced (copied below as the reference).
contract GasPassTest is Fixture {
    function setUp() public override {
        super.setUp();
        buy(alice, 50e18);
        buy(bob, 50e18);
        skip(1 days);
    }

    // ---------------------------------------------------------------- the judges' question

    /// The body used to escape the whole question; now only the plea texts are escaped. Same bytes.
    function test_bodyEqualsEscapingTheWholeQuestion() public {
        uint256 amount = small(alice);
        uint256 id =
            plead(alice, amount, 'He said "sell" and I said \\ maybe; "quoted" twice, a backslash at the end\\');
        _checkBody(id);
        require(answer(id, 0), "not delivered");
        vm.prank(alice);
        uint256 a = gate.appeal(id, amount, 'Again: "please", \\ and "please" once more.');
        _checkBody(a);
        uint256 b = plead(bob, small(bob), "No quotes here at all, just a plain plea to sell a little.");
        _checkBody(b);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_bodyEqualsEscapingTheWholeQuestion(uint256 seed) public {
        uint256 amount = small(alice);
        uint256 id = plead(alice, amount, _printable(seed));
        _checkBody(id);
    }

    function _checkBody(uint256 id) internal view {
        bytes memory body = bytes(gate.body(id));
        bytes memory q = bytes(_refEscape(gate.question(id)));
        bytes memory head = bytes('{"v":1,"question":"');
        bytes memory tail = bytes('","chainId":1,"window":{"hours":1}');
        assertEq(_slice(body, 0, head.length), head);
        assertEq(_slice(body, head.length, q.length), q, "the question, escaped as before");
        assertEq(_slice(body, head.length + q.length, tail.length), tail);
    }

    /// @dev Printable ASCII, rich in quotes and backslashes, without `[` (no marker by chance).
    function _printable(uint256 seed) internal pure returns (string memory) {
        uint256 n = 1 + seed % 280;
        bytes memory t = new bytes(n);
        for (uint256 i; i < n; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint8 c = uint8(0x20 + seed % 95);
            if (seed % 5 == 0) c = 0x22;
            else if (seed % 7 == 0) c = 0x5c;
            if (c == 0x5b) c = 0x5d;
            t[i] = bytes1(c);
        }
        return string(t);
    }

    /// @dev The gate's escape before the gas pass.
    function _refEscape(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 extra;
        for (uint256 i; i < b.length; ++i) {
            if (b[i] == '"' || b[i] == "\\") ++extra;
        }
        if (extra == 0) return s;
        bytes memory out = new bytes(b.length + extra);
        uint256 j;
        for (uint256 i; i < b.length; ++i) {
            if (b[i] == '"' || b[i] == "\\") out[j++] = "\\";
            out[j++] = b[i];
        }
        return string(out);
    }

    function _slice(bytes memory b, uint256 from, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            out[i] = b[from + i];
        }
    }

    // ---------------------------------------------------------------- the plea text rules

    /// The text check reads bytes without bounds checks now; it must match the reference rules.
    /// Run 5's delimiter finding adds [OBJECTION prefixes to both checks below; round 7 (R7-A1-2)
    /// adds the rest of Unicode's format characters to both, the gate now decoding code points; round 8
    /// (R8-A1-1) adds every variation selector and every other default-ignorable character.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_textCheckMatchesTheReferenceRules(uint256 seed) public {
        bytes memory t = _mixed(seed);
        bool valid = _refValid(t);
        uint256 amount = small(alice);
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(gate).call(abi.encodeCall(CabalGate.submitSell, (amount, string(t))));
        if (valid) {
            assertTrue(ok, "a valid text was refused");
        } else {
            assertFalse(ok, "an invalid text was accepted");
            assertEq(bytes4(ret), CabalGate.BadPleaText.selector);
        }
    }

    function test_textCheckEdgeCases() public {
        bytes[18] memory valid = [
            bytes("a"),
            bytes("[pleb] is fine, [/ple too, and [ alone"),
            hex"c3a9e282acf09f9880", // é € 😀
            hex"c2a0", // no-break space
            hex"e280a7", // U+2027
            hex"efb890", // U+FE10
            hex"f3a18080", // U+E1000
            hex"ed9fbf", // U+D7FF
            hex"f48fbfbf", // U+10FFFF
            bytes('quote " and backslash \\'),
            bytes("PLEA without a bracket"),
            hex"d886", // U+0606, next to the Arabic number signs
            hex"efbfbc", // U+FFFC, next to the annotation characters
            hex"f09d85bb", // U+1D17B, next to the musical format controls
            hex"e281b0", // U+2070 superscript zero, just past the refused U+206F
            hex"cd8e", // U+034E, next to the combining grapheme joiner
            hex"e1a08a", // U+180A Mongolian nirugu, next to the free variation selectors
            hex"e385a5" // U+3165, next to the Hangul filler
        ];
        bytes[28] memory invalid = [
            bytes(""),
            bytes("[PLEA]"),
            bytes("x [/pLeA"),
            bytes("[OBJECTION]"),
            bytes("x [/oBjEcTiOn"),
            hex"0a",
            hex"7f",
            hex"c2ad", // soft hyphen
            hex"e2808b", // zero-width space
            hex"e281a6", // bidi isolate
            hex"efbbbf", // BOM
            hex"f3a08081", // tag
            hex"eda080", // surrogate
            hex"e08080", // overlong
            hex"f4908080", // above U+10FFFF
            hex"41c3", // cut off
            hex"d880", // U+0600 Arabic number sign
            hex"dc8f", // U+070F Syriac abbreviation mark
            hex"e0a3a2", // U+08E2 Arabic disputed end of ayah
            hex"e281aa", // U+206A deprecated format control
            hex"efbfb9", // U+FFF9 interlinear annotation anchor
            hex"f09390b0", // U+13430 Egyptian hieroglyph vertical joiner
            hex"f09d85b3", // U+1D173 musical symbol begin beam
            hex"e281a5", // U+2065 (reserved, default ignorable)
            hex"e1a08b", // U+180B Mongolian free variation selector one
            hex"cd8f", // U+034F combining grapheme joiner
            hex"e385a4", // U+3164 Hangul filler
            hex"efbfb0" // U+FFF0 (reserved, default ignorable)
        ];
        for (uint256 i; i < valid.length; ++i) {
            assertTrue(_refValid(valid[i]), "reference: valid");
            _expectText(valid[i], true);
        }
        for (uint256 i; i < invalid.length; ++i) {
            assertFalse(_refValid(invalid[i]), "reference: invalid");
            _expectText(invalid[i], false);
        }
        bytes memory long = new bytes(281);
        for (uint256 i; i < 281; ++i) {
            long[i] = "a";
        }
        _expectText(long, false);
    }

    function _expectText(bytes memory t, bool valid) internal {
        uint256 snap = vm.snapshotState();
        uint256 amount = small(alice);
        vm.prank(alice);
        (bool ok,) = address(gate).call(abi.encodeCall(CabalGate.submitSell, (amount, string(t))));
        assertEq(ok, valid, string(t));
        vm.revertToState(snap);
    }

    /// @dev Fragments of valid, forbidden and broken text, joined at random.
    function _mixed(uint256 seed) internal pure returns (bytes memory t) {
        bytes[62] memory pal = [
            bytes("a"),
            bytes("Z"),
            bytes(" "),
            bytes("9"),
            bytes('"'),
            bytes("\\"),
            bytes("["),
            bytes("/"),
            bytes("[/"),
            bytes("PLEA"),
            bytes("pLeA"),
            bytes("OBJECTION"),
            bytes("oBjEcTiOn"),
            bytes("ple"),
            bytes("]"),
            hex"c3a9",
            hex"e282ac",
            hex"f09f9880",
            hex"c2a0",
            hex"e281a5",
            hex"00",
            hex"0a",
            hex"7f",
            hex"c280",
            hex"c29f",
            hex"c2ad",
            hex"d89c",
            hex"e2808b",
            hex"e280ae",
            hex"e280a8",
            hex"e281a0",
            hex"e281a9",
            hex"efbbbf",
            hex"efb880",
            hex"e1a08e",
            hex"f3a08080",
            hex"c3",
            hex"80",
            hex"c0af",
            hex"e08080",
            hex"eda080",
            hex"f4908080",
            hex"f5",
            hex"e282",
            hex"f09f98",
            hex"ff",
            hex"d880",
            hex"d886",
            hex"db9d",
            hex"e0a291",
            hex"e281af",
            hex"e281b0",
            hex"efbfbb",
            hex"efbfbc",
            hex"f09bb2a0",
            hex"f09d85bb",
            hex"e1a08b",
            hex"e1a08a",
            hex"cd8f",
            hex"e19eb5",
            hex"efbea0",
            hex"efbfb4"
        ];
        if (seed % 97 == 0) return "";
        uint256 n = 1 + seed % 24;
        for (uint256 i; i < n; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            // Mostly plain letters, so that valid texts are common.
            t = bytes.concat(t, seed % 3 == 0 ? pal[seed % pal.length] : pal[seed % 4]);
        }
        if (seed % 13 == 0) {
            bytes memory pad = new bytes(250 + seed % 40);
            for (uint256 i; i < pad.length; ++i) {
                pad[i] = "a";
            }
            t = bytes.concat(t, pad);
        }
    }

    /// @dev The text check before the gas pass, plus run 5's required marker restriction.
    function _refValid(bytes memory b) internal pure returns (bool) {
        uint256 n = b.length;
        if (n == 0 || n > 280) return false;
        uint256 i;
        while (i < n) {
            uint8 c = uint8(b[i]);
            if (c < 0x20 || c == 0x7f) return false;
            if (c == 0x5b && _refMarker(b, i, n)) return false; // '['
            if (c < 0x80) {
                ++i;
                continue;
            }
            uint256 len;
            if (c >= 0xc2 && c <= 0xdf) len = 2;
            else if (c >= 0xe0 && c <= 0xef) len = 3;
            else if (c >= 0xf0 && c <= 0xf4) len = 4;
            else return false;
            if (i + len > n) return false;
            for (uint256 k = 1; k < len; ++k) {
                if (uint8(b[i + k]) & 0xc0 != 0x80) return false;
            }
            uint8 c1 = uint8(b[i + 1]);
            if (
                (c == 0xe0 && c1 < 0xa0) || (c == 0xed && c1 > 0x9f) || (c == 0xf0 && c1 < 0x90)
                    || (c == 0xf4 && c1 > 0x8f)
            ) return false;
            if (len == 2) {
                if ((c == 0xc2 && (c1 <= 0x9f || c1 == 0xad)) || (c == 0xd8 && c1 == 0x9c)) return false;
                // round 7: U+0600-0605, U+06DD, U+070F
                if ((c == 0xd8 && c1 <= 0x85) || (c == 0xdb && c1 == 0x9d) || (c == 0xdc && c1 == 0x8f)) return false;
                // round 8: U+034F combining grapheme joiner
                if (c == 0xcd && c1 == 0x8f) return false;
            } else if (len == 3) {
                uint8 c2 = uint8(b[i + 2]);
                if (c == 0xe2 && c1 == 0x80 && ((c2 >= 0x8b && c2 <= 0x8f) || (c2 >= 0xa8 && c2 <= 0xae))) {
                    return false;
                }
                if (c == 0xe2 && c1 == 0x81 && ((c2 >= 0xa0 && c2 <= 0xa4) || (c2 >= 0xa6 && c2 <= 0xa9))) {
                    return false;
                }
                if (c == 0xef && c1 == 0xbb && c2 == 0xbf) return false;
                if (c == 0xef && c1 == 0xb8 && c2 <= 0x8f) return false;
                if (c == 0xe1 && c1 == 0xa0 && c2 == 0x8e) return false;
                // round 7: U+206A-206F, U+FFF9-FFFB, U+0890-0891, U+08E2
                if (c == 0xe2 && c1 == 0x81 && c2 >= 0xaa && c2 <= 0xaf) return false;
                if (c == 0xef && c1 == 0xbf && c2 >= 0xb9 && c2 <= 0xbb) return false;
                if (c == 0xe0 && c1 == 0xa2 && (c2 == 0x90 || c2 == 0x91)) return false;
                if (c == 0xe0 && c1 == 0xa3 && c2 == 0xa2) return false;
                // round 8: U+115F-1160, U+17B4-17B5, U+180B-180D, U+180F, U+2065, U+3164, U+FFA0, U+FFF0-FFF8
                if (c == 0xe1 && c1 == 0x85 && (c2 == 0x9f || c2 == 0xa0)) return false;
                if (c == 0xe1 && c1 == 0x9e && (c2 == 0xb4 || c2 == 0xb5)) return false;
                if (c == 0xe1 && c1 == 0xa0 && c2 >= 0x8b && c2 <= 0x8f) return false;
                if (c == 0xe2 && c1 == 0x81 && c2 == 0xa5) return false;
                if (c == 0xe3 && c1 == 0x85 && c2 == 0xa4) return false;
                if (c == 0xef && c1 == 0xbe && c2 == 0xa0) return false;
                if (c == 0xef && c1 == 0xbf && c2 >= 0xb0 && c2 <= 0xb8) return false;
            } else {
                if (c == 0xf3 && c1 == 0xa0) return false;
                // round 7: U+110BD, U+110CD, U+13430-1343F, U+1BCA0-1BCA3, U+1D173-1D17A
                uint8 c2 = uint8(b[i + 2]);
                uint8 c3 = uint8(b[i + 3]);
                if (c == 0xf0 && c1 == 0x91 && c2 == 0x82 && c3 == 0xbd) return false;
                if (c == 0xf0 && c1 == 0x91 && c2 == 0x83 && c3 == 0x8d) return false;
                if (c == 0xf0 && c1 == 0x93 && c2 == 0x90 && c3 >= 0xb0) return false;
                if (c == 0xf0 && c1 == 0x9b && c2 == 0xb2 && c3 >= 0xa0 && c3 <= 0xa3) return false;
                if (c == 0xf0 && c1 == 0x9d && c2 == 0x85 && c3 >= 0xb3 && c3 <= 0xba) return false;
            }
            i += len;
        }
        return true;
    }

    function _refMarker(bytes memory b, uint256 i, uint256 n) internal pure returns (bool) {
        uint256 j = i + 1;
        if (j < n && b[j] == "/") ++j;
        if (j + 4 > n) return false;
        if (
            _refLower(b[j]) == "p" && _refLower(b[j + 1]) == "l" && _refLower(b[j + 2]) == "e"
                && _refLower(b[j + 3]) == "a"
        ) return true;
        bytes memory word = bytes("objection");
        if (j + word.length > n) return false;
        for (uint256 k; k < word.length; ++k) {
            if (_refLower(b[j + k]) != word[k]) return false;
        }
        return true;
    }

    function _refLower(bytes1 c) internal pure returns (bytes1) {
        if (c >= "A" && c <= "Z") return bytes1(uint8(c) + 32);
        return c;
    }

    // ---------------------------------------------------------------- the hook's price views

    /// The hook now reads its newest checkpoint directly and the 24-hour-old one by its hour; both
    /// must equal a scan of the whole ring, across hours with and without trades and ring wraps.
    function test_priceViewsMatchAFullScan() public {
        for (uint256 h; h < 80; ++h) {
            bool quiet = h % 7 == 3 || h % 11 == 5 || (h >= 30 && h < 34) || (h >= 50 && h < 53);
            if (!quiet) buy(h % 2 == 0 ? alice : bob, 1e18);
            assertEq(hook.latestPrice(), _scanLatest(), "latest");
            assertEq(hook.price24hAgo(), _scan24h(), "24 hours ago");
            skip(37 minutes);
            if (!quiet) buy(bob, 0.5e18);
            assertEq(hook.latestPrice(), _scanLatest(), "latest, later in the hour");
            assertEq(hook.price24hAgo(), _scan24h(), "24 hours ago, later in the hour");
            skip(23 minutes);
        }
    }

    function _scanLatest() internal view returns (uint256 best) {
        uint64 bestHour;
        for (uint256 i; i < 48; ++i) {
            (uint64 hour, uint256 p) = hook.ring(i);
            if (p != 0 && hour >= bestHour) {
                bestHour = hour;
                best = p;
            }
        }
    }

    function _scan24h() internal view returns (uint256 best) {
        uint64 target = uint64(block.timestamp / 1 hours) - 24;
        uint64 bestHour;
        for (uint256 i; i < 48; ++i) {
            (uint64 hour, uint256 p) = hook.ring(i);
            // Within two days (round 4, R4-A1-1): a checkpoint that only survived in a quiet ring is no reference.
            if (p != 0 && hour <= target && hour + 24 >= target && hour >= bestHour) {
                bestHour = hour;
                best = p;
            }
        }
    }
}
