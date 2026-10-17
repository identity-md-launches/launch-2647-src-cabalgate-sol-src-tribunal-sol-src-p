// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PLEA} from "src/PLEA.sol";
import {Seasons} from "src/Seasons.sol";
import {PleaDistributor} from "src/PleaDistributor.sol";
import {MockIMD} from "../utils/Mocks.sol";
import {ArtifactDeployment} from "../utils/ArtifactDeployment.sol";
import {SeasonResults, SeasonWallSink, SeasonModel} from "../utils/SeasonModel.sol";

/// @dev Models ABI failures as well as a seat changing hands; no ranking logic lives in this mock.
contract Run7SeatSource {
    mapping(address => uint256) public seats;
    uint256 public mode;

    function configure(address wallet, uint256 count, uint256 mode_) external {
        seats[wallet] = count;
        mode = mode_;
    }

    function balanceOf(address wallet) external returns (uint256) {
        uint256 m = mode;
        if (m == 1) revert("seat unavailable");
        if (m == 2) {
            assembly ("memory-safe") { invalid() }
        }
        if (m == 3) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 31)
            }
        }
        if (m == 4) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 64)
            }
        }
        if (m == 5) {
            // STATICCALL must reject an NFT that tries to mutate state while answering.
            seats[wallet] = 1;
        }
        return seats[wallet];
    }
}

