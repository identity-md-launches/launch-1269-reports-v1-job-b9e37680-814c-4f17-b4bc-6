// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GameModule} from "./lib/GameModule.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISystemMarket} from "./interfaces/Interfaces.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Params} from "./Params.sol";
import {RewardPool} from "./RewardPool.sol";
import {IMarket} from "./interfaces/Interfaces.sol";
import "./lib/Errors.sol";

interface IFeatureFlags {
    function enabled(uint256) external view returns (bool);
}

interface IPotSeason {
    function depositPot(uint256 amount) external;
}

contract FeeRouter is GameModule, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public teamTokens;
    uint256 public heartbeatTokens;
    uint256 public potETH;
    uint256 public lastSell;
    bool private selling;
    event TokensRouted(uint256 pool, uint256 team, uint256 heartbeat);
    event TokensSold(uint256 amount, uint256 ethAmount);
    event PotBought(uint256 ethAmount, uint256 tokens);
    address public constant team = 0x6d51cBE774aeAe4dd40bCA2560E9bc2695A0d007;
    uint256 public constant TEAM_BPS = 1000;

    function HEARTBEAT_CAP() public view returns (uint256) {
        return params().get(Params.Key.HeartbeatCap);
    }

    uint256 public rewardETH;
    uint256 public heartbeatBalance;
    uint256 public lastBuy;
    uint256 public constant MIN_BUY_AMOUNT = 0.05 ether;
    uint256 public constant MIN_BUY_INTERVAL = 5 minutes;
    uint256 public constant MAX_SLIPPAGE_BPS = 150;
    mapping(address => uint256) public credit;
    event Routed(uint8 indexed stream, uint256 amount);
    event Bought(uint256 ethAmount, uint256 tokenAmount);
    event Withdrawn(address indexed recipient, uint256 amount);
    event Bounty(address indexed caller, uint256 amount);
    event WorkBounty(address indexed caller, Params.Key indexed kind, uint256 units, uint256 amount);

    constructor(address registry_) GameModule(registry_) {}

    function token() public view returns (IERC20) {
        return IERC20(registry.token());
    }

    function params() public view returns (Params) {
        return Params(registry.params());
    }

    function market() public view returns (IMarket) {
        return IMarket(registry.market());
    }

    function rewardPool() public view returns (address) {
        return registry.module(0);
    }

    function packSale() public view returns (address) {
        return registry.module(4);
    }

    function grid() public view returns (address) {
        return registry.module(7);
    }

    function rewards() public view returns (address) {
        return registry.module(1);
    }

    function season() public view returns (address) {
        return registry.module(8);
    }

    function starter() public view returns (address) {
        return registry.module(5);
    }

    receive() external payable {
        if (selling && msg.sender == address(market())) return;
        _base();
    }

    function depositBaseFee() external payable {
        _base();
    }

    /// @dev v3.9: the hook's 1% swap share funds reward buys entirely. The team's swap income is the
    /// platform's 1% of the LP fee, paid to the paying wallet by LaunchFactory.claimFees, never routed here.
    function _base() private {
        if (msg.value == 0) revert InvalidValue();
        rewardETH += msg.value;
        emit Routed(0, msg.value);
    }

    function depositPack() external payable {
        revert InvalidValue();
    }

    function depositLobby() external payable {
        revert InvalidValue();
    }

    function depositSellTax() external payable {
        if (msg.sender != address(market())) revert Unauthorized();
        _route(3);
    }

    /// @notice Entire launch-window stepped buy tax: 100% to reward buys, no team or heartbeat share.
    function depositLaunchTax() external payable {
        if (msg.sender != address(market())) revert Unauthorized();
        if (msg.value == 0) revert InvalidValue();
        rewardETH += msg.value;
        emit Routed(4, msg.value);
    }

    /// @notice v3.6: the season token pot is a phased feature (Civic feature 6). Until it is enabled the
    /// pot share follows the v3.4 routing, i.e. it stays in reward buys. Unregistered Civic counts as disabled.
    function potEnabled() public view returns (bool) {
        address civic = registry.registeredModule(12);
        return civic != address(0) && IFeatureFlags(civic).enabled(6);
    }

    /// @dev Sell surcharge: 50% season pot (when enabled), 38% reward buys, 10% team, 2% capped heartbeat.
    function _route(uint8 stream) private {
        if (msg.value == 0) revert InvalidValue();
        uint256 t = msg.value * TEAM_BPS / 10000;
        uint256 h = msg.value * 200 / 10000;
        uint256 cap = HEARTBEAT_CAP();
        uint256 room = cap > heartbeatBalance ? cap - heartbeatBalance : 0;
        if (h > room) h = room;
        credit[team] += t;
        heartbeatBalance += h;
        uint256 pot = stream == 3 && potEnabled() ? msg.value / 2 : 0;
        potETH += pot;
        rewardETH += msg.value - t - h - pot;
        emit Routed(stream, msg.value);
    }

    function routeTokens(uint256 amount) external nonReentrant {
        if (msg.sender != packSale() && msg.sender != registry.module(2)) revert Unauthorized();
        if (amount == 0 || token().balanceOf(address(this)) < teamTokens + heartbeatTokens + amount) {
            revert InvalidValue();
        }
        uint256 t = amount / 10;
        uint256 h = heartbeatBalance < HEARTBEAT_CAP() ? amount * 200 / 10000 : 0;
        uint256 reward = amount - t - h;
        teamTokens += t;
        heartbeatTokens += h;
        token().safeTransfer(rewardPool(), reward);
        RewardPool(rewardPool()).recordInflow(reward);
        emit TokensRouted(reward, t, h);
    }

    function zapBuy(uint256 minOut, address recipient) external payable nonReentrant returns (uint256 received) {
        if (msg.sender != packSale() || recipient != packSale() || minOut == 0 || msg.value == 0) {
            revert Unauthorized();
        }
        uint256 before_ = token().balanceOf(recipient);
        market().buy{value: msg.value}(minOut, recipient);
        received = token().balanceOf(recipient) - before_;
        if (received < minOut) revert InsufficientBalance();
    }

    function sellBatchQuote() public view returns (uint256 amount, uint256 minimum) {
        ISystemMarket m = ISystemMarket(address(market()));
        uint256 eligibleHeartbeat = heartbeatBalance < HEARTBEAT_CAP() ? heartbeatTokens : 0;
        amount = Math.min(teamTokens + eligibleHeartbeat, m.maxSellBatch());
        minimum = m.quoteSell(amount) * 9850 / 10000;
    }

    function executeSells(uint256 amount, uint256 minOut) external nonReentrant returns (uint256 received) {
        if (lastSell != 0 && block.timestamp < lastSell + 5 minutes) revert TooEarly();
        if (heartbeatBalance >= HEARTBEAT_CAP() && heartbeatTokens != 0) {
            uint256 excess = heartbeatTokens;
            heartbeatTokens = 0;
            token().safeTransfer(rewardPool(), excess);
            RewardPool(rewardPool()).recordInflow(excess);
        }
        ISystemMarket m = ISystemMarket(address(market()));
        uint256 total = teamTokens + heartbeatTokens;
        // v3.14: the batch is the best one available at inclusion time (a dust trade between quote and
        // inclusion no longer reverts the sale); minOut is still checked against the live quote.
        amount = Math.min(total, m.maxSellBatch());
        if (amount == 0) revert InvalidValue();
        uint256 quoted = m.quoteSell(amount);
        if (minOut == 0 || minOut < quoted * 9850 / 10000) revert InvalidValue();
        uint256 h = amount * heartbeatTokens / total;
        teamTokens -= amount - h;
        heartbeatTokens -= h;
        lastSell = block.timestamp;
        uint256 before_ = address(this).balance;
        token().forceApprove(address(m), amount);
        selling = true;
        m.sell(amount, minOut, address(this));
        selling = false;
        token().forceApprove(address(m), 0);
        received = address(this).balance - before_;
        if (received < minOut) revert InsufficientBalance();
        uint256 hb = received * h / amount;
        uint256 accepted = Math.min(hb, HEARTBEAT_CAP() - heartbeatBalance);
        heartbeatBalance += accepted;
        rewardETH += hb - accepted;
        credit[team] += received - hb;
        emit TokensSold(amount, received);
    }

    function executePotBuys(uint256 amount, uint256 minOut) external nonReentrant returns (uint256 received) {
        if (amount == 0 || amount > potETH || amount > params().get(Params.Key.BuyBatch)) revert InvalidValue();
        if (lastBuy != 0 && block.timestamp < lastBuy + 5 minutes) revert TooEarly();
        uint256 minimum = Math.min(potETH, MIN_BUY_AMOUNT);
        uint256 quote = market().quote(amount);
        if (amount < minimum || minOut == 0 || quote == 0 || minOut < quote * 9850 / 10000) revert InvalidValue();
        potETH -= amount;
        lastBuy = block.timestamp;
        uint256 before_ = token().balanceOf(season());
        market().buy{value: amount}(minOut, season());
        received = token().balanceOf(season()) - before_;
        if (received < minOut) revert InsufficientBalance();
        IPotSeason(season()).depositPot(received);
        emit PotBought(amount, received);
    }

    function payBounty(address caller) external {
        if (msg.sender != rewards()) revert Unauthorized();
        uint256 b = _creditBounty(caller, params().get(Params.Key.Bounty));
        emit Bounty(caller, b);
    }

    /// @dev Only immutable work producers can request credits, after advancing their monotonic cursors.
    function payWork(address caller, Params.Key kind, uint256 units, uint256 gasUsed) external {
        bool allowed = (msg.sender == grid() || msg.sender == packSale() || msg.sender == starter())
            && kind == Params.Key.EntropyBounty;
        allowed = allowed || msg.sender == season() && kind == Params.Key.SeasonBounty;
        if (!allowed) revert Unauthorized();
        if (units == 0 || units > 64) revert InvalidValue();
        uint256 amount = _creditBounty(caller, _workAmount(params().get(kind) * units, gasUsed));
        emit WorkBounty(caller, kind, units, amount);
    }

    /// @dev Reimburse measured work plus transaction/payment overhead, with a 25% bot margin.
    /// Caps prevent high gas-price bidding or calldata padding from drawing an unbounded amount.
    function _workAmount(uint256 cap, uint256 gasUsed) private view returns (uint256) {
        uint256 price = tx.gasprice;
        uint256 ceiling = params().get(Params.Key.KeeperGasPrice);
        if (price > ceiling) price = ceiling;
        uint256 wanted = (gasUsed + 80_000) * price * 125 / 100;
        return wanted > cap ? cap : wanted;
    }

    function _creditBounty(address caller, uint256 requested) private returns (uint256 amount) {
        if (caller == address(0)) revert InvalidAddress();
        amount = requested > heartbeatBalance ? heartbeatBalance : requested;
        heartbeatBalance -= amount;
        credit[caller] += amount;
    }

    function withdraw() external nonReentrant {
        uint256 a = credit[msg.sender];
        if (a == 0) revert InsufficientBalance();
        credit[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: a}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(msg.sender, a);
    }

    function executeBuys(uint256 ethAmount, uint256 minOut) external nonReentrant returns (uint256 received) {
        uint256 startGas = gasleft();
        if (ethAmount == 0 || ethAmount > params().get(Params.Key.BuyBatch) || ethAmount > rewardETH) {
            revert InvalidValue();
        }
        uint256 minimum = rewardETH < MIN_BUY_AMOUNT ? rewardETH : MIN_BUY_AMOUNT;
        if (ethAmount < minimum) revert InvalidValue();
        if (lastBuy != 0 && block.timestamp < lastBuy + MIN_BUY_INTERVAL) revert TooEarly();
        uint256 q = market().quote(ethAmount);
        if (params().get(Params.Key.SlippageBps) > MAX_SLIPPAGE_BPS) revert InvalidValue();
        if (q == 0 || minOut == 0 || minOut < q * (10000 - params().get(Params.Key.SlippageBps)) / 10000) {
            revert InvalidValue();
        }
        rewardETH -= ethAmount;
        lastBuy = block.timestamp;
        uint256 before_ = token().balanceOf(rewardPool());
        market().buy{value: ethAmount}(minOut, rewardPool());
        received = token().balanceOf(rewardPool()) - before_;
        if (received < minOut) revert InsufficientBalance();
        if (!RewardPool(rewardPool()).endowed()) RewardPool(rewardPool()).recordInflow(received);
        // The aggregate cap is proportional to ETH bought, even when a caller splits a buy.
        uint256 bounty = params().get(Params.Key.BuyBounty) * ethAmount / params().get(Params.Key.BuyBatch);
        uint256 paid = _creditBounty(msg.sender, _workAmount(bounty, startGas - gasleft()));
        emit WorkBounty(msg.sender, Params.Key.BuyBounty, ethAmount, paid);
        emit Bought(ethAmount, received);
    }
}
