// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GameModule} from "./lib/GameModule.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Params} from "./Params.sol";
import {RewardPool} from "./RewardPool.sol";
import {FeeRouter} from "./FeeRouter.sol";
import {GridOperator} from "./GridOperator.sol";
import {ICore, ISeason} from "./interfaces/IGame.sol";
import "./lib/Errors.sol";

/// @notice Global epochs never visit farms. Anyone may settle one farm in bounded, unpaid batches.
contract FarmRewards is GameModule, ReentrancyGuard {
    uint256 public constant EPOCH = 6 hours;
    uint256 public constant MAX_SETTLE = 8;
    uint256 public constant PRECISION = 1e27;
    /// @notice A commitment stays in the global denominator for this many epochs after the last owner action.
    uint256 public constant IDLE_EPOCHS = 12;

    struct Epoch {
        uint64 start;
        uint64 end;
        uint256 raw; // Committed hash-time, including pro-rata first-entry snapshots.
        uint256 miningSeconds; // No emission for the empty prefix of an epoch.
        uint256 budget;
        uint256 mining;
        uint256 redis;
        uint256 spent;
        uint256 sales;
        uint256 target;
        uint256 tariff;
        uint256 emission;
        uint256 auditThreshold;
        uint256 rewardPerHash;
        uint256 accRewardPerHash;
        uint256 settledHash;
        uint256 allocated;
        uint256 scrap;
        GridOperator.Kind kind;
        uint16 severity;
        uint8 district;
        bytes32 seed;
    }

    struct Share {
        uint256 raw;
        uint256 productive;
        uint256 power;
        bool audit;
    }

    struct Vintage {
        uint64 epoch;
        uint64 at;
        uint256 amount;
    }

    struct Account {
        uint256 lastSettled;
        uint256 weight;
        uint256 nextWeight;
        uint256 weightEpoch;
        uint256 weightExpiry; // First epoch in which `weight` no longer counts.
        uint256 nextExpiry; // First epoch in which `nextWeight` no longer counts.
        bool initialized;
        uint256 pending;
        uint256 matured;
        address referrer;
        bool referralClosed;
        Vintage[32] vintages;
    }

    uint256 public epoch;
    uint256 public settledEpoch;
    uint256 public queuedTax;
    uint256 public currentRedis;
    uint256 public lastYieldPerHash;
    uint256 public lastAverageDaily;
    mapping(address => uint256) public lastFarmDaily;
    uint256 public nextActiveFarms;
    mapping(uint256 => uint256) public districtActiveHash;
    mapping(uint256 => uint256) public nextDistrictHash;
    mapping(uint256 => mapping(uint256 => uint256)) public expiringDistrictHash;
    mapping(uint256 => uint256) public expiringFarms;
    mapping(uint256 => uint256) public activeFarmCount;
    uint256 public constant MAX_OUTPUT_BPS = 15000;
    uint256 public scrapAllowance;
    /// @dev Read through `epochData`: a 21-field public getter does not compile without via-IR.
    mapping(uint256 => Epoch) private epochs;
    mapping(uint256 => mapping(uint256 => uint256)) public epochParam;
    mapping(uint256 => mapping(address => Share)) public shares;
    uint256 public nextTotalHash;
    uint256 public accRewardPerHash;
    mapping(uint256 => uint256) public lastEpochInWeek;
    mapping(address => Account) private accounts;
    /// @notice Committed hash that leaves the denominator when epoch `id` starts.
    mapping(uint256 => uint256) public expiring;
    mapping(uint256 => mapping(address => uint256)) public entryWeight;
    mapping(uint256 => mapping(address => uint256)) public entrySeconds;
    event MiningStarted(address indexed player, uint256 indexed epoch, uint256 secondsLeft, uint256 weight);
    event Committed(address indexed player, uint256 weight, uint256 fromEpoch, uint256 expiresAt);
    event Expired(uint256 indexed epoch, uint256 hash);
    event EpochStarted(uint256 indexed epoch, uint256 start, uint256 end, address caller);
    event EpochClosed(uint256 indexed epoch, uint256 budget, uint256 roster);
    event EpochSettled(uint256 indexed epoch, uint256 mining, uint256 recycled);
    event Credited(address indexed player, uint256 indexed epoch, uint256 amount);
    event Claimed(address indexed player, uint256 amount, uint256 tax);
    event Spent(address indexed player, uint256 consumed);
    event ReferrerSet(address indexed player, address indexed referrer);

    constructor(address registry_) GameModule(registry_) {}

    function params() public view returns (Params) {
        return Params(registry.params());
    }

    function pool() public view returns (RewardPool) {
        return RewardPool(registry.module(0));
    }

    function core() public view returns (ICore) {
        return ICore(registry.module(2));
    }

    function grid() public view returns (GridOperator) {
        return GridOperator(registry.module(7));
    }

    function fees() public view returns (FeeRouter) {
        return FeeRouter(payable(registry.module(6)));
    }

    function season() public view returns (ISeason) {
        return ISeason(registry.module(8));
    }

    function launchTime() public view returns (uint256) {
        return registry.launchTime();
    }
    modifier onlyCore() {
        if (msg.sender != address(core())) revert Unauthorized();
        _;
    }

    function ready() public view returns (bool) {
        return true;
    }

    function live() public view returns (bool) {
        return epoch != 0 && block.timestamp < epochs[epoch].end;
    }

    function epochStart() external view returns (uint256) {
        return epochs[epoch].start;
    }

    function epochEnd() external view returns (uint256) {
        return epochs[epoch].end;
    }

    function advanceEpoch() external nonReentrant {
        if (block.timestamp < launchTime() || (epoch != 0 && block.timestamp < epochs[epoch].end)) revert TooEarly();
        if (scrapAllowance != 0) {
            pool().recycle(scrapAllowance);
            scrapAllowance = 0;
        }
        if (epoch != 0) {
            grid().resolveFor(epoch, msg.sender);
            Epoch storage old = epochs[epoch];
            (old.kind, old.severity, old.district, old.seed,) = grid().eventAt(epoch);
            old.redis = currentRedis;
            uint256 week = (old.start - launchTime()) / 7 days;
            lastEpochInWeek[week] = epoch;
            if (old.raw != 0) {
                old.mining = Math.mulDiv(pool().available(), old.emission * old.miningSeconds, 40000 * EPOCH);
                // 110% Green gross + 5% referral + 1% season = 116.5% maximum, before tariff.
                old.budget = old.mining * 159 / 100;
                pool().reserve(old.budget);
                old.rewardPerHash = Math.mulDiv(old.mining, PRECISION, old.raw);
                accRewardPerHash += old.rewardPerHash;
                old.accRewardPerHash = accRewardPerHash;
                uint256 prize = old.mining / 100;
                old.spent = prize;
                old.allocated = prize;
                if (prize != 0) season().addPrize(week, prize);
                lastYieldPerHash = Math.mulDiv(old.mining * (10000 - old.tariff) / 10000, 1 ether, old.raw);
                if (activeFarmCount[epoch] != 0) {
                    lastAverageDaily = old.mining * (10000 - old.tariff) / 10000 * 4 / activeFarmCount[epoch];
                }
            } else {
                queuedTax += old.redis;
                old.redis = 0;
                old.accRewardPerHash = accRewardPerHash;
                // Preserve the last settled productive rate across empty epochs.
            }
            settledEpoch = epoch; // Globally closed; individual farm cursors are independent.
            emit EpochClosed(epoch, old.budget, old.raw);
        }
        epoch++;
        Epoch storage e = epochs[epoch];
        e.start = uint64(block.timestamp);
        e.end = uint64(block.timestamp + EPOCH);
        uint256 gone = expiring[epoch];
        if (gone != 0) {
            // O(1): one bucket per epoch, filled by owner actions, never a farm loop.
            nextTotalHash -= gone;
            delete expiring[epoch];
            emit Expired(epoch, gone);
        }
        for (uint256 d; d < 8; ++d) {
            nextDistrictHash[d] -= expiringDistrictHash[epoch][d];
            delete expiringDistrictHash[epoch][d];
            districtActiveHash[d] = nextDistrictHash[d];
        }
        nextActiveFarms -= expiringFarms[epoch];
        delete expiringFarms[epoch];
        activeFarmCount[epoch] = nextActiveFarms;
        e.raw = nextTotalHash;
        if (e.raw != 0) e.miningSeconds = EPOCH;
        e.target = params().get(Params.Key.DemandTarget) * 6;
        e.tariff = params().get(Params.Key.TariffBps);
        e.emission = params().get(Params.Key.EmissionBps);
        e.auditThreshold = params().get(Params.Key.AuditHashThreshold);
        for (uint256 k = uint256(Params.Key.FullSetBps); k <= uint256(Params.Key.SetCapBps); ++k) {
            epochParam[epoch][k] = params().get(Params.Key(k));
        }
        currentRedis = queuedTax;
        queuedTax = 0;
        grid().shift(epoch);
        fees().payBounty(msg.sender);
        emit EpochStarted(epoch, e.start, e.end, msg.sender);
    }

    function epochData(uint256 id) external view returns (Epoch memory) {
        return epochs[id];
    }

    function eventAt(uint256 id) external view returns (GridOperator.Kind, uint16, uint8, bytes32, bool) {
        Epoch storage e = epochs[id];
        return (e.kind, e.severity, e.district, e.seed, id != 0 && id <= settledEpoch);
    }

    function recordSales(uint256 n) external onlyCore {
        if (!live()) revert TooEarly();
        epochs[epoch].sales += n;
    }

    function initialize(address p) external onlyCore {
        Account storage a = accounts[p];
        if (a.initialized) revert AlreadyDone();
        a.initialized = true;
        a.lastSettled = epoch == 0 ? 0 : epoch - 1;
    }

    /// @dev Owner configuration changes take effect next epoch. Settlement alone never changes weights.
    /// @dev Every owner action re-commits the farm for IDLE_EPOCHS epochs starting next epoch.
    function setWeight(address p, uint256 weight) external onlyCore {
        Account storage a = accounts[p];
        if (!a.initialized || a.lastSettled < settledEpoch) revert CatchUpRequired();
        _commit(a, p, weight);
    }

    function _commit(Account storage a, address p, uint256 weight) private {
        uint256 d = uint256(keccak256(abi.encodePacked(p))) % 8;
        if (a.weightEpoch <= epoch) {
            a.weight = a.nextWeight;
            a.weightExpiry = a.nextExpiry;
        }
        // Buckets for epochs <= current have already been applied; later buckets still hold this commitment.
        if (a.nextExpiry > epoch) {
            if (a.nextWeight != 0) {
                --nextActiveFarms;
                --expiringFarms[a.nextExpiry];
            }
            nextDistrictHash[d] -= a.nextWeight;
            expiringDistrictHash[a.nextExpiry][d] -= a.nextWeight;
            nextTotalHash -= a.nextWeight;
            expiring[a.nextExpiry] -= a.nextWeight;
        }
        uint256 expiry = epoch + 1 + IDLE_EPOCHS;
        if (weight != 0) {
            ++nextActiveFarms;
            ++expiringFarms[expiry];
        }
        nextDistrictHash[d] += weight;
        expiringDistrictHash[expiry][d] += weight;
        nextTotalHash += weight;
        expiring[expiry] += weight;
        a.nextWeight = weight;
        a.nextExpiry = expiry;
        a.weightEpoch = epoch + 1;
        emit Committed(p, weight, epoch + 1, expiry);
    }

    /// @notice Admit a farm's first productive snapshot immediately, weighted by remaining epoch time.
    /// Later loadout changes retain the existing next-epoch rule; a wallet cannot replace this snapshot.
    function beginMining(address p, uint256 weight) external onlyCore returns (bool) {
        if (!live() || weight == 0 || farmWeight(p, epoch) != 0 || entrySeconds[epoch][p] != 0) return false;
        uint256 secondsLeft = epochs[epoch].end - block.timestamp;
        uint256 weighted = Math.mulDiv(weight, secondsLeft, EPOCH);
        if (weighted == 0) return false;
        if (epochs[epoch].raw == 0) epochs[epoch].miningSeconds = secondsLeft;
        entryWeight[epoch][p] = weighted;
        entrySeconds[epoch][p] = secondsLeft;
        epochs[epoch].raw += weighted;
        ++activeFarmCount[epoch];
        districtActiveHash[uint256(keccak256(abi.encodePacked(p))) % 8] += weighted;
        emit MiningStarted(p, epoch, secondsLeft, weighted);
        return true;
    }

    /// @notice Weight counted in epoch `e`'s denominator; zero once the farm has been idle for IDLE_EPOCHS.
    function farmWeight(address p, uint256 e) public view returns (uint256) {
        if (entrySeconds[e][p] != 0) return entryWeight[e][p];
        Account storage a = accounts[p];
        if (e >= a.weightEpoch) return e < a.nextExpiry ? a.nextWeight : 0;
        return e < a.weightExpiry ? a.weight : 0;
    }

    /// @notice Configured allocation hash, whether or not it is currently committed.
    function configuredWeight(address p) external view returns (uint256) {
        return accounts[p].nextWeight;
    }

    /// @notice First epoch in which the farm's latest commitment no longer counts.
    function expiresAt(address p) external view returns (uint256) {
        return accounts[p].nextExpiry;
    }

    function committed(address p) external view returns (bool) {
        Account storage a = accounts[p];
        return a.nextWeight != 0 && a.nextExpiry > epoch + 1;
    }

    function lastSettled(address p) external view returns (uint256) {
        return accounts[p].lastSettled;
    }

    /// @notice No bounty; catch-up is paid by the player or a voluntary sponsor. Mining never expires.
    function settle(address p, uint256 limit) external nonReentrant returns (uint256 cursor) {
        return _settle(p, limit);
    }

    function _settle(address p, uint256 limit) private returns (uint256 cursor) {
        if (limit == 0 || limit > MAX_SETTLE) revert InvalidValue();
        Account storage a = accounts[p];
        if (!a.initialized) return settledEpoch;
        cursor = a.lastSettled;
        for (uint256 n; n < limit && cursor < settledEpoch; ++n) {
            ++cursor;
            a.lastSettled = cursor; // CEI and monotonically increasing, including zero-yield epochs.
            _settleOne(p, cursor);
        }
    }

    function _settleOne(address p, uint256 id) private {
        Epoch storage e = epochs[id];
        (uint256 raw, uint256 productive, uint256 power) = core().process(p, id);
        bool audit = e.kind == GridOperator.Kind.Audit && raw > e.auditThreshold;
        uint256 weight = farmWeight(p, id);
        uint256 secondsLeft = entrySeconds[id][p];
        if (secondsLeft != 0) {
            raw = Math.mulDiv(raw, secondsLeft, EPOCH);
            productive = Math.mulDiv(productive, secondsLeft, EPOCH);
            power = Math.mulDiv(power, secondsLeft, EPOCH);
            // Integer hash-time rounding must retain the same envelope as the reservation formula.
            uint256 limit = weight * MAX_OUTPUT_BPS / 10000;
            if (productive > limit) {
                power = Math.mulDiv(power, limit, productive);
                productive = limit;
            }
        }
        Share memory sh = Share(raw, productive, power, audit);
        shares[id][p] = sh;
        uint256 week = (e.start - launchTime()) / 7 days;
        if (weight != 0) _reward(p, id, sh, weight, week);
        // Only a complete week's yield may compete for spend/yield prizes; partial settlement cannot win.
        if (id == lastEpochInWeek[week] && epochs[epoch].start >= launchTime() + (week + 1) * 7 days) {
            season().complete(p, week);
        }
    }

    struct Payout {
        uint256 gross;
        uint256 net;
        uint256 redis;
        uint256 referral;
        uint256 allocation;
    }

    function _payout(address p, Epoch storage e, Share memory sh, uint256 weight)
        private
        view
        returns (Payout memory o)
    {
        o.gross = Math.mulDiv(e.rewardPerHash, sh.productive, PRECISION);
        uint256 electricity = Math.mulDiv(e.rewardPerHash, sh.power, PRECISION) * e.tariff / 10000;
        if (e.kind == GridOperator.Kind.Cheap && uint256(keccak256(abi.encodePacked(p))) % 8 == e.district) {
            electricity /= 2;
        }
        uint256 tax = sh.audit ? o.gross / 10 : 0;
        o.net = o.gross - tax - Math.min(electricity, o.gross - tax);
        o.redis = Math.mulDiv(e.redis, Math.min(sh.productive, weight), e.raw);
        // Use the same rounding as actual gross. Flooring a global envelope before
        // apportionment can otherwise underfund a farm by one wei and lock its cursor.
        uint256 maxGross = Math.mulDiv(e.rewardPerHash, weight * MAX_OUTPUT_BPS / 10000, PRECISION);
        o.allocation = maxGross + maxGross * 500 / 10000 + Math.mulDiv(e.redis, weight, e.raw);
    }

    function _reward(address p, uint256 id, Share memory sh, uint256 weight, uint256 week) private {
        Epoch storage e = epochs[id];
        Payout memory o = _payout(p, e, sh, weight);
        Account storage a = accounts[p];
        a.referralClosed = true;
        if (a.referrer != address(0)) {
            o.referral = o.gross * 500 / 10000;
            _credit(a.referrer, o.referral, id, e.end);
        }
        uint256 spent = o.net + o.redis + o.referral;
        // Protocol maximum district/event boosts bound productive hash by 150% of committed allocation hash.
        if (spent > o.allocation) revert InvalidValue();
        _credit(p, o.net + o.redis, id, e.end);
        lastFarmDaily[p] = o.net * 4;
        core().autoRepair(p, id);
        e.spent += spent;
        e.allocated += o.allocation;
        e.settledHash += weight;
        _recycle(e, id, o.allocation - spent);
        if (sh.raw != 0) {
            core().activity(p, id, o.gross, o.net);
            if (e.sales >= 2 * e.target && uint256(keccak256(abi.encode(e.seed, p, "supply"))) % 10000 < 500) {
                core().grantDrop(p, keccak256(abi.encode(e.seed, p, "item")));
            }
            season().recordActivity(p, week, o.gross, weight);
        }
    }

    function _recycle(Epoch storage e, uint256 id, uint256 unused) private {
        if (id == settledEpoch) {
            uint256 allowance = Math.min(unused, e.mining / 6 - e.scrap);
            e.scrap += allowance;
            scrapAllowance += allowance;
            unused -= allowance;
        }
        if (unused != 0) pool().recycle(unused);
        if (e.settledHash == e.raw) {
            uint256 dust = e.budget + e.redis - e.allocated;
            if (dust != 0) pool().recycle(dust);
            emit EpochSettled(id, e.spent, dust);
        }
    }

    function pending(address p) external view returns (uint256) {
        return accounts[p].pending;
    }

    function referrer(address p) external view returns (address) {
        return accounts[p].referrer;
    }

    function setReferrer(address p, address ref) external onlyCore {
        Account storage a = accounts[p];
        if (a.referrer != address(0) || a.referralClosed) revert AlreadyDone();
        if (p == ref || !core().hasFarm(ref)) revert InvalidValue();
        a.referrer = ref;
        emit ReferrerSet(p, ref);
    }

    function _credit(address p, uint256 amount, uint256 e, uint256 at) private {
        if (amount == 0) return;
        Account storage a = accounts[p];
        a.pending += amount;
        // Referrals can arrive out of epoch order. Never evict a younger, still-taxable vintage.
        if (block.timestamp >= at + 7 days) {
            a.matured += amount;
            emit Credited(p, e, amount);
            return;
        }
        Vintage storage v = a.vintages[e % 32];
        if (v.amount != 0 && v.epoch != e) {
            a.matured += v.amount;
            v.amount = 0;
        }
        v.epoch = uint64(e);
        if (v.amount == 0 || at < v.at) v.at = uint64(at); // v3.14: a later credit never delays the earlier one
        v.amount += amount;
        emit Credited(p, e, amount);
    }

    function taxBps(uint256 age) public pure returns (uint256) {
        return age >= 7 days ? 500 : 2000 - 1500 * age / 7 days;
    }

    function _consume(address p, uint256 amount, bool taxed) private returns (uint256 tax) {
        Account storage a = accounts[p];
        if (amount == 0 || amount > a.pending) revert InsufficientBalance();
        a.pending -= amount;
        // Sparse credits can leave an old slot behind the current ring head.
        // Sweep by actual age before consuming any higher-tax vintage.
        for (uint256 n; n < 32; ++n) {
            Vintage storage old = a.vintages[n];
            if (old.amount != 0 && block.timestamp >= uint256(old.at) + 7 days) {
                a.matured += old.amount;
                old.amount = 0;
            }
        }
        uint256 used = Math.min(amount, a.matured);
        a.matured -= used;
        amount -= used;
        if (taxed) tax = used * 500 / 10000;
        uint256 first = epoch > 31 ? epoch - 31 : 0;
        // Old slots are consumed before newer slots; all skipped generations have matured.
        for (uint256 n; n < 32 && amount != 0; ++n) {
            Vintage storage v = a.vintages[(first + n) % 32];
            if (v.amount == 0) continue;
            used = Math.min(amount, v.amount);
            v.amount -= used;
            amount -= used;
            if (taxed) tax += used * taxBps(block.timestamp > v.at ? block.timestamp - v.at : 0) / 10000;
        }
        assert(amount == 0);
    }

    function claim(uint256 amount) external nonReentrant returns (uint256 net) {
        _settle(msg.sender, MAX_SETTLE);
        Account storage a = accounts[msg.sender];
        // Claim is an owner action: re-commit when fully caught up. Never blocks the withdrawal.
        if (a.initialized && a.lastSettled >= settledEpoch && a.nextWeight != 0) _commit(a, msg.sender, a.nextWeight);
        uint256 tax = _consume(msg.sender, amount, true);
        queuedTax += tax;
        net = amount - tax;
        pool().pay(msg.sender, net);
        emit Claimed(msg.sender, amount, tax);
    }

    function spend(address p, uint256 nominal) external returns (uint256 consumed) {
        if (msg.sender != address(core()) && msg.sender != registry.module(10)) revert Unauthorized();
        consumed = nominal;
        _consume(p, consumed, false);
        pool().recycle(consumed);
        emit Spent(p, consumed);
    }

    function epochTime(uint256 e) external view returns (uint256) {
        return epochs[e].start;
    }

    function spendTo(address p, uint256 amount, address to) external onlyCore {
        if (to != registry.module(6)) revert Unauthorized();
        _consume(p, amount, false);
        pool().pay(to, amount);
        emit Spent(p, amount);
    }

    function scrap(address p, uint256 hash, uint256 minimum) external onlyCore nonReentrant returns (uint256 amount) {
        amount = Math.mulDiv(hash, lastYieldPerHash, 6 ether);
        amount = Math.min(amount, scrapAllowance);
        if (amount < minimum) revert InsufficientBalance();
        scrapAllowance -= amount;
        if (amount != 0) _credit(p, amount, epoch, block.timestamp);
    }

    function seasonReady(uint256 week) external view returns (bool) {
        return epoch != 0 && epochs[epoch].start >= launchTime() + (week + 1) * 7 days;
    }

    function releasePrize(uint256 amount) external nonReentrant {
        if (msg.sender != address(season())) revert Unauthorized();
        pool().recycle(amount);
    }

    function award(address p, uint256 amount) external nonReentrant {
        if (msg.sender != address(season())) revert Unauthorized();
        _credit(p, amount, epoch, block.timestamp);
    }
}