contract Run7SeatHandler is Test {
    PLEA public immutable token;
    Seasons public immutable seasons;
    SeasonResults public immutable results;
    MockIMD public immutable quote;
    Run7SeatSource public immutable seat;
    address[12] public actors;
    uint256[12] public seatCounts;
    uint256 public seatMode;
    SeasonModel.Approval[] internal approvals;
    mapping(uint256 => bool) public approved;
    uint8[] internal judged;
    uint256[12] public quotePaid;
    uint256[12] public bonusPaid;
    uint256 public funded;
    uint256 public totalPaid;
    uint256 public totalBonusPaid;
    uint256 public operations;
    uint256 public successfulRecords;
    uint256 public refusedRecords;
    bool public closed;

    constructor(
        PLEA token_,
        Seasons seasons_,
        SeasonResults results_,
        MockIMD quote_,
        Run7SeatSource seat_,
        address[12] memory actors_
    ) {
        token = token_;
        seasons = seasons_;
        results = results_;
        quote = quote_;
        seat = seat_;
        actors = actors_;
    }

    function setSeat(uint256 actorSeed, uint256 count, uint256 modeSeed) external {
        ++operations;
        uint256 a = actorSeed % 12;
        seatCounts[a] = count;
        seatMode = modeSeed % 6;
        seat.configure(actors[a], count, seatMode);
    }

    function issue(uint256 actorSeed, uint256 rawScore, bool passes) external {
        ++operations;
        if (approvals.length >= 96) return;
        uint256 id = approvals.length + 1;
        uint256 a = actorSeed % 12;
        // A real approved gate result has score >= 26 (71 minus at most 45 fact points).
        uint8 score = uint8(bound(rawScore, 26, 45));
        results.setResult(id, actors[a], score, passes, results.startedAt());
        approvals.push(SeasonModel.Approval(id, 0, a, 0, false));
        judged.push(score);
        approved[id] = passes;
    }

    function record(uint256 seed) external {
        ++operations;
        if (approvals.length == 0) return;
        uint256 p = seed % approvals.length;
        SeasonModel.Approval storage a = approvals[p];
        bool succeeds = approved[a.id] && !a.recorded && !closed;
        if (!approved[a.id]) vm.expectRevert(abi.encodeWithSelector(Seasons.NotApproved.selector, a.id));
        else if (a.recorded) vm.expectRevert(abi.encodeWithSelector(Seasons.AlreadyRecorded.selector, a.id));
        else if (closed) vm.expectRevert(abi.encodeWithSelector(Seasons.SeasonClosed.selector, uint256(0)));
        seasons.record(a.id);
        if (succeeds) snapshot(p);
        else ++refusedRecords;
    }

    function snapshot(uint256 p) internal {
        SeasonModel.Approval storage a = approvals[p];
        a.recorded = true;
        // The input score plus a whole point for each complete group of five is floor(score*1.2).
        a.score = judged[p] + (seatMode == 0 && seatCounts[a.actor] != 0 ? judged[p] / 5 : 0);
        ++successfulRecords;
    }

    function donate(uint256 rawAmount) external {
        ++operations;
        uint256 amount = bound(rawAmount, 0, 1_000_000e18);
        quote.mint(address(seasons), amount);
        seasons.checkpoint();
        funded += amount;
    }

    function closeWithLateRecords(uint256 seed) external {
        ++operations;
        // Let random record and seat operations mix before closing the sole modeled season.
        if (operations < 100) return;
        if (closed) {
            vm.expectRevert(abi.encodeWithSelector(Seasons.NotReady.selector, uint256(1)));
            seasons.closeSeason(new uint256[](0));
            return;
        }
        uint256[] memory ids = new uint256[](12);
        for (uint256 i; i < ids.length; ++i) {
            uint256 p = (seed % approvals.length + i) % approvals.length;
            ids[i] = approvals[p].id;
            if (approved[ids[i]] && !approvals[p].recorded) snapshot(p);
        }
        (SeasonModel.Approval[] memory all, uint256 n) = SeasonModel.sorted(approvals, 0);
        SeasonModel.Wallet[12] memory ranked = SeasonModel.wallets(all, n);
        for (uint256 rank; rank < 12; ++rank) {
            if (ranked[rank].points < 60) continue;
            uint256 a = ranked[rank].actor;
            uint256 share = seasons.shareBps(rank);
            quotePaid[a] = funded * share / 10_000;
            bonusPaid[a] = 10_000_000e18 * share / 10_000;
            totalPaid += quotePaid[a];
            totalBonusPaid += bonusPaid[a];
        }
        vm.warp(uint256(results.startedAt()) + 5 hours + 1 hours);
        seasons.closeSeason(ids);
        closed = true;
    }

    function assertRecordsAndRanking() external view {
        for (uint256 i; i < 12; ++i) {
            assertEq(seat.seats(actors[i]), seatCounts[i], "the NFT read must stay static");
        }
        for (uint256 i; i < approvals.length; ++i) {
            assertEq(seasons.recorded(approvals[i].id), approvals[i].recorded);
            assertEq(seasons.pointsOf(approvals[i].id), approvals[i].score, "seat changes cannot reprice old records");
        }
        (SeasonModel.Approval[] memory all, uint256 n) = SeasonModel.sorted(approvals, 0);
        SeasonModel.Wallet[12] memory ranked = SeasonModel.wallets(all, n);
        Seasons.Entry[25] memory actual = seasons.topOf(0);
        for (uint256 i; i < 12; ++i) {
            assertEq(actual[i].wallet, ranked[i].points == 0 ? address(0) : actors[ranked[i].actor]);
            assertEq(actual[i].points, ranked[i].points);
            assertEq(actual[i].pleaId, ranked[i].newest, "ties use counted plea IDs, not recording order");
        }
        for (uint256 i = 12; i < 25; ++i) {
            assertEq(actual[i].wallet, address(0));
        }
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract Run7SeatAccountingTest is Test {
    PLEA internal token;
    Seasons internal seasons;
    MockIMD internal quote;
    Run7SeatSource internal seat;
    Run7SeatHandler internal handler;
    address[12] internal actors;

    function setUp() public {
        SeasonResults results = new SeasonResults();
        vm.warp(results.startedAt());
        token = PLEA(ArtifactDeployment.deploy("PLEA.sol:PLEA", abi.encode(address(this))));
        quote = MockIMD(ArtifactDeployment.deploy("Mocks.sol:MockIMD", bytes("")));
        seat = new Run7SeatSource();
        seasons = Seasons(
            ArtifactDeployment.deploy(
                "Seasons.sol:Seasons", abi.encode(address(token), address(results), address(quote), address(seat))
            )
        );
        PleaDistributor drop = PleaDistributor(
            ArtifactDeployment.deploy("PleaDistributor.sol:PleaDistributor", abi.encode(address(token), address(this)))
        );
        token.setLauncher(address(results), address(seasons), address(drop));
        token.init(
            address(new SeasonWallSink(quote)), deployCode("PoolManager.sol:PoolManager", abi.encode(address(this)))
        );
        for (uint256 i; i < 12; ++i) {
            actors[i] = makeAddr(string.concat("run7 seat contender ", vm.toString(i)));
        }
        handler = new Run7SeatHandler(token, seasons, results, quote, seat, actors);
        // Seed payable and sub-threshold contenders; leave another result for each to record later.
        for (uint256 i; i < 12; ++i) {
            handler.setSeat(i, i % 2, 0);
            handler.issue(i, 26 + i, true);
            handler.record(3 * i);
            handler.issue(i, 26 + i, true);
            handler.record(3 * i + 1);
            handler.issue(i, 45, true);
        }
        handler.donate(10_000e18 + 1);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.setSeat.selector;
        selectors[1] = handler.issue.selector;
        selectors[2] = handler.record.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.closeWithLateRecords.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_pointsAndBestThreeUseSeatsOnlyAtRecordTime() public view {
        handler.assertRecordsAndRanking();
    }

    function invariant_imdAndBonusRemainConservedAcrossSeatFailuresAndClose() public view {
        uint256 quotePaid;
        uint256 bonusPaid;
        for (uint256 i; i < 12; ++i) {
            assertEq(quote.balanceOf(actors[i]), handler.quotePaid(i));
            assertEq(token.balanceOf(actors[i]), handler.bonusPaid(i));
            quotePaid += quote.balanceOf(actors[i]);
            bonusPaid += token.balanceOf(actors[i]);
        }
        assertEq(quotePaid, handler.totalPaid());
        assertEq(bonusPaid, handler.totalBonusPaid());
        assertEq(seasons.pot() + quotePaid, handler.funded());
        assertEq(token.balanceOf(address(seasons)) + bonusPaid + seasons.bonusBurned(), 60_000_000e18);
        assertEq(token.totalSupply() + seasons.bonusBurned(), 1_000_000_000e18);
        assertEq(seasons.bonusBurned() + bonusPaid, handler.closed() ? 10_000_000e18 : 0);
        assertEq(seasons.closed(0), handler.closed());
        assertEq(seasons.nextToClose(), handler.closed() ? 1 : 0);
    }

    function test_malformedOrStateChangingSeatAnswersCannotBlockRecordsOrPayouts() public {
        for (uint256 mode; mode < 6; ++mode) {
            handler.setSeat(mode, type(uint256).max, mode);
            handler.record(3 * mode + 2);
            assertEq(seasons.pointsOf(3 * mode + 3), mode == 0 ? 54 : 45);
        }
        _mixSeatsBeforeClose();
        handler.closeWithLateRecords(20);
        assertTrue(handler.closed());
        assertGt(handler.totalPaid(), 0);
        assertGt(handler.totalBonusPaid(), 0);
        handler.closeWithLateRecords(20); // a repeated close cannot pay season zero twice
        handler.record(0); // replay is refused even after closing
        handler.setSeat(0, 0, 0);
        invariant_pointsAndBestThreeUseSeatsOnlyAtRecordTime();
        invariant_imdAndBonusRemainConservedAcrossSeatFailuresAndClose();
    }

    function test_receivingOrLosingManySeatsAfterRecordNeverChangesEarnedPoints() public {
        handler.setSeat(0, type(uint256).max, 0);
        handler.record(2);
        assertEq(seasons.pointsOf(3), 54);
        handler.setSeat(0, 0, 0);
        handler.issue(0, 44, true);
        handler.record(36);
        assertEq(seasons.pointsOf(37), 44);
        handler.setSeat(0, 100, 0);
        handler.issue(0, 44, true);
        handler.record(37);
        assertEq(seasons.pointsOf(38), 52);
        assertEq(seasons.topOf(0)[0].points, 150, "only 54, 52 and 44 count");
        _mixSeatsBeforeClose();
        handler.closeWithLateRecords(24);
        invariant_pointsAndBestThreeUseSeatsOnlyAtRecordTime();
        invariant_imdAndBonusRemainConservedAcrossSeatFailuresAndClose();
    }

    function _mixSeatsBeforeClose() internal {
        for (uint256 i; handler.operations() < 100; ++i) {
            handler.setSeat(i, i % 3, i % 6);
        }
    }
}
