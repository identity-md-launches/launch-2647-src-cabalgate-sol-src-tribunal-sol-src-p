// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ArtifactDeployment} from "../utils/ArtifactDeployment.sol";

import {Test} from "forge-std/Test.sol";
import {PLEA} from "../../src/PLEA.sol";
import {Seasons} from "../../src/Seasons.sol";
import {PleaDistributor} from "../../src/PleaDistributor.sol";
import {MockIMD, MockSeat} from "../utils/Mocks.sol";

/// @dev Approved results only, as in SeasonRanking: the multiplier is a Seasons matter.
contract SeatResults {
    uint256 public constant SEASON = 18000;
    uint64 public constant startedAt = 1_800_000_000;

    struct Result {
        address seller;
        uint8 score;
        bool approved;
        uint64 verdictAt;
    }

    mapping(uint256 => Result) public result;

    function approve(uint256 id, address seller, uint8 score) external {
        result[id] = Result(seller, score, true, startedAt);
    }

    function restricted() external pure returns (bool) {
        return true;
    }

    function diedAt() external pure returns (uint64) {
        return 0;
    }
}

/// Run 7: points = score x 1.2 (rounded down) at `record` when the seller holds at least one IMD seat
/// NFT. Binary, points only; the 60-point bar is unchanged; the read never blocks a record.
contract SeatMultiplierTest is Test {
    SeatResults gate;
    Seasons seasons;
    MockIMD imd;
    MockSeat seat;
    address alice = makeAddr("seat alice");
    address bob = makeAddr("seat bob");

    function setUp() public {
        gate = new SeatResults();
        vm.warp(gate.startedAt());
        PLEA plea = PLEA(ArtifactDeployment.deploy("PLEA.sol:PLEA", abi.encode(address(this))));
        imd = MockIMD(ArtifactDeployment.deploy("Mocks.sol:MockIMD", bytes("")));
        seat = MockSeat(ArtifactDeployment.deploy("Mocks.sol:MockSeat", bytes("")));
        seasons = Seasons(
            ArtifactDeployment.deploy(
                "Seasons.sol:Seasons", abi.encode(address(plea), address(gate), address(imd), address(seat))
            )
        );
        PleaDistributor distributor = PleaDistributor(
            ArtifactDeployment.deploy("PleaDistributor.sol:PleaDistributor", abi.encode(address(plea), address(this)))
        );
        plea.setLauncher(address(gate), address(seasons), address(distributor));
    }

    function test_aSeatHolderEarnsOneFifthMoreRoundedDown() public {
        seat.mint(alice);
        assertTrue(seasons.holdsSeat(alice));
        assertFalse(seasons.holdsSeat(bob));
        assertEq(seasons.SEAT_MULTIPLIER_BPS(), 12_000);
        assertEq(seasons.pointsFor(alice, 45), 54);
        assertEq(seasons.pointsFor(alice, 41), 49, "49.2 rounds down");
        assertEq(seasons.pointsFor(alice, 0), 0);
        assertEq(seasons.pointsFor(bob, 45), 45);
        gate.approve(1, alice, 45);
        gate.approve(2, bob, 45);
        vm.expectEmit(true, true, false, true, address(seasons));
        emit Seasons.SeatMultiplier(1, alice, 45, 54);
        vm.expectEmit(true, true, true, true, address(seasons));
        emit Seasons.Recorded(1, 0, alice, 45, 54);
        seasons.record(1);
        seasons.record(2);
        Seasons.Entry[25] memory top = seasons.topOf(0);
        assertEq(top[0].wallet, alice);
        assertEq(top[0].points, 54);
        assertEq(top[1].wallet, bob);
        assertEq(top[1].points, 45);
        assertEq(seasons.bestOf(0, alice)[0], 54, "bestOf holds the plea's points, after the multiplier");
    }

    function test_twoSeatsAreNoBetterThanOne() public {
        seat.mint(alice);
        seat.mint(alice);
        assertEq(seasons.pointsFor(alice, 40), 48);
    }

    function test_theSixtyPointBarIsUnchangedSoTwoMiddlingPleasQualifyWithASeat() public {
        seat.mint(alice);
        gate.approve(1, alice, 25);
        gate.approve(2, alice, 25);
        gate.approve(3, bob, 25);
        gate.approve(4, bob, 25);
        seasons.record(1);
        seasons.record(2);
        seasons.record(3);
        seasons.record(4);
        assertEq(seasons.topOf(0)[0].points, 60, "alice: 2 x 30");
        assertEq(seasons.topOf(0)[1].points, 50, "bob: 2 x 25");
        imd.mint(address(seasons), 1000e18);
        seasons.checkpoint();
        vm.warp(uint256(gate.startedAt()) + gate.SEASON() + 1 hours);
        seasons.closeSeason(new uint256[](0));
        assertEq(imd.balanceOf(alice), 45e18, "alice reached 60 and takes first place");
        assertEq(imd.balanceOf(bob), 0, "bob stays under 60");
    }

    function test_theSeatIsReadWhenThePleaIsRecordedNotWhenItWasJudged() public {
        gate.approve(1, alice, 40);
        seat.mint(alice);
        seasons.record(1);
        assertEq(seasons.topOf(0)[0].points, 48);
        seat.burn(alice);
        gate.approve(2, alice, 40);
        seasons.record(2);
        assertEq(seasons.topOf(0)[0].points, 88, "the second plea is recorded without a seat");
    }

    function test_aBrokenGreedyOrMissingSeatContractNeverBlocksARecord() public {
        seat.mint(alice);
        gate.approve(1, alice, 40);
        seat.setBroken(true);
        assertFalse(seasons.holdsSeat(alice));
        seasons.record(1);
        assertEq(seasons.topOf(0)[0].points, 40, "a reverting read means no multiplier");
        seat.setBroken(false);
        seat.setGreedy(true);
        gate.approve(2, alice, 40);
        uint256 g = gasleft();
        seasons.record(2);
        assertLt(g - gasleft(), 400_000, "the read is capped at SEAT_READ_GAS");
        assertEq(seasons.topOf(0)[0].points, 80, "a read that runs out of gas means no multiplier");
        // No seat contract at all.
        PLEA plea = PLEA(ArtifactDeployment.deploy("PLEA.sol:PLEA", abi.encode(address(this))));
        Seasons none = Seasons(
            ArtifactDeployment.deploy(
                "Seasons.sol:Seasons", abi.encode(address(plea), address(gate), address(imd), address(0))
            )
        );
        assertFalse(none.holdsSeat(alice));
        assertEq(none.pointsFor(alice, 45), 45);
        // An address with no code answers nothing: no multiplier either.
        Seasons eoa = Seasons(
            ArtifactDeployment.deploy(
                "Seasons.sol:Seasons", abi.encode(address(plea), address(gate), address(imd), makeAddr("no code"))
            )
        );
        assertFalse(eoa.holdsSeat(alice));
    }

    function testFuzz_pointsNeverExceedScoreTimesOnePointTwo(uint8 score, bool holder) public {
        score = uint8(bound(score, 0, 45));
        if (holder) seat.mint(alice);
        uint256 pts = seasons.pointsFor(alice, score);
        assertEq(pts, holder ? uint256(score) * 12 / 10 : score);
        assertLe(pts, 54);
    }
}
