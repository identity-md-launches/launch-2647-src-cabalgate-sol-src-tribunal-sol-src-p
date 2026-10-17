// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "../utils/Fixture.sol";
import {HookTest} from "./Hook.t.sol";
import {GateTest} from "./Gate.t.sol";
import {SeasonsTest} from "./Seasons.t.sol";
import {LetterboxTest} from "./Letterbox.t.sol";
import {AuditRound1Test} from "./AuditRound1.t.sol";
import {MockIMD} from "../utils/Mocks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/*
  The launch factory may give PLEA an address below TestIMD, which makes PLEA currency0
  (`hook.pleaIsZero() == true`) and selects the other branch in seed(), _pleaIn/_imdIn, _applyCap,
  _rebalance and CabalGate.unlockCallback. These suites rerun the hook, gate and seasons tests with
  IMD etched at the highest address, so PLEA is currency0.

  The default fixture already lands PLEA below IMD (round-3 audit R3-A3-2: the deterministic suites
  therefore never ran the IMD-is-currency0 branches), so the ImdIsZero suites below etch IMD at a
  low address and rerun the hook, gate, seasons, Letterbox, hook-revision and audit suites with
  `hook.pleaIsZero() == false`, the orientation Sepolia's run 4 and mainnet may get.
*/
abstract contract PleaIsZeroFixture is Fixture {
    address constant HIGH_IMD = address(type(uint160).max);

    function deployImd() internal virtual override {
        deployCodeTo("Mocks.sol:MockIMD", "", HIGH_IMD);
        imd = MockIMD(HIGH_IMD);
    }

    function test_orientationIsPleaZero() public view {
        assertTrue(hook.pleaIsZero(), "PLEA must be currency0 in this suite");
        PoolKey memory key = hook.poolKey();
        assertEq(Currency.unwrap(key.currency0), address(plea));
        assertEq(Currency.unwrap(key.currency1), address(imd));
    }
}

abstract contract ImdIsZeroFixture is Fixture {
    address constant LOW_IMD = address(uint160(1 << 32));

    function deployImd() internal virtual override {
        deployCodeTo("Mocks.sol:MockIMD", "", LOW_IMD);
        imd = MockIMD(LOW_IMD);
    }

    function test_orientationIsImdZero() public view {
        assertFalse(hook.pleaIsZero(), "IMD must be currency0 in this suite");
        PoolKey memory key = hook.poolKey();
        assertEq(Currency.unwrap(key.currency0), address(imd));
    }
}

contract HookPleaIsZeroTest is PleaIsZeroFixture, HookTest {
    function deployImd() internal override(Fixture, PleaIsZeroFixture) {
        PleaIsZeroFixture.deployImd();
    }
}

contract GatePleaIsZeroTest is PleaIsZeroFixture, GateTest {
    function deployImd() internal override(Fixture, PleaIsZeroFixture) {
        PleaIsZeroFixture.deployImd();
    }

    function setUp() public override(Fixture, GateTest) {
        GateTest.setUp();
    }
}

contract SeasonsPleaIsZeroTest is PleaIsZeroFixture, SeasonsTest {
    function deployImd() internal override(Fixture, PleaIsZeroFixture) {
        PleaIsZeroFixture.deployImd();
    }

    function setUp() public override(Fixture, SeasonsTest) {
        SeasonsTest.setUp();
    }
}

contract HookImdIsZeroTest is ImdIsZeroFixture, HookTest {
    function deployImd() internal override(Fixture, ImdIsZeroFixture) {
        ImdIsZeroFixture.deployImd();
    }
}

contract GateImdIsZeroTest is ImdIsZeroFixture, GateTest {
    function deployImd() internal override(Fixture, ImdIsZeroFixture) {
        ImdIsZeroFixture.deployImd();
    }

    function setUp() public override(Fixture, GateTest) {
        GateTest.setUp();
    }
}

contract SeasonsImdIsZeroTest is ImdIsZeroFixture, SeasonsTest {
    function deployImd() internal override(Fixture, ImdIsZeroFixture) {
        ImdIsZeroFixture.deployImd();
    }

    function setUp() public override(Fixture, SeasonsTest) {
        SeasonsTest.setUp();
    }
}

contract LetterboxImdIsZeroTest is ImdIsZeroFixture, LetterboxTest {
    function deployImd() internal override(Fixture, ImdIsZeroFixture) {
        ImdIsZeroFixture.deployImd();
    }

    function setUp() public override(Fixture, LetterboxTest) {
        LetterboxTest.setUp();
    }
}

contract AuditRound1ImdIsZeroTest is ImdIsZeroFixture, AuditRound1Test {
    function deployImd() internal override(Fixture, ImdIsZeroFixture) {
        ImdIsZeroFixture.deployImd();
    }

    function withTribunal() internal pure override(Fixture, AuditRound1Test) returns (bool) {
        return AuditRound1Test.withTribunal();
    }
}
