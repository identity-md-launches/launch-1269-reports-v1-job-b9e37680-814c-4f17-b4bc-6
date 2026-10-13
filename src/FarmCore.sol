// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GameModule} from "./lib/GameModule.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RewardPool} from "./RewardPool.sol";
import {FarmEngine} from "./FarmEngine.sol";
import {FarmItems} from "./FarmItems.sol";
import {Params} from "./Params.sol";
import {GridOperator} from "./GridOperator.sol";
import {Economy} from "./Economy.sol";
import {Enhancement} from "./Enhancement.sol";
import {FeeRouter} from "./FeeRouter.sol";
import {EconomyMath} from "./lib/EconomyMath.sol";
import {ItemMath} from "./lib/ItemMath.sol";
import {IMarket} from "./interfaces/Interfaces.sol";
import {IRewards, ISeason} from "./interfaces/IGame.sol";
import "./lib/Errors.sol";

interface ITokenPacks {
    function tokenPack(address p) external returns (uint256);
    function price() external view returns (uint256);
}

contract FarmCore is GameModule, ReentrancyGuard, IERC1155Receiver {
    using SafeERC20 for IERC20;

    struct Farm {
        uint64 born;
        uint64 serial;
        uint64 activeEpoch;
        uint64 theftUntil;
        uint64 activeTheftUntil;
        uint64 cableRepairedEpoch;
        uint16 routerRepairBps;
        uint256 xp;
        uint256 paid;
        uint256[24] loadout;
        uint256[24] active;
        uint8[24] clocks;
        uint16[24] health;
        bool activePaid;
        uint256 drops;
        uint64 paidXpDay;
        uint256 paidXpToday;
        uint16 activeBoost;
    }

    /// @notice Paid XP (packs and spending) per farm per UTC day. Activity XP is not capped.
    uint256 public constant PAID_XP_PER_DAY = 400;

    mapping(address => mapping(uint256 => bytes32)) private dropSeeds;
    mapping(address => Farm) private farms;
    address[] private players;
    mapping(address => uint256) private minerIndex;
    uint64 private nextSerial = 1;
    event Retired(address indexed player);
    event Registered(address indexed player, uint256 district);
    event Placed(address indexed player, uint256 indexed id, uint256 room, uint256 slot);
    event Unplaced(address indexed player, uint256 indexed id, uint256 room, uint256 slot);
    event Spent(address indexed player, uint8 kind, uint256 paid, uint256 nominal);
    event Scrapped(address indexed player, uint256 indexed id, uint256 earned);
    event Active(address indexed player, uint256 indexed epoch, uint256 gross, uint256 net);

    mapping(address => mapping(uint256 => bool)) public purchasedRoom;
    mapping(address => uint16) public autoRepairThreshold;
    event AutoRepairSet(address indexed player, uint256 threshold);
    event RoomPurchased(address indexed player, uint256 room, uint256 price);

    function economy() public view returns (Economy) {
        return Economy(registry.module(10));
    }

    function enhancement() public view returns (Enhancement) {
        return Enhancement(registry.module(11));
    }

    function _boost(address p, uint256 at) private view returns (uint256) {
        return economy().boostAt(p, at);
    }

    function civicPurchase(address p, uint256 cost) external nonReentrant {
        if (msg.sender != registry.module(12)) revert Unauthorized();
        _prepare(p);
        farms[p].paid++;
        _paidXp(p, 25);
        _sync(p);
        season().recordSpend(p, cost, true);
    }

    function syncFor(address p) external nonReentrant {
        if (msg.sender != registry.module(10)) revert Unauthorized();
        _prepare(p);
    }

    function buyRoom(uint256 room, bool wallet) external nonReentrant {
        _prepare(msg.sender);
        if (room == 0 || room > 3 || !roomEligible(msg.sender, room) || purchasedRoom[msg.sender][room]) {
            revert InvalidValue();
        }
        uint256 price = economy().roomQuote(msg.sender, room);
        _charge(msg.sender, price, wallet, 5);
        purchasedRoom[msg.sender][room] = true;
        emit RoomPurchased(msg.sender, room, price);
    }

    function setAutoRepair(bool enabled, uint16 threshold) external nonReentrant {
        _prepare(msg.sender);
        if (threshold == 0) threshold = 8000;
        if (threshold > 10000 || threshold < 2000) revert InvalidValue();
        autoRepairThreshold[msg.sender] = enabled ? threshold : 0;
        emit AutoRepairSet(msg.sender, autoRepairThreshold[msg.sender]);
    }

    function autoRepair(address p, uint256 e) external {
        if (msg.sender != address(rewards())) revert Unauthorized();
        uint256 threshold = autoRepairThreshold[p];
        if (threshold == 0) return;
        uint256 paid = economy().autoRepair(p, threshold, farms[p].loadout);
        if (paid != 0) {
            season().recordRepair(p, (rewards().epochTime(e) - registry.launchTime()) / 7 days, paid);
            _paidXp(p, paid * 25 / economy().farmDaily(p));
            emit Spent(p, 0, paid, paid);
        }
    }

    function prepareEnhancement(address p, uint256 id, uint256 cost, bool wallet) external nonReentrant {
        if (msg.sender != address(enhancement())) revert Unauthorized();
        _prepare(p);
        FarmItems.Item memory x = items().data(id);
        if (x.holder != p || x.equipped || _locked(p, id)) revert InvalidValue();
        _charge(p, cost, wallet, 1);
    }

    constructor(address registry_) GameModule(registry_) {}

    function engine() public view returns (FarmEngine) {
        return FarmEngine(registry.module(9));
    }

    function items() public view returns (FarmItems) {
        return FarmItems(registry.module(3));
    }

    function rewards() public view returns (IRewards) {
        return IRewards(registry.module(1));
    }

    function params() public view returns (Params) {
        return Params(registry.params());
    }

    function packs() public view returns (address) {
        return registry.module(4);
    }

    function starter() public view returns (address) {
        return registry.module(5);
    }

    function market() public view returns (IMarket) {
        return IMarket(registry.market());
    }

    function grid() public view returns (GridOperator) {
        return GridOperator(registry.module(7));
    }

    function season() public view returns (ISeason) {
        return ISeason(registry.module(8));
    }

    function token() public view returns (IERC20) {
        return IERC20(registry.token());
    }

    function pool() public view returns (address) {
        return registry.module(0);
    }

    function count() external view returns (uint256) {
        return players.length;
    }

    function playerAt(uint256 i) external view returns (address) {
        return players[i];
    }

    function hasFarm(address p) external view returns (bool) {
        return farms[p].serial != 0;
    }

    function district(address p) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(p))) % 8;
    }

    function xp(address p) external view returns (uint256) {
        return farms[p].xp;
    }

    function paidPacks(address p) external view returns (uint256) {
        return farms[p].paid;
    }

    /// @notice XP level, capped by farm age: level 5 needs 1 day, level 7 needs 3 days, level 10 needs 5 days.
    function level(address p) public view returns (uint256) {
        uint256 lv = xpLevel(p);
        uint256 cap = maxLevelByAge(p);
        return lv < cap ? lv : cap;
    }

    function maxLevelByAge(address p) public view returns (uint256) {
        uint256 born = farms[p].born;
        uint256 age = born == 0 || block.timestamp < born ? 0 : block.timestamp - born;
        if (age >= 5 days) return 10;
        if (age >= 3 days) return 9;
        if (age >= 1 days) return 6;
        return 4;
    }

    /// @notice Paid XP still accepted today for this farm.
    function paidXpRoom(address p) public view returns (uint256) {
        Farm storage f = farms[p];
        if (f.paidXpDay != block.timestamp / 1 days) return PAID_XP_PER_DAY;
        return PAID_XP_PER_DAY - f.paidXpToday;
    }

    function _paidXp(address p, uint256 amount) private {
        Farm storage f = farms[p];
        uint64 today = uint64(block.timestamp / 1 days);
        if (f.paidXpDay != today) {
            f.paidXpDay = today;
            f.paidXpToday = 0;
        }
        uint256 room = PAID_XP_PER_DAY - f.paidXpToday;
        if (amount > room) amount = room;
        f.paidXpToday += amount;
        f.xp += amount;
    }

    function xpLevel(address p) public view returns (uint256) {
        uint256 x = farms[p].xp;
        if (x >= 2800) return 10;
        if (x >= 2400) return 9;
        if (x >= 2000) return 8;
        if (x >= 1600) return 7;
        if (x >= 1200) return 6;
        if (x >= 800) return 5;
        if (x >= 600) return 4;
        if (x >= 400) return 3;
        if (x >= 100) return 2;
        return 1;
    }

    function roomEligible(address p, uint256 room) public view returns (bool) {
        if (room == 0) return true;
        if (room == 1) return farms[p].born != 0 && block.timestamp >= farms[p].born + 3 days;
        if (room == 2) return level(p) >= 7;
        return room == 3 && level(p) >= 10;
    }

    function roomUnlocked(address p, uint256 room) public view returns (bool) {
        return room == 0 || (roomEligible(p, room) && purchasedRoom[p][room]);
    }

    function rooms(address p) public view returns (uint256 n) {
        n = 1;
        if (roomUnlocked(p, 1)) ++n;
        if (roomUnlocked(p, 2)) ++n;
        if (roomUnlocked(p, 3)) ++n;
    }

    function register(address p) external {
        if (msg.sender != p && msg.sender != packs() && msg.sender != starter()) revert Unauthorized();
        _register(p);
    }

    function _register(address p) private {
        if (p == address(0)) revert InvalidAddress();
        Farm storage f = farms[p];
        if (f.serial != 0) return;
        f.born = uint64(block.timestamp);
        f.serial = nextSerial++;
        rewards().initialize(p);
        emit Registered(p, district(p));
    }

    function _prepare(address p) private {
        if (!rewards().ready() || !rewards().live()) revert TooEarly();
        _register(p);
        if (rewards().settle(p, 8) < rewards().settledEpoch()) revert CatchUpRequired();
        _roll(p, rewards().epoch());
        _sync(p);
    }

    function _sync(address p) private {
        rewards()
            .setWeight(
                p,
                engine().allocationHash(farms[p].loadout, farms[p].paid != 0) * (10000 + _boost(p, block.timestamp))
                    / 10000
            );
    }

    function _roll(address p, uint256 e) private {
        Farm storage f = farms[p];
        if (f.activeEpoch >= e) return;
        f.active = f.loadout;
        f.activeEpoch = uint64(e);
        f.activePaid = f.paid != 0;
        f.activeBoost = uint16(_boost(p, rewards().epochTime(e)));
        f.activeTheftUntil = f.theftUntil;
        f.routerRepairBps = 0;
        for (uint256 i; i < 24; ++i) {
            if (f.active[i] == 0) continue;
            FarmItems.Item memory x = items().data(f.active[i]);
            f.clocks[i] = x.overclock;
            f.health[i] = x.durability;
        }
    }

    function paidPackBought(address p, uint256 n, uint256 ethValue) external nonReentrant {
        if (msg.sender != packs()) revert Unauthorized();
        _prepare(p);
        farms[p].paid += n;
        _paidXp(p, 25 * n);
        _sync(p);
        rewards().recordSales(n);
        season().recordSpend(p, ethValue, true);
    }

    /// @notice Owner heartbeat: settle and re-commit the farm for the next IDLE_EPOCHS epochs.
    function sync() external nonReentrant {
        _prepare(msg.sender);
    }

    function setReferrer(address inviter) external nonReentrant {
        _prepare(msg.sender);
        if (farms[inviter].serial == 0 || farms[inviter].serial >= farms[msg.sender].serial) revert InvalidValue();
        rewards().setReferrer(msg.sender, inviter);
    }

    function itemAt(address p, uint256 room, uint256 slot) external view returns (uint256) {
        if (room >= 4 || slot >= 6) revert InvalidValue();
        return farms[p].loadout[room * 6 + slot];
    }

    function place(uint256 id, uint256 room, uint256 slot) external nonReentrant {
        _prepare(msg.sender);
        if (!roomUnlocked(msg.sender, room) || slot >= 6) revert InvalidValue();
        Farm storage f = farms[msg.sender];
        FarmItems.Item memory x = items().data(id);
        if (x.holder != msg.sender || x.equipped || enhancement().pending(id) != 0 || f.loadout[room * 6 + slot] != 0) {
            revert InvalidValue();
        }
        uint256 lev = level(msg.sender);
        if ((x.rarity == 2 && lev < 3) || (x.rarity == 3 && lev < 5) || (x.rarity == 4 && lev < 10)) {
            revert InvalidValue();
        }
        for (uint256 i; i < 6; ++i) {
            uint256 old = f.loadout[room * 6 + i];
            if (old != 0 && items().data(old).kind == x.kind) revert InvalidValue();
        }
        if (minerIndex[msg.sender] == 0) {
            players.push(msg.sender);
            minerIndex[msg.sender] = players.length;
        }
        f.loadout[room * 6 + slot] = id;
        items().equip(msg.sender, id);
        _sync(msg.sender);
        if (rewards()
                .beginMining(
                    msg.sender,
                    engine().allocationHash(f.loadout, f.paid != 0) * (10000 + _boost(msg.sender, block.timestamp))
                        / 10000
                )) {
            // Freeze the first installed loadout for this epoch; later edits apply next epoch.
            f.activeEpoch = 0;
            _roll(msg.sender, rewards().epoch());
        }
        emit Placed(msg.sender, id, room, slot);
    }

    function unplace(uint256 room, uint256 slot) external nonReentrant {
        _prepare(msg.sender);
        if (room >= 4 || slot >= 6) revert InvalidValue();
        Farm storage f = farms[msg.sender];
        uint256 id = f.loadout[room * 6 + slot];
        if (id == 0) revert InvalidValue();
        delete f.loadout[room * 6 + slot];
        items().unequip(msg.sender, id);
        _sync(msg.sender);
        emit Unplaced(msg.sender, id, room, slot);
    }

    /// @notice Remove an empty farm from future settlement rosters; past season entitlements remain.
    function retire(address p) external nonReentrant {
        if (msg.sender != p) revert Unauthorized(); // v3.14: only the owner retires their own farm
        _prepare(p);
        Farm storage f = farms[p];
        for (uint256 i; i < 24; ++i) {
            if (f.loadout[i] != 0 || f.active[i] != 0) revert InvalidValue();
        }
        uint256 index = minerIndex[p];
        if (index == 0) revert InvalidValue();
        address last = players[players.length - 1];
        players[index - 1] = last;
        minerIndex[last] = index;
        players.pop();
        delete minerIndex[p];
        emit Retired(p);
    }

    function _locked(address p, uint256 id) private view returns (bool) {
        Farm storage f = farms[p];
        for (uint256 i; i < 24; ++i) {
            if (f.active[i] == id) return true;
        }
        return false;
    }

    function _charge(address p, uint256 nominal, bool wallet, uint8 kind) private returns (uint256 paid) {
        if (nominal == 0 || IERC20Metadata(address(token())).decimals() != 18) revert InvalidValue();
        if (wallet) {
            paid = nominal;
            uint256 before_ = token().balanceOf(pool());
            token().safeTransferFrom(p, pool(), paid);
            if (token().balanceOf(pool()) - before_ != paid) revert InvalidValue();
            RewardPool(pool()).recordInflow(paid);
        } else {
            paid = rewards().spend(p, nominal);
        }
        _paidXp(p, paid * 25 / economy().farmDaily(p));
        season().recordSpend(p, paid, kind == 0 || kind == 3 || kind == 4);
        emit Spent(p, kind, paid, nominal);
    }

    function repair(uint256 id, bool wallet) external nonReentrant {
        _prepare(msg.sender);
        FarmItems.Item memory x = items().data(id);
        if (x.holder != msg.sender || x.durability == 10000) revert InvalidValue();
        uint256 price = economy().repairQuote(id);
        _charge(msg.sender, price, wallet, 0);
        items().maintain(id, 10000, x.overclock);
    }

    function repairCable(bool wallet) external nonReentrant {
        _prepare(msg.sender);
        Farm storage f = farms[msg.sender];
        if (f.theftUntil <= rewards().epoch()) revert InvalidValue();
        _charge(msg.sender, economy().farmDaily(msg.sender) / 4, wallet, 0);
        f.theftUntil = 0;
        f.cableRepairedEpoch = uint64(rewards().epoch());
        f.routerRepairBps = uint16((rewards().epochEnd() - block.timestamp) * 10000 / 6 hours);
    }

    /// @notice Removed in v3.5: use Enhancement.commit and resolve.
    function overclock(uint256, bool) external pure {
        revert InvalidValue();
    }

    function expand(bool wallet) external nonReentrant {
        _prepare(msg.sender);
        uint256 n = items().expansions(msg.sender);
        uint256 price = economy().farmDaily(msg.sender) * (n + 1) * (n + 1);
        _charge(msg.sender, price, wallet, 2);
        items().expand(msg.sender);
    }

    function buyTokenPack(bool wallet) external nonReentrant returns (uint256 id) {
        _prepare(msg.sender);
        uint256 price = ITokenPacks(packs()).price();
        _splitCharge(msg.sender, price, wallet);
        farms[msg.sender].paid++;
        _sync(msg.sender);
        _paidXp(msg.sender, 25);
        rewards().recordSales(1);
        season().recordSpend(msg.sender, price, true);
        id = ITokenPacks(packs()).tokenPack(msg.sender);
    }

    function _splitCharge(address p, uint256 amount, bool wallet) private {
        address router = registry.module(6);
        if (wallet) {
            uint256 before_ = token().balanceOf(router);
            token().safeTransferFrom(p, router, amount);
            if (token().balanceOf(router) - before_ != amount) revert InvalidValue();
        } else {
            rewards().spendTo(p, amount, router);
        }
        FeeRouter(payable(router)).routeTokens(amount);
    }

    function lobby(uint256 amount, bool wallet) external nonReentrant {
        _prepare(msg.sender);
        if (amount < economy().lobbyQuote(msg.sender)) revert InvalidValue();
        _splitCharge(msg.sender, amount, wallet);
        season().recordSpend(msg.sender, amount, true);
        grid().tokenLobby(msg.sender, amount);
    }

    function scrap(uint256 id, uint256 minimum) external nonReentrant {
        _prepare(msg.sender);
        FarmItems.Item memory x = items().data(id);
        if (
            x.holder != msg.sender || x.equipped || _locked(msg.sender, id) || enhancement().pending(id) != 0
                || (x.starter && farms[msg.sender].paid == 0)
        ) revert InvalidValue();
        uint256 hash = ItemMath.baseHash(x.rarity) * (x.kind < 3 ? 10000 : 6000) / 10000 * x.durability / 10000;
        items().destroy(id);
        uint256 earned = rewards().scrap(msg.sender, hash, minimum);
        emit Scrapped(msg.sender, id, earned);
    }

    function roomStats(address p, uint256 room) external view returns (FarmEngine.RoomStats memory) {
        Farm storage f = farms[p];
        return engine().preview(f.loadout, f.theftUntil, room);
    }

    function process(address p, uint256 e) external returns (uint256 raw, uint256 productive, uint256 power) {
        if (msg.sender != address(rewards())) revert Unauthorized();
        if (rewards().farmWeight(p, e) == 0) return (0, 0, 0);
        _roll(p, e);
        Farm storage f = farms[p];
        bool occupied;
        for (uint256 i; i < 24; ++i) {
            if (f.active[i] != 0) {
                occupied = true;
                break;
            }
        }
        if (!occupied) return (0, 0, 0);
        FarmEngine.Snapshot memory snap =
            FarmEngine.Snapshot(f.active, f.clocks, f.health, f.activePaid, f.activeTheftUntil, f.routerRepairBps);
        uint64 theftUntil;
        (raw, productive, power, theftUntil) = engine().process(p, e, snap);
        raw = raw * (10000 + f.activeBoost) / 10000;
        productive = productive * (10000 + f.activeBoost) / 10000;
        power = power * (10000 + f.activeBoost) / 10000;
        f.theftUntil = f.cableRepairedEpoch == e && theftUntil == f.activeTheftUntil ? 0 : theftUntil;
        for (uint256 i; i < 24; ++i) {
            uint256 id = f.active[i];
            if (id != 0 && items().data(id).holder == address(0)) _remove(f, id);
        }
    }

    function _remove(Farm storage f, uint256 id) private {
        for (uint256 i; i < 24; ++i) {
            if (f.loadout[i] == id) delete f.loadout[i];
            if (f.active[i] == id) delete f.active[i];
        }
    }

    function activity(address p, uint256 e, uint256 gross, uint256 net) external {
        if (msg.sender != address(rewards())) revert Unauthorized();
        farms[p].xp += 100;
        emit Active(p, e, gross, net);
    }

    function grantDrop(address p, bytes32 seed) external {
        if (msg.sender != address(rewards())) revert Unauthorized();
        dropSeeds[p][farms[p].drops++] = seed;
    }

    function drops(address p) external view returns (uint256) {
        return farms[p].drops;
    }

    function claimDrop() external nonReentrant returns (uint256 id) {
        Farm storage f = farms[msg.sender];
        if (f.drops == 0) revert InsufficientBalance();
        f.drops--;
        bytes32 seed = dropSeeds[msg.sender][f.drops];
        delete dropSeeds[msg.sender][f.drops];
        id = items().mintDrop(msg.sender, seed);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(items())) revert Unauthorized();
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert Unauthorized();
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC1155Receiver).interfaceId || id == 0x01ffc9a7;
    }
}
