// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPLEA, IGate, IPleaHook} from "./interfaces/IPleaParts.sol";

/// @title Seasons — PLEA's leaderboard and prizes while the Cabal lives
/// @notice Seasons of `SEASON` each run back to back from the moment trading opens; the last one
/// ends when the Cabal dies. An approved plea earns its judges' score (0-45) as points, times 1.2
/// (rounded down) when the seller holds an IMD seat NFT at the time of recording; each wallet's
/// best three count. When a season ends anyone calls `closeSeason`: the top 25 with at
/// least 60 points are paid shares of the prize pot in IMD that fall in a straight line from 4.50%
/// (rank 1) to 3.50% (rank 25), and unpaid shares roll over. The pot is fed by the hook's 0.25%
/// prize fee and by overruled objections' stakes. After the last season is closed, whatever is left
/// goes to the buy wall.
/// @notice PLEA bonus: Seasons holds 6% of the supply, minted to it at launch. Each of the first
/// six seasons pays 10,000,000 PLEA to the same top 25 with the same shares; a share nobody
/// qualifies for is burned when the season closes. If the Cabal dies before the sixth season,
/// `flushToWall` burns the rest. Nobody can withdraw it.
/// @notice The owner of PLEA does not play: its pleas earn no points, and no prize or bonus goes
/// to it, so the prize fee always leaves the team for good.
/// @notice Objection! (the Tribunal, deployed after the launch): a plea's points wait while others
/// may object to it or an objection is pending; a sustained objection means no points, and the
/// recorded score is the lowest any panel gave. With no Tribunal, points are recorded as before.
contract Seasons {
    using SafeERC20 for IERC20;

    error NotApproved(uint256 pleaId);
    error AlreadyRecorded(uint256 pleaId);
    error SeasonClosed(uint256 season);
    error NotReady(uint256 season);
    error NotFinished();
    error CallbackNotExpected();
    error OwnerExcluded();
    error Held(uint256 pleaId);
    error ObjectionSustained(uint256 pleaId);
    error NotTribunal();
    error UnfundedStake();

    event Recorded(uint256 indexed pleaId, uint256 indexed season, address indexed wallet, uint8 score, uint16 points);
    /// @notice The seller held an IMD seat when the plea was recorded: it counts `pleaPoints` (score x 1.2).
    event SeatMultiplier(uint256 indexed pleaId, address indexed wallet, uint8 score, uint8 pleaPoints);
    event SeasonClosedOut(uint256 indexed season, uint256 pot, uint256 paid);
    event PrizePaid(uint256 indexed season, address indexed wallet, uint8 rank, uint256 amount);
    event LeftoverToWall(uint256 amount);
    event PrizeFunded(uint256 indexed season, uint256 amount);
    event BonusPaid(uint256 indexed season, address indexed wallet, uint8 rank, uint256 amount);
    event BonusBurned(uint256 indexed season, uint256 amount);

    struct Entry {
        address wallet;
        uint16 points;
        uint64 pleaId; // newest of the counted best three pleas (ties go to the earlier one)
    }

    // ---------------------------------------------------------------- agreed numbers
    uint256 public constant MIN_POINTS = 60;
    uint256 public constant TOP = 25;
    /// @notice After a season ends, time to record late approvals before it can be closed. An
    /// objection window plus a pending objection's expiry (40 minutes) always ends inside it.
    uint256 public constant CLOSE_GRACE = 1 hours;
    /// @notice The PLEA bonus: 10,000,000 PLEA for each of the first six seasons (6% in all).
    uint256 public constant BONUS_SEASONS = 6;
    uint256 public constant BONUS_PER_SEASON = 10_000_000e18;
    /// @notice Points for a plea are its score times this, over 10,000, when the seller holds at
    /// least one IMD seat NFT when the plea is recorded (binary, not per seat). Points only: the
    /// Tribunal's score/need comparison and the 60-point bar are untouched.
    uint256 public constant SEAT_MULTIPLIER_BPS = 12_000;
    /// @dev Gas lent to the seat NFT's `balanceOf`; a read that fails or runs out means no multiplier.
    uint256 internal constant SEAT_READ_GAS = 100_000;
    /// @dev Prize shares in basis points, two bytes per rank, 4.50% down to 3.50%, 10,000 in all.
    bytes internal constant SHARES =
        hex"01c201be01ba01b601b101ad01a901a501a1019c019801940190018c01880184017f017b01770173016f016a01660162015e";

    IPLEA public immutable plea;
    IGate public immutable gate;
    IERC20 public immutable imd;
    /// @notice The IMD seat NFT (ERC-721) whose holders' points are multiplied; zero means none.
    address public immutable seat;
    uint256 public immutable SEASON;

    mapping(uint256 => Entry[TOP]) internal _top;
    mapping(uint256 => mapping(address => uint8[3])) internal _best;
    mapping(uint256 => mapping(address => uint64[3])) internal _bestPleaIds;
    mapping(uint256 => bool) public closed;
    mapping(uint256 => bool) public recorded;
    /// @notice The points a recorded plea counted (its score, times the seat multiplier at record time).
    mapping(uint256 => uint8) public pointsOf;
    /// @notice The oldest season not yet closed (season 0 starts when trading opens).
    uint256 public nextToClose;
    /// @notice Fees received during each season, excluding rollover from earlier seasons.
    mapping(uint256 => uint256) public seasonFees;
    uint256 public rollover;
    /// @notice PLEA bonus burned so far (unpaid shares, and seasons that never ran).
    uint256 public bonusBurned;
    uint256 private accountedPot;
    bool private redeeming;

    constructor(address plea_, address gate_, address imd_, address seat_) {
        plea = IPLEA(plea_);
        gate = IGate(gate_);
        imd = IERC20(imd_);
        seat = seat_;
        SEASON = IGate(gate_).SEASON();
    }

    // ================================================================ views

    function topOf(uint256 season) external view returns (Entry[TOP] memory) {
        return _top[season];
    }

    /// @notice The share of the pot and the bonus paid to `rank` (0 = first), in basis points.
    function shareBps(uint256 rank) public pure returns (uint256) {
        return (uint256(uint8(SHARES[2 * rank])) << 8) | uint8(SHARES[2 * rank + 1]);
    }

    /// @notice The wallets that never earn points, prizes or the bonus (read by the Tribunal).
    function excluded(address wallet) external view returns (bool) {
        return _excluded(wallet);
    }

    /// @notice The wallet's three counted pleas' points (after the seat multiplier) in a season.
    function bestOf(uint256 season, address wallet) external view returns (uint8[3] memory) {
        return _best[season][wallet];
    }

    /// @notice The points a plea with `score` earns `wallet` if recorded now: the score, times 1.2
    /// (rounded down) while the wallet holds an IMD seat NFT.
    function pointsFor(address wallet, uint8 score) public view returns (uint8) {
        return holdsSeat(wallet) ? uint8(uint256(score) * SEAT_MULTIPLIER_BPS / 10_000) : score;
    }

    /// @notice Whether `wallet` holds at least one IMD seat NFT. Read, never trust: no seat contract,
    /// a reverting one or a malformed answer means no multiplier, and can never block a record.
    function holdsSeat(address wallet) public view returns (bool) {
        if (seat == address(0)) return false;
        (bool ok, bytes memory ret) =
            seat.staticcall{gas: SEAT_READ_GAS}(abi.encodeWithSignature("balanceOf(address)", wallet));
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) != 0;
    }

    /// @notice A season's window. It exists once it has started while the Cabal was alive; it ends
    /// after `SEASON` or when the Cabal dies.
    function seasonBounds(uint256 season) public view returns (bool exists, uint64 start, uint64 end, bool ended) {
        uint256 t0 = gate.startedAt();
        if (t0 == 0) return (false, 0, 0, false);
        uint256 s = t0 + season * SEASON;
        uint256 e = s + SEASON;
        uint256 died = gate.diedAt();
        if (block.timestamp < s || (died != 0 && died <= s)) return (false, uint64(s), uint64(e), false);
        if (died != 0 && died < e) e = died;
        return (true, uint64(s), uint64(e), block.timestamp >= e);
    }

    /// @notice The season running now, if the Cabal is alive.
    function currentSeason() external view returns (bool live, uint256 season, uint64 endsAt) {
        uint256 t0 = gate.startedAt();
        if (t0 == 0 || !gate.cabalAlive()) return (false, 0, 0);
        season = (block.timestamp - t0) / SEASON;
        return (true, season, uint64(t0 + (season + 1) * SEASON));
    }

    /// @notice All prize assets, including later seasons' fees and redeemable IMD claims.
    /// A close distributes only that season's fees plus rollover, not this whole balance.
    function pot() public view returns (uint256) {
        IPoolManager pm = IPoolManager(plea.poolManager());
        uint256 claims = address(pm) == address(0) ? 0 : pm.balanceOf(address(this), uint256(uint160(address(imd))));
        return imd.balanceOf(address(this)) + claims;
    }

    /// @notice Accounts new prize assets to the running season. The hook calls this in every swap
    /// that pays a prize fee, including fees delivered as claims. Direct donations belong to the
    /// season when first checkpointed; donors can call immediately after transferring.
    function checkpoint() public {
        uint256 assets = pot();
        uint256 added = assets - accountedPot;
        if (added == 0) return;
        accountedPot = assets;
        uint256 t0 = gate.startedAt();
        uint256 died = gate.diedAt();
        uint256 season = t0 == 0 ? 0 : ((died == 0 ? block.timestamp : died - 1) - t0) / SEASON;
        if (closed[season]) rollover += added;
        else seasonFees[season] += added;
        emit PrizeFunded(season, added);
    }

    /// @notice Accounts an overruled stake to the plea's season, even if `settle` is called in a
    /// later season. Only the committed Tribunal can label a payment this way; it transfers the
    /// stake first. Closed pots cannot be paid again, so their late stakes become rollover.
    function checkpointObjection(uint256 pleaId, uint256 amount) external {
        address tribunal = _tribunal();
        if (tribunal == address(0) || msg.sender != tribunal) revert NotTribunal();
        (,, bool approved, uint64 verdictAt) = gate.result(pleaId);
        if (!approved) revert NotApproved(pleaId);
        if (pot() - accountedPot < amount) revert UnfundedStake();
        accountedPot += amount;
        uint256 season = _seasonOf(verdictAt);
        if (closed[season]) rollover += amount;
        else seasonFees[season] += amount;
        emit PrizeFunded(season, amount);
        // Any other unaccounted donations still belong to the running season.
        checkpoint();
    }

    /// @notice True once the Cabal is dead and its last season is closed.
    function finished() public view returns (bool) {
        if (gate.diedAt() == 0) return false;
        (bool exists,,,) = seasonBounds(nextToClose);
        return !exists;
    }

    // ================================================================ points

    /// @notice Records an approved plea's score for its season. Anyone may call it; the seller has
    /// every reason to. Must happen before the season is closed, and after the plea's objection
    /// window: a sustained objection leaves no points, an overruled one may lower the score.
    function record(uint256 pleaId) external {
        (address seller, uint8 score, bool approved, uint64 verdictAt) = gate.result(pleaId);
        if (!approved) revert NotApproved(pleaId);
        if (recorded[pleaId]) revert AlreadyRecorded(pleaId);
        if (_excluded(seller)) revert OwnerExcluded();
        uint256 season = _seasonOf(verdictAt);
        if (closed[season]) revert SeasonClosed(season);
        (bool held, bool sustained, uint8 lowest) = _standing(pleaId);
        if (held) revert Held(pleaId);
        if (sustained) revert ObjectionSustained(pleaId);
        _record(pleaId, season, seller, lowest < score ? lowest : score);
    }

    /// @dev What the Tribunal says about a plea, read through PLEA's launcher. Read, never trust: a
    /// launcher without `tribunal()` or no Tribunal deployed means today's behaviour, and a Tribunal
    /// that reverts can never block a record or a close.
    function _standing(uint256 pleaId) internal view returns (bool held, bool sustained, uint8 lowest) {
        lowest = type(uint8).max;
        address t = _tribunal();
        if (t == address(0)) return (false, false, lowest);
        (bool ok, bytes memory ret) = t.staticcall(abi.encodeWithSignature("standing(uint256)", pleaId));
        if (!ok || ret.length != 96) return (false, false, lowest);
        return abi.decode(ret, (bool, bool, uint8));
    }

    function _tribunal() internal view returns (address) {
        address launcher = plea.launcher();
        if (launcher == address(0)) return address(0);
        (bool ok, bytes memory ret) = launcher.staticcall(abi.encodeWithSignature("tribunal()"));
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
    }

    function _seasonOf(uint64 verdictAt) internal view returns (uint256) {
        return (uint256(verdictAt) - gate.startedAt()) / SEASON;
    }

    /// @dev `score` is the judged score (the lowest of the panels); the plea's points are that score
    /// times the seat multiplier when the seller holds a seat as it is recorded.
    function _record(uint256 pleaId, uint256 season, address seller, uint8 score) internal {
        recorded[pleaId] = true;
        uint8 pleaPoints = pointsFor(seller, score);
        pointsOf[pleaId] = pleaPoints;
        if (pleaPoints != score) emit SeatMultiplier(pleaId, seller, score, pleaPoints);
        uint8[3] storage b = _best[season][seller];
        uint64[3] storage ids = _bestPleaIds[season][seller];
        uint256 mi;
        // Replace the lowest points, or the newest plea among equal lowest points.
        for (uint256 i = 1; i < 3; ++i) {
            if (b[i] < b[mi] || (b[i] == b[mi] && ids[i] > ids[mi])) mi = i;
        }
        uint16 pts;
        if (pleaPoints > b[mi] || (pleaPoints == b[mi] && pleaId < ids[mi])) {
            b[mi] = pleaPoints;
            ids[mi] = uint64(pleaId);
            pts = uint16(uint256(b[0]) + b[1] + b[2]);
            uint64 newest = ids[0];
            if (ids[1] > newest) newest = ids[1];
            if (ids[2] > newest) newest = ids[2];
            _insertWallet(season, Entry({wallet: seller, points: pts, pleaId: newest}));
        }
        emit Recorded(pleaId, season, seller, score, pts);
    }

    function _better(Entry memory a, Entry memory b) internal pure returns (bool) {
        if (b.wallet == address(0)) return true;
        return a.points > b.points || (a.points == b.points && a.pleaId < b.pleaId);
    }

    function _insertWallet(uint256 season, Entry memory ne) internal {
        Entry[TOP] storage t = _top[season];
        Entry[TOP] memory m = t;
        uint256 pos = TOP;
        for (uint256 k; k < TOP; ++k) {
            if (m[k].wallet == ne.wallet) {
                pos = k;
                break;
            }
        }
        if (pos == TOP) {
            if (!_better(ne, m[TOP - 1])) return;
            pos = TOP - 1;
        }
        uint256 i = pos;
        while (i > 0 && _better(ne, m[i - 1])) {
            m[i] = m[i - 1];
            --i;
        }
        m[i] = ne;
        for (uint256 k = i; k <= pos; ++k) {
            t[k] = m[k];
        }
    }

    // ================================================================ closing

    /// @notice Closes the oldest open season once it has ended (plus a one-hour grace): records any
    /// listed approvals first, then pays the top 25 (IMD and, in the first six seasons, the PLEA
    /// bonus). Anyone may call it.
    function closeSeason(uint256[] calldata pleaIds) external {
        for (uint256 i; i < pleaIds.length; ++i) {
            _tryRecord(pleaIds[i]);
        }
        uint256 season = nextToClose;
        (bool exists,, uint64 end, bool ended) = seasonBounds(season);
        if (!exists || !ended || block.timestamp < uint256(end) + CLOSE_GRACE) revert NotReady(season);
        checkpoint();
        closed[season] = true;
        nextToClose = season + 1;

        uint256 amountIn = seasonFees[season] + rollover;
        delete seasonFees[season];
        rollover = 0;
        _redeemClaims();
        uint256 paid;
        Entry[TOP] memory t = _top[season];
        _dropOwner(t);
        for (uint256 i; i < TOP; ++i) {
            if (t[i].wallet == address(0) || t[i].points < MIN_POINTS) continue;
            uint256 amount = amountIn * shareBps(i) / 10_000;
            if (amount != 0 && _pay(t[i].wallet, amount)) {
                paid += amount;
                emit PrizePaid(season, t[i].wallet, uint8(i + 1), amount);
            }
        }
        accountedPot -= paid;
        rollover = amountIn - paid;
        emit SeasonClosedOut(season, amountIn, paid);

        if (season < BONUS_SEASONS) _payBonus(season, t);
    }

    /// @notice Once the Cabal is dead and its last season closed, anyone sends what is left (unpaid
    /// shares) to the buy wall, and burns the PLEA bonus of seasons that never ran.
    function flushToWall() external {
        if (!finished()) revert NotFinished();
        uint256 leftover = IERC20(address(plea)).balanceOf(address(this));
        if (leftover != 0) {
            plea.burn(leftover);
            bonusBurned += leftover;
            emit BonusBurned(nextToClose, leftover);
        }
        checkpoint();
        _redeemClaims();
        uint256 amount = pot();
        if (amount == 0) return;
        accountedPot = 0;
        rollover = 0;
        IPleaHook h = IPleaHook(plea.hook());
        imd.forceApprove(address(h), amount);
        h.fundWall(amount);
        emit LeftoverToWall(amount);
    }

    /// @dev A prize fee can arrive as a claim before a large buyer settles its input. Closing is
    /// later, with the PoolManager locked and funded, so redeem it into ordinary prize IMD.
    function _redeemClaims() internal {
        IPoolManager pm = IPoolManager(plea.poolManager());
        if (address(pm) == address(0)) return;
        uint256 amount = pm.balanceOf(address(this), uint256(uint160(address(imd))));
        if (amount == 0) return;
        redeeming = true;
        pm.unlock(abi.encode(amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        IPoolManager pm = IPoolManager(plea.poolManager());
        if (msg.sender != address(pm) || !redeeming) revert CallbackNotExpected();
        redeeming = false;
        uint256 amount = abi.decode(data, (uint256));
        pm.burn(address(this), uint256(uint160(address(imd))), amount);
        pm.take(Currency.wrap(address(imd)), address(this), amount);
        return "";
    }

    /// @dev Skips, never reverts: a close may list pleas of the running season that are still held.
    function _tryRecord(uint256 pleaId) internal {
        if (recorded[pleaId]) return;
        (address seller, uint8 score, bool approved, uint64 verdictAt) = gate.result(pleaId);
        if (!approved || _excluded(seller)) return;
        uint256 season = _seasonOf(verdictAt);
        if (closed[season]) return;
        (bool held, bool sustained, uint8 lowest) = _standing(pleaId);
        if (held || sustained) return;
        _record(pleaId, season, seller, lowest < score ? lowest : score);
    }

    /// @dev Points recorded before an ownership transfer: the current owner is not paid. Its rank's
    /// share is not paid to anyone else either (the IMD rolls over, the PLEA bonus share is burned).
    function _dropOwner(Entry[TOP] memory t) internal view {
        (address a,, address c) = _owners();
        for (uint256 i; i < TOP; ++i) {
            address w = t[i].wallet;
            if (w != address(0) && (w == a || w == c)) t[i].wallet = address(0);
        }
    }

    /// @dev The owner of PLEA and the launch owner the hook pays its 1% to: neither ever earns
    /// points, prizes or the bonus, so a handover inside the team cannot bring a prize back to it.
    /// A wallet merely nominated (two-step transfer) is not excluded: that would let the owner strip
    /// a leader by nominating them, the run-3 finding Ownable2Step closed.
    function _owners() internal view returns (address a, address b, address c) {
        a = plea.owner();
        address hook_ = plea.hook();
        if (hook_ != address(0)) {
            // Read, never trust: a hook without `owner()` must not be able to block a record or a close.
            (bool ok, bytes memory ret) = hook_.staticcall(abi.encodeWithSignature("owner()"));
            if (ok && ret.length == 32) c = abi.decode(ret, (address));
        }
    }

    function _excluded(address w) internal view returns (bool) {
        (address a,, address c) = _owners();
        return w != address(0) && (w == a || w == c);
    }

    /// @dev Pays the season's PLEA bonus to the qualifying top 25 (same shares and minimum as the
    /// IMD prizes) and burns what is not paid. Seasons is an exempt sender, so the transfers work
    /// while the Cabal watches; one that fails is burned with the rest.
    function _payBonus(uint256 season, Entry[TOP] memory t) internal {
        IERC20 token = IERC20(address(plea));
        uint256 paid;
        for (uint256 i; i < TOP; ++i) {
            if (t[i].wallet == address(0) || t[i].points < MIN_POINTS) continue;
            uint256 amount = BONUS_PER_SEASON * shareBps(i) / 10_000;
            (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (t[i].wallet, amount)));
            if (ok && (ret.length == 0 || abi.decode(ret, (bool)))) {
                paid += amount;
                emit BonusPaid(season, t[i].wallet, uint8(i + 1), amount);
            }
        }
        uint256 unpaid = BONUS_PER_SEASON - paid;
        uint256 held = token.balanceOf(address(this));
        if (unpaid > held) unpaid = held;
        if (unpaid != 0) {
            plea.burn(unpaid);
            bonusBurned += unpaid;
            emit BonusBurned(season, unpaid);
        }
    }

    /// @dev A transfer that fails (a blocked recipient) leaves the share in the pot.
    function _pay(address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = address(imd).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }
}
