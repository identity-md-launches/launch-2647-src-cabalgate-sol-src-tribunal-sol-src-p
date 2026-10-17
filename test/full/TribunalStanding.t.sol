// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ArtifactDeployment} from "../utils/ArtifactDeployment.sol";

import {Test} from "forge-std/Test.sol";
import {Seasons} from "../../src/Seasons.sol";

/// @dev The least gate Seasons needs: a start, a season length, one approved plea.
contract StandingGate {
    uint64 public startedAt = 1_000_000;
    uint256 public constant SEASON = 5 hours;
    address public seller;

    constructor(address seller_) {
        seller = seller_;
    }

    function diedAt() external pure returns (uint64) {
        return 0;
    }

    function cabalAlive() external pure returns (bool) {
        return true;
    }

    function result(uint256 id) external view returns (address, uint8, bool, uint64) {
        if (id == 0) return (address(0), 0, false, 0);
        return (seller, 40, true, startedAt + 10);
    }
}

/// @dev The least PLEA Seasons needs: owner, hook, pool manager and a launcher that can be swapped.
contract StandingPlea {
    address public owner = address(0xA11);
    address public hook = address(0);
    address public poolManager = address(0);
    address public launcher;

    function setLauncher(address l) external {
        launcher = l;
    }

    /// @dev Seasons holds no bonus here: a close burns nothing and pays nobody.
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

/// @dev An empty prize token: a close finds no pot.
contract EmptyToken {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

contract LauncherWithoutTribunal {
    function somethingElse() external pure returns (uint256) {
        return 1;
    }
}

contract LauncherShortReturn {
    fallback() external {
        assembly {
            return(0, 31)
        }
    }
}

contract LauncherWith {
    address public tribunal;

    constructor(address t) {
        tribunal = t;
    }
}

contract RevertingTribunal {
    fallback() external {
        revert("no");
    }
}

contract ShortTribunal {
    fallback() external {
        assembly {
            return(0, 64)
        }
    }
}

contract FixedTribunal {
    bool public held;
    bool public sustained;
    uint8 public lowest;

    constructor(bool h, bool s, uint8 l) {
        held = h;
        sustained = s;
        lowest = l;
    }

    function standing(uint256) external view returns (bool, bool, uint8) {
        return (held, sustained, lowest);
    }
}

/// @notice `Seasons._standing` reads the Tribunal through PLEA's launcher and never trusts it: every
/// broken path records as before (fail open), and only a well-formed answer holds, blocks or lowers.
contract TribunalStandingTest is Test {
    address seller = address(0x5E11);
    StandingGate gate;
    StandingPlea plea;
    Seasons seasons;

    function setUp() public {
        gate = new StandingGate(seller);
        plea = new StandingPlea();
        seasons = Seasons(
            ArtifactDeployment.deploy(
                "Seasons.sol:Seasons", abi.encode(address(plea), address(gate), address(new EmptyToken()), address(0))
            )
        );
        vm.warp(uint256(gate.startedAt()) + 1 hours);
    }

    function _recordsAt(uint8 expected) internal {
        seasons.record(1);
        assertTrue(seasons.recorded(1));
        assertEq(seasons.bestOf(0, seller)[0], expected);
    }

    function test_noLauncherRecordsAsBefore() public {
        _recordsAt(40);
    }

    function test_aLauncherWithoutTribunalRecordsAsBefore() public {
        plea.setLauncher(address(new LauncherWithoutTribunal()));
        _recordsAt(40);
    }

    function test_aLauncherAnsweringTheWrongSizeRecordsAsBefore() public {
        plea.setLauncher(address(new LauncherShortReturn()));
        _recordsAt(40);
    }

    function test_aZeroTribunalRecordsAsBefore() public {
        plea.setLauncher(address(new LauncherWith(address(0))));
        _recordsAt(40);
    }

    function test_aRevertingTribunalCannotBlockARecord() public {
        plea.setLauncher(address(new LauncherWith(address(new RevertingTribunal()))));
        _recordsAt(40);
    }

    function test_aTribunalAnsweringTheWrongSizeRecordsAsBefore() public {
        plea.setLauncher(address(new LauncherWith(address(new ShortTribunal()))));
        _recordsAt(40);
    }

    function test_aHeldPleaIsRefusedAndSkippedByAClose() public {
        plea.setLauncher(address(new LauncherWith(address(new FixedTribunal(true, false, 255)))));
        vm.expectRevert(abi.encodeWithSelector(Seasons.Held.selector, 1));
        seasons.record(1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.warp(uint256(gate.startedAt()) + gate.SEASON() + 1 hours);
        // closeSeason skips the held plea, closes, and the plea stays unrecorded
        seasons.closeSeason(ids);
        assertTrue(seasons.closed(0));
        assertFalse(seasons.recorded(1));
    }

    function test_aSustainedPleaIsRefused() public {
        plea.setLauncher(address(new LauncherWith(address(new FixedTribunal(false, true, 10)))));
        vm.expectRevert(abi.encodeWithSelector(Seasons.ObjectionSustained.selector, 1));
        seasons.record(1);
    }

    function test_aLowerPanelScoreIsRecorded() public {
        plea.setLauncher(address(new LauncherWith(address(new FixedTribunal(false, false, 33)))));
        _recordsAt(33);
    }

    function test_aHigherPanelScoreKeepsTheOriginal() public {
        plea.setLauncher(address(new LauncherWith(address(new FixedTribunal(false, false, 45)))));
        _recordsAt(40);
    }

    // ---------------------------------------------------------------- the prize table

    function test_sharesFallInAStraightLineAndSumToTenThousand() public view {
        uint256 sum;
        uint256 prev = type(uint256).max;
        for (uint256 i; i < seasons.TOP(); ++i) {
            uint256 s = seasons.shareBps(i);
            assertLt(s, prev, "strictly falling");
            // within half a basis point of the straight line 450 -> 350 over 25 ranks (24 steps)
            int256 off = int256(s) * 24 - (int256(450 * 24) - int256(100 * i));
            assertLe(off < 0 ? -off : off, 12, "on the line");
            prev = s;
            sum += s;
        }
        assertEq(sum, 10_000);
        assertEq(seasons.shareBps(0), 450);
        assertEq(seasons.shareBps(24), 350);
        assertEq(seasons.TOP(), 25);
        assertEq(seasons.BONUS_SEASONS() * seasons.BONUS_PER_SEASON(), 60_000_000e18, "6% of the supply");
    }

    function test_noShareBeyondTheTable() public {
        vm.expectRevert();
        seasons.shareBps(25);
    }
}
