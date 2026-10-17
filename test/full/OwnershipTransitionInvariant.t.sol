// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ArtifactDeployment} from "../utils/ArtifactDeployment.sol";

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PLEA} from "src/PLEA.sol";
import {Seasons} from "src/Seasons.sol";
import {PleaDistributor} from "src/PleaDistributor.sol";
import {MockIMD} from "../utils/Mocks.sol";
import {SeasonResults, SeasonWallSink} from "../utils/SeasonModel.sol";

/// @dev Exercises PLEA's actual Ownable2Step integration while two real season prizes are held.
/// The oracle mock supplies fixed approvals only; PLEA and Seasons execute all authorization,
/// ownership, ranking, payout and burning logic themselves.
contract OwnershipTransitionHandler is Test {
    PLEA public immutable token;
    Seasons public immutable seasons;
    MockIMD public immutable quote;
    address[3] public actors;
    address public expectedOwner;
    address public expectedPending;
    bool[3] public expectedAllowed;
    uint256[3] public quotePaid;
    uint256[3] public bonusPaid;
    bool public closed;
    uint256 public acceptedTransfers;
    uint256 public rejectedActions;

    constructor(PLEA token_, Seasons seasons_, MockIMD quote_, address[3] memory actors_) {
        token = token_;
        seasons = seasons_;
        quote = quote_;
        actors = actors_;
        expectedOwner = actors_[0];
    }

    function nominate(uint256 callerSeed, uint256 nomineeSeed, bool cancel) external {
        address caller = actors[callerSeed % 3];
        address nominee = cancel ? address(0) : actors[nomineeSeed % 3];
        bool authorized = caller == expectedOwner;
        if (!authorized) refuse(caller);
        vm.prank(caller);
        token.transferOwnership(nominee);
        if (authorized) expectedPending = nominee;
        assertEq(token.owner(), expectedOwner, "a nomination alone must not remove a prize winner");
        assertEq(token.pendingOwner(), expectedPending);
    }

    function accept(uint256 callerSeed) external {
        address caller = actors[callerSeed % 3];
        bool authorized = caller == expectedPending;
        if (!authorized) refuse(caller);
        vm.prank(caller);
        token.acceptOwnership();
        if (authorized) {
            expectedOwner = caller;
            expectedPending = address(0);
            ++acceptedTransfers;
        }
        assertEq(token.owner(), expectedOwner);
        assertEq(token.pendingOwner(), expectedPending);
    }

    function allow(uint256 callerSeed, uint256 targetSeed) external {
        address caller = actors[callerSeed % 3];
        uint256 target = targetSeed % 3;
        bool authorized = caller == expectedOwner;
        if (!authorized) refuse(caller);
        vm.prank(caller);
        token.allow(actors[target]);
        if (authorized) expectedAllowed[target] = true;
        assertEq(token.allowed(actors[target]), expectedAllowed[target]);
    }

    function renounce(uint256 callerSeed) external {
        address caller = actors[callerSeed % 3];
        bool authorized = caller == expectedOwner;
        if (!authorized) refuse(caller);
        vm.prank(caller);
        token.renounceOwnership();
        if (authorized) {
            expectedOwner = address(0);
            expectedPending = address(0);
        }
        assertEq(token.owner(), expectedOwner);
        assertEq(token.pendingOwner(), expectedPending, "renouncing cancels the pending transfer too");
    }

    function closePrizes() external {
        if (closed) return;
        // Only the accepted owner is excluded (the launch owner too, but this stand-in hook has no
        // owner). A nomination cannot revoke either fixed rank.
        if (expectedOwner != actors[1]) {
            quotePaid[1] = 4.5e18;
            bonusPaid[1] = 450_000e18;
        }
        if (expectedOwner != actors[2]) {
            quotePaid[2] = 4.46e18;
            bonusPaid[2] = 446_000e18;
        }
        seasons.closeSeason(new uint256[](0));
        closed = true;
        for (uint256 i; i < 3; ++i) {
            assertEq(quote.balanceOf(actors[i]), quotePaid[i]);
            assertEq(token.balanceOf(actors[i]), bonusPaid[i]);
        }
    }

    function refuse(address caller) internal {
        ++rejectedActions;
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract OwnershipTransitionInvariantTest is Test {
    PLEA internal token;
    Seasons internal seasons;
    MockIMD internal quote;
    PleaDistributor internal drop;
    SeasonWallSink internal wall;
    OwnershipTransitionHandler internal handler;
    address[3] internal actors;

    function setUp() public {
        actors = [makeAddr("initial PLEA owner"), makeAddr("first season leader"), makeAddr("second season leader")];
        SeasonResults results = new SeasonResults();
        vm.warp(results.startedAt());
        token = PLEA(ArtifactDeployment.deploy("PLEA.sol:PLEA", abi.encode(actors[0])));
        quote = MockIMD(ArtifactDeployment.deploy("Mocks.sol:MockIMD", bytes("")));
        seasons = Seasons(
            ArtifactDeployment.deploy(
                "Seasons.sol:Seasons", abi.encode(address(token), address(results), address(quote), address(0))
            )
        );
        wall = new SeasonWallSink(quote);
        drop = PleaDistributor(
            ArtifactDeployment.deploy("PleaDistributor.sol:PleaDistributor", abi.encode(address(token), actors[0]))
        );
        token.setLauncher(address(results), address(seasons), address(drop));
        token.init(address(wall), deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        for (uint256 id = 1; id <= 4; ++id) {
            results.setResult(id, actors[id <= 2 ? 1 : 2], 45, true, results.startedAt());
            seasons.record(id);
        }
        assertEq(seasons.topOf(0)[0].wallet, actors[1]);
        assertEq(seasons.topOf(0)[1].wallet, actors[2]);
        quote.mint(address(seasons), 100e18);
        seasons.checkpoint();
        vm.warp(uint256(results.startedAt()) + 18000 + 1 hours);
        handler = new OwnershipTransitionHandler(token, seasons, quote, actors);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.nominate.selector;
        selectors[1] = handler.accept.selector;
        selectors[2] = handler.allow.selector;
        selectors[3] = handler.closePrizes.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_onlyAcceptedTransfersChangeOwnerOrAllowlistAuthority() public view {
        assertEq(token.owner(), handler.expectedOwner());
        assertEq(token.pendingOwner(), handler.expectedPending());
        for (uint256 i; i < 3; ++i) {
            assertEq(token.allowed(actors[i]), handler.expectedAllowed(i));
        }
        assertEq(token.launcher(), address(this));
        assertEq(token.hook(), address(wall));
        assertEq(token.seasons(), address(seasons));
        assertEq(token.distributor(), address(drop));
    }

    function invariant_ownershipChangesCannotMoveOrDuplicateCustodiedPrizes() public view {
        uint256 quotePaid;
        uint256 bonusPaid;
        for (uint256 i; i < 3; ++i) {
            assertEq(quote.balanceOf(actors[i]), handler.quotePaid(i));
            assertEq(token.balanceOf(actors[i]), handler.bonusPaid(i));
            quotePaid += handler.quotePaid(i);
            bonusPaid += handler.bonusPaid(i);
        }
        assertEq(quote.balanceOf(address(seasons)) + quotePaid, 100e18);
        assertEq(token.balanceOf(address(seasons)) + bonusPaid + seasons.bonusBurned(), 60_000_000e18);
        assertEq(token.totalSupply() + seasons.bonusBurned(), 1_000_000_000e18);
        assertEq(token.balanceOf(address(wall)), 820_000_000e18);
        assertEq(token.balanceOf(address(drop)), 120_000_000e18);
        assertEq(seasons.closed(0), handler.closed());
        assertEq(seasons.nextToClose(), handler.closed() ? 1 : 0);
    }

    function test_replacedNomineeCannotAcceptAndNewOwnerAloneLosesTheirPrize() public {
        handler.nominate(0, 1, false);
        handler.allow(1, 1); // nominee is not yet an owner
        handler.nominate(0, 2, false);
        handler.accept(1); // replaced nominee is no longer allowed to accept
        handler.accept(2);
        handler.allow(0, 0); // previous owner lost its authority
        handler.allow(2, 1);
        handler.closePrizes();
        assertEq(handler.acceptedTransfers(), 1);
        assertEq(handler.rejectedActions(), 3);
        assertEq(quote.balanceOf(actors[1]), 4.5e18);
        assertEq(quote.balanceOf(actors[2]), 0);
        assertEq(seasons.rollover(), 95.5e18, "owner's rank is not reassigned");
        invariant_onlyAcceptedTransfersChangeOwnerOrAllowlistAuthority();
        invariant_ownershipChangesCannotMoveOrDuplicateCustodiedPrizes();
    }

    function test_cancelledNomineeCannotAcceptAndBothLeadersKeepTheirPrizes() public {
        handler.nominate(0, 1, false);
        handler.nominate(0, 0, true);
        handler.accept(1);
        handler.closePrizes();
        assertEq(token.owner(), actors[0]);
        assertEq(token.pendingOwner(), address(0));
        assertEq(quote.balanceOf(actors[1]), 4.5e18);
        assertEq(quote.balanceOf(actors[2]), 4.46e18);
        invariant_ownershipChangesCannotMoveOrDuplicateCustodiedPrizes();
    }

    function test_renounceClearsNominationAndDoesNotLetFormerNomineeClaimAuthority() public {
        handler.nominate(0, 1, false);
        handler.renounce(1); // pending owner cannot renounce somebody else's ownership
        handler.renounce(0);
        handler.accept(1);
        handler.allow(0, 0);
        handler.allow(1, 1);
        handler.closePrizes();
        assertEq(token.owner(), address(0));
        assertEq(token.pendingOwner(), address(0));
        invariant_onlyAcceptedTransfersChangeOwnerOrAllowlistAuthority();
        invariant_ownershipChangesCannotMoveOrDuplicateCustodiedPrizes();
    }
}
