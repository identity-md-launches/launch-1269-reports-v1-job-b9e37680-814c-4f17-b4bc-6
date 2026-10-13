// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GameModule} from "./lib/GameModule.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FarmItems} from "./FarmItems.sol";
import {ItemMath} from "./lib/ItemMath.sol";
import {EconomyMath} from "./lib/EconomyMath.sol";
import {IRewards} from "./interfaces/IGame.sol";
import {Params} from "./Params.sol";
import "./lib/Errors.sol";

interface IYieldRewards {
    function lastYieldPerHash() external view returns (uint256);
    function lastFarmDaily(address) external view returns (uint256);
    function lastAverageDaily() external view returns (uint256);
}

interface IFeatureFlags {
    function enabled(uint256) external view returns (bool);
}

interface IEconomyCore {
    function syncFor(address p) external;
}

/// @notice Immutable token-denominated quotes and escrow. No token mint/burn, ETH pricing or admin withdrawal.
contract Economy is GameModule, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant FARM_FLOOR = 3000 ether;
    /// @notice v3.14: bound of the sorted lock-list walk per insertion (districtStake reads the top ten).
    uint256 public constant MAX_INSERT_STEPS = 32;
    uint256 public constant HASH_RATE_FLOOR = 0.000001 ether * 1 ether; // per six-hour epoch per hash

    struct Lock {
        uint256 amount;
        uint64 start;
        uint64 end;
        uint16 bonus;
    }
    mapping(address => Lock) public locks;
    mapping(uint256 => uint256) public districtTotal;
    mapping(uint256 => address) public head;
    mapping(address => address) public next;
    mapping(address => address) public previous;
    uint256 public totalLocked;
    event Locked(address indexed player, uint256 amount, uint256 end, uint256 bonus);
    event Unlocked(address indexed player, uint256 amount);
    constructor(address r) GameModule(r) {}

    function rewards() private view returns (IYieldRewards) {
        return IYieldRewards(registry.module(1));
    }

    /// @dev Core calls during settlement, including inside lock's core synchronization.
    function autoRepair(address p, uint256 threshold, uint256[24] calldata ids) external returns (uint256 paid) {
        if (msg.sender != registry.module(2)) revert Unauthorized();
        IRewards reward = IRewards(registry.module(1));
        FarmItems inventory = FarmItems(registry.module(3));
        for (uint256 i; i < 24; ++i) {
            uint256 id = ids[i];
            if (id == 0) continue;
            FarmItems.Item memory x = inventory.data(id);
            if (x.holder != p || x.durability >= threshold) continue;
            uint256 cost = repairQuote(id);
            if (reward.pending(p) < cost) continue;
            paid += reward.spend(p, cost);
            inventory.maintain(id, 10000, x.overclock);
        }
    }

    function averageDaily() public view returns (uint256) {
        return Math.max(FARM_FLOOR, rewards().lastAverageDaily());
    }

    function auctionQuote(uint256 start) external view returns (uint256) {
        if (start == 0 || start > block.timestamp) revert NotConfigured();
        uint256 elapsed = Math.min(block.timestamp - start, 7 days);
        return averageDaily() * (70 days - 8 * elapsed) / (7 days);
    }

    function farmDaily(address p) public view returns (uint256) {
        return Math.max(FARM_FLOOR, rewards().lastFarmDaily(p));
    }

    function itemDaily(uint256 id) public view returns (uint256) {
        FarmItems.Item memory x = FarmItems(registry.module(3)).data(id);
        if (x.holder == address(0)) revert InvalidValue();
        uint256 hash = ItemMath.baseHash(x.rarity) * (x.kind < 3 ? 10000 : 6000) / 10000;
        hash = hash * (10000 + EconomyMath.bonus(x.overclock)) / 10000;
        return Math.mulDiv(hash * 4, Math.max(HASH_RATE_FLOOR, rewards().lastYieldPerHash()), 1 ether);
    }

    function repairQuote(uint256 id) public view returns (uint256) {
        FarmItems.Item memory x = FarmItems(registry.module(3)).data(id);
        uint256 missing = 10000 - x.durability;
        return Math.mulDiv(
            itemDaily(id),
            missing * Params(registry.params()).get(Params.Key.RepairHours),
            24000 ether,
            Math.Rounding.Ceil
        );
    }

    function enhanceQuote(uint256 id) external view returns (uint256) {
        FarmItems.Item memory x = FarmItems(registry.module(3)).data(id);
        (,,, uint256 daysWad) = EconomyMath.enhancement(x.overclock + 1);
        return Math.mulDiv(itemDaily(id), daysWad, 1 ether, Math.Rounding.Ceil);
    }

    function roomQuote(address p, uint256 room) external view returns (uint256) {
        if (room == 0 || room > 3) revert InvalidValue();
        return farmDaily(p) * (room == 1 ? 2 : room == 2 ? 5 : 10);
    }

    /// @notice Reverts while Civic feature 4 (locks, district stake, lobby) is disabled, so Core's lobby reverts too.
    function lobbyQuote(address p) external view returns (uint256) {
        if (!IFeatureFlags(registry.module(12)).enabled(4)) revert FeatureDisabled();
        return farmDaily(p);
    }

    function lockQuote(address p, uint256 days_) public view returns (uint256 amount, uint256 bps) {
        if (days_ == 7) return (farmDaily(p) * 5, 500);
        if (days_ == 14) return (farmDaily(p) * 10, 1000);
        if (days_ == 30) return (farmDaily(p) * 20, 2000);
        revert InvalidValue();
    }

    function district(address p) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(p))) % 8;
    }

    /// @notice Disabled until Civic feature 4 is enabled (v3.6 phased release). Unlock is never gated.
    function lock(uint256 amount, uint256 days_) external nonReentrant {
        if (!IFeatureFlags(registry.module(12)).enabled(4)) revert FeatureDisabled();
        IEconomyCore(registry.module(2)).syncFor(msg.sender);
        if (locks[msg.sender].amount != 0) revert AlreadyDone();
        (uint256 minimum, uint256 bps) = lockQuote(msg.sender, days_);
        if (amount < minimum) revert InvalidValue();
        locks[msg.sender] = Lock(amount, uint64(block.timestamp), uint64(block.timestamp + days_ * 1 days), uint16(bps));
        uint256 d = district(msg.sender);
        districtTotal[d] += amount;
        totalLocked += amount;
        _insert(d, msg.sender);
        IERC20 t = IERC20(registry.token());
        uint256 before_ = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        if (t.balanceOf(address(this)) - before_ != amount) revert InvalidValue();
        IEconomyCore(registry.module(2)).syncFor(msg.sender);
        emit Locked(msg.sender, amount, block.timestamp + days_ * 1 days, bps);
    }

    function unlock() external nonReentrant {
        Lock memory l = locks[msg.sender];
        if (l.amount == 0 || block.timestamp < l.end) revert TooEarly();
        IEconomyCore(registry.module(2)).syncFor(msg.sender);
        delete locks[msg.sender];
        districtTotal[district(msg.sender)] -= l.amount;
        totalLocked -= l.amount;
        address before_ = previous[msg.sender];
        address after_ = next[msg.sender];
        if (before_ == address(0)) head[district(msg.sender)] = after_;
        else next[before_] = after_;
        if (after_ != address(0)) previous[after_] = before_;
        delete previous[msg.sender];
        delete next[msg.sender];
        IEconomyCore(registry.module(2)).syncFor(msg.sender);
        IERC20(registry.token()).safeTransfer(msg.sender, l.amount);
        emit Unlocked(msg.sender, l.amount);
    }

    function _insert(uint256 d, address p) private {
        address cursor = head[d];
        address prev;
        // User pays for insertion only. Epoch snapshots inspect at most the top ten wallets, so the walk is
        // bounded to MAX_INSERT_STEPS (v3.14): a flooded district costs at most 32 steps and the sorted prefix
        // that districtStake reads stays exact.
        uint256 steps;
        while (cursor != address(0) && locks[cursor].amount >= locks[p].amount && steps < MAX_INSERT_STEPS) {
            prev = cursor;
            cursor = next[cursor];
            ++steps;
        }
        previous[p] = prev;
        next[p] = cursor;
        if (prev == address(0)) head[d] = p;
        else next[prev] = p;
        if (cursor != address(0)) previous[cursor] = p;
    }

    function districtStake(uint256 d) public view returns (uint256 counted) {
        counted = districtTotal[d];
        uint256 cap = counted / 10;
        address p = head[d];
        for (uint256 i; i < 10 && p != address(0); ++i) {
            uint256 amount = locks[p].amount;
            if (amount <= cap) break;
            counted -= amount - cap;
            p = next[p];
        }
    }

    function boostAt(address p, uint256 timestamp) external view returns (uint256) {
        Lock memory l = locks[p];
        return timestamp >= l.start && timestamp < l.end ? l.bonus : 0;
    }

    function stakeOf(address p) public view returns (uint256) {
        return Math.min(locks[p].amount, districtTotal[district(p)] / 10);
    }
}
