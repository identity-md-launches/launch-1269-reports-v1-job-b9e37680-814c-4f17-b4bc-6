// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Economy} from "./Economy.sol";
import {GameModule} from "./lib/GameModule.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FeeRouter} from "./FeeRouter.sol";
import {Params} from "./Params.sol";
import {FarmItems} from "./FarmItems.sol";
import {IRewards, ICore} from "./interfaces/IGame.sol";
import {ChainClock} from "./lib/ChainClock.sol";
import "./lib/Errors.sol";

interface IPrizePacks {
    function rewardPack(address p) external returns (uint256);
}

/// @notice Complete-week scores enter during lazy settlement, until a fixed seven-day grace deadline.
/// Finalization visits eight districts and at most three 32-level ticket paths, never farms.
contract Season is GameModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Week {
        uint256[8] districtSpend;
        uint256 participants;
        uint256 totalTickets;
        uint256 prize;
        uint64 target;
        bool finalized;
        uint8 winnerDistrict;
        address best;
        uint256 bestScore;
        bytes32 seed;
    }

    mapping(uint256 => Week) private seasons;
    mapping(uint256 => uint256) public pot;
    mapping(uint256 => uint256) public potRemaining;
    mapping(uint256 => bool) public rolled;
    mapping(uint256 => bool) public bestClaimed;
    mapping(uint256 => mapping(uint256 => uint256)) public eligiblePayers;
    uint256 public potLiability;
    event PotFunded(uint256 indexed week, uint256 amount);
    event PotPaid(uint256 indexed week, address indexed player, uint256 amount);
    event PotRolled(uint256 indexed from, uint256 indexed to, uint256 amount);

    function depositPot(uint256 amount) external {
        if (msg.sender != address(fees())) revert Unauthorized();
        if (amount == 0 || IERC20(registry.token()).balanceOf(address(this)) < potLiability + amount) {
            revert InvalidValue();
        }
        uint256 w = (block.timestamp - launchTime()) / 7 days;
        pot[w] += amount;
        potRemaining[w] += amount;
        potLiability += amount;
        emit PotFunded(w, amount);
    }

    function claimDeadline(uint256 w) public view returns (uint256) {
        return deadline(w) + 4 weeks;
    }

    function _payPot(uint256 w, address p, uint256 amount) private {
        if (rolled[w] || block.timestamp >= claimDeadline(w)) revert TooEarly();
        potRemaining[w] -= amount;
        potLiability -= amount;
        if (amount != 0) IERC20(registry.token()).safeTransfer(p, amount);
        emit PotPaid(w, p, amount);
    }

    function claimBest(uint256 w) external nonReentrant {
        if (!seasons[w].finalized || seasons[w].best != msg.sender || bestClaimed[w]) revert InvalidValue();
        bestClaimed[w] = true;
        _payPot(w, msg.sender, pot[w] * 40 / 100);
    }

    function rollover(uint256 w) external {
        if (rolled[w] || block.timestamp < claimDeadline(w)) revert TooEarly();
        uint256 current = (block.timestamp - launchTime()) / 7 days;
        rolled[w] = true;
        uint256 amount = potRemaining[w];
        potRemaining[w] = 0;
        pot[current] += amount;
        potRemaining[current] += amount;
        emit PotRolled(w, current, amount);
    }
    mapping(uint256 => mapping(address => uint256)) public spend;
    mapping(uint256 => mapping(address => uint256)) public yield;
    mapping(uint256 => mapping(address => uint256)) public index;
    mapping(uint256 => mapping(uint256 => address)) public participant;
    mapping(uint256 => mapping(uint256 => uint256)) private tree;
    mapping(uint256 => mapping(address => uint256)) public tickets;
    mapping(uint256 => mapping(address => uint256)) public activeEpochs;
    uint256 public constant BEST_MIN_EPOCHS = 20;
    uint256 public constant BEST_SPEND_CAP = 1 ether;
    uint256 public constant TICKET_HASH_CAP = 100_000;
    uint256 public constant WEEK_TICKET_CAP = 28 * TICKET_HASH_CAP;
    mapping(uint256 => mapping(address => bool)) public districtClaimed;
    mapping(uint256 => mapping(address => bool)) public lotteryWon;
    mapping(uint256 => mapping(address => bool)) public lotteryClaimed;
    mapping(uint256 => mapping(address => bool)) public completed;
    uint256 public constant SETTLEMENT_GRACE = 7 days;
    /// @notice One wallet counts for at most 1/WALLET_SHARE_DIV (10%) of its district score.
    uint256 public constant WALLET_SHARE_DIV = 10;
    uint256 public constant TOP = 10;
    mapping(uint256 => mapping(address => uint256)) public districtSpendOf;
    mapping(uint256 => mapping(uint256 => uint256)) public activeFarms;
    mapping(uint256 => mapping(address => bool)) public activeCounted;
    mapping(uint256 => mapping(address => bool)) public payingCounted;
    mapping(uint256 => mapping(uint256 => address[10])) private topSpenders;
    event SeasonPrepared(uint256 indexed week, uint256 target);
    event SeasonFinalized(uint256 indexed week, uint256 district, address best, bytes32 seed);
    event LotteryWinner(uint256 indexed week, address indexed player);

    constructor(address registry_) GameModule(registry_) {}

    function rewards() public view returns (IRewards) {
        return IRewards(registry.module(1));
    }

    function core() public view returns (ICore) {
        return ICore(registry.module(2));
    }

    function items() public view returns (FarmItems) {
        return FarmItems(registry.module(3));
    }

    function packs() public view returns (IPrizePacks) {
        return IPrizePacks(registry.module(4));
    }

    function grid() public view returns (address) {
        return registry.module(7);
    }

    function fees() public view returns (FeeRouter) {
        return FeeRouter(payable(registry.module(6)));
    }

    function launchTime() public view returns (uint256) {
        return registry.launchTime();
    }

    function district(address p) private pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(p))) % 8;
    }

    function recordSpend(address p, uint256 value, bool districtSpend) external {
        if (msg.sender != address(core()) && msg.sender != grid()) revert Unauthorized();
        if (block.timestamp < launchTime()) revert TooEarly();
        uint256 w = (block.timestamp - launchTime()) / 7 days;
        _recordSpend(p, w, value, districtSpend);
    }

    function recordRepair(address p, uint256 w, uint256 amount) external {
        if (msg.sender != address(core())) revert Unauthorized();
        if (block.timestamp >= deadline(w) || completed[w][p]) return;
        _recordSpend(p, w, amount, true);
    }

    function _recordSpend(address p, uint256 w, uint256 value, bool districtSpend) private {
        spend[w][p] += value;
        if (districtSpend && value != 0) {
            uint256 d = district(p);
            districtSpendOf[w][p] += value;
            if (activeCounted[w][p]) {
                if (!payingCounted[w][p]) {
                    payingCounted[w][p] = true;
                    activeFarms[w][d]++;
                    seasons[w].districtSpend[d] += districtSpendOf[w][p];
                } else {
                    seasons[w].districtSpend[d] += value;
                }
                _track(w, d, p);
            }
        }
    }

    /// @dev Exact top-10 by district spend. Spend only grows, so an untracked wallet never exceeds the minimum.
    /// Only wallets above the 10% cap matter, and at most ten can be (they would otherwise exceed the total).
    function _track(uint256 w, uint256 d, address p) private {
        address[10] storage top = topSpenders[w][d];
        uint256 low = type(uint256).max;
        uint256 slot;
        for (uint256 i; i < TOP; ++i) {
            address q = top[i];
            if (q == p) return;
            if (q == address(0)) {
                topSpenders[w][d][i] = p;
                return;
            }
            uint256 v = districtSpendOf[w][q];
            if (v < low) {
                low = v;
                slot = i;
            }
        }
        if (districtSpendOf[w][p] > low) topSpenders[w][d][slot] = p;
    }

    /// @notice Average active-paying spend, with each wallet capped at 10% of the uncapped district total.
    /// This is the requested soft cap, so even districts with fewer than ten payers can compete.
    function districtScore(uint256 w, uint256 d) public view returns (uint256 score, uint256 counted) {
        uint256 farms_ = activeFarms[w][d];
        if (farms_ == 0) return (0, 0);
        counted = seasons[w].districtSpend[d];
        uint256 cap = counted / WALLET_SHARE_DIV;
        for (uint256 i; i < TOP; ++i) {
            address p = topSpenders[w][d][i];
            if (p != address(0) && districtSpendOf[w][p] > cap) counted -= districtSpendOf[w][p] - cap;
        }
        score = counted / farms_;
    }

    function _add(uint256 w, uint256 i, uint256 amount, bool subtract) private {
        uint256 node = (1 << 32) + i;
        for (uint256 n; n < 33; ++n) {
            if (subtract) tree[w][node] -= amount;
            else tree[w][node] += amount;
            node >>= 1;
        }
    }

    function deadline(uint256 w) public view returns (uint256) {
        return launchTime() + (w + 1) * 7 days + SETTLEMENT_GRACE;
    }

    function recordActivity(address p, uint256 w, uint256 gross, uint256 committedHash) external {
        if (msg.sender != address(rewards())) revert Unauthorized();
        if (block.timestamp >= deadline(w) || completed[w][p]) return;
        if (!activeCounted[w][p]) {
            activeCounted[w][p] = true;
            if (districtSpendOf[w][p] != 0) {
                uint256 d = district(p);
                payingCounted[w][p] = true;
                activeFarms[w][d]++;
                seasons[w].districtSpend[d] += districtSpendOf[w][p];
                _track(w, d, p);
            }
        }
        activeEpochs[w][p]++;
        tickets[w][p] = Math.min(WEEK_TICKET_CAP, tickets[w][p] + Math.min(committedHash, TICKET_HASH_CAP));
        yield[w][p] += gross;
    }

    function complete(address p, uint256 w) external {
        if (msg.sender != address(rewards())) revert Unauthorized();
        if (!rewards().seasonReady(w)) revert TooEarly();
        if (block.timestamp >= deadline(w) || completed[w][p]) return;
        completed[w][p] = true;
        if (districtSpendOf[w][p] != 0 && tickets[w][p] != 0) ++eligiblePayers[w][district(p)];
        uint256 weight = tickets[w][p];
        if (weight == 0) return;
        Week storage s = seasons[w];
        uint256 i = ++s.participants;
        if (i >= 1 << 32) revert InvalidValue();
        index[w][p] = i;
        participant[w][i] = p;
        s.totalTickets += weight;
        _add(w, i, weight, false);
        if (activeEpochs[w][p] < BEST_MIN_EPOCHS || spend[w][p] == 0) return;
        uint256 score = Math.min(spend[w][p], Economy(registry.module(10)).farmDaily(p) * 7);
        if (s.best == address(0) || score > s.bestScore || (score == s.bestScore && uint160(p) < uint160(s.best))) {
            s.best = p;
            s.bestScore = score;
        }
    }

    function addPrize(uint256 w, uint256 amount) external {
        if (msg.sender != address(rewards())) revert Unauthorized();
        seasons[w].prize += amount;
    }

    /// @notice Compatibility argument is bounded, but preparation now always does constant work, unpaid.
    function prepare(uint256 w, uint256 limit) external nonReentrant {
        if (!rewards().seasonReady(w) || block.timestamp < deadline(w) || limit == 0 || limit > 64) revert TooEarly();
        Week storage s = seasons[w];
        if (s.target != 0) revert AlreadyDone();
        s.target = uint64(ChainClock.number() + 2);
        emit SeasonPrepared(w, s.target);
    }

    function _draw(uint256 w, uint256 point) private view returns (address) {
        uint256 node = 1;
        for (uint256 i; i < 32; ++i) {
            uint256 left = tree[w][node * 2];
            if (point < left) {
                node *= 2;
            } else {
                point -= left;
                node = node * 2 + 1;
            }
        }
        return participant[w][node - (1 << 32)];
    }

    function finalize(uint256 w) external nonReentrant {
        uint256 startGas = gasleft();
        Week storage s = seasons[w];
        if (s.finalized) revert AlreadyDone();
        if (s.target == 0 || ChainClock.number() <= s.target) revert TooEarly();
        bytes32 h = ChainClock.hash(s.target);
        if (h == bytes32(0)) revert NotConfigured();
        s.seed = keccak256(abi.encode(h, address(this), w, s.totalTickets));
        s.finalized = true;
        (uint256 bestDistrict,) = districtScore(w, 0);
        for (uint256 d = 1; d < 8; ++d) {
            (uint256 score,) = districtScore(w, d);
            if (score > bestDistrict) {
                bestDistrict = score;
                s.winnerDistrict = uint8(d);
            }
        }
        uint256 left = s.totalTickets;
        for (uint256 i; i < 3 && left != 0; ++i) {
            address winner = _draw(w, uint256(keccak256(abi.encode(s.seed, i))) % left);
            uint256 weight = tickets[w][winner];
            left -= weight;
            _add(w, index[w][winner], weight, true);
            lotteryWon[w][winner] = true;
            emit LotteryWinner(w, winner);
        }
        if (s.prize != 0) {
            if (s.best != address(0)) rewards().award(s.best, s.prize);
            else rewards().releasePrize(s.prize);
        }
        if (s.participants != 0) fees().payWork(msg.sender, Params.Key.SeasonBounty, 1, startGas - gasleft());
        emit SeasonFinalized(w, s.winnerDistrict, s.best, s.seed);
    }

    function rearm(uint256 w) external {
        Week storage s = seasons[w];
        if (s.finalized || s.target == 0 || ChainClock.number() <= uint256(s.target) + 256) revert TooEarly();
        s.target = uint64(ChainClock.number() + 2);
        emit SeasonPrepared(w, s.target);
    }

    function result(uint256 w)
        external
        view
        returns (bool finalized, uint8 d, address best, uint256 prize, bytes32 seed)
    {
        Week storage s = seasons[w];
        return (s.finalized, s.winnerDistrict, s.best, s.prize, s.seed);
    }

    function claimDistrict(uint256 w) external nonReentrant returns (uint256 id) {
        Week storage s = seasons[w];
        if (
            !s.finalized || index[w][msg.sender] == 0 || districtSpendOf[w][msg.sender] == 0
                || district(msg.sender) != s.winnerDistrict || districtClaimed[w][msg.sender]
        ) revert InvalidValue();
        districtClaimed[w][msg.sender] = true;
        _payPot(w, msg.sender, (pot[w] * 30 / 100) / eligiblePayers[w][s.winnerDistrict]);
        id = packs().rewardPack(msg.sender);
    }

    function claimLottery(uint256 w) external nonReentrant returns (uint256 id) {
        if (!lotteryWon[w][msg.sender] || lotteryClaimed[w][msg.sender]) revert InvalidValue();
        lotteryClaimed[w][msg.sender] = true;
        _payPot(w, msg.sender, pot[w] * 10 / 100);
        // v3.14: the item is a lazy pack receipt like claimDistrict, so a full inventory never blocks the pot share.
        id = packs().rewardPack(msg.sender);
    }
}
