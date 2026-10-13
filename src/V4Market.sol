// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GameRegistry, IApplicationFactory} from "./GameRegistry.sol";
import {Params} from "./Params.sol";

interface IHookDesk {
    function registry() external view returns (address);
}
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IHookParams {
    function get(uint8 key) external view returns (uint256);
}

interface IHookRouter {
    function registry() external view returns (address);
    function token() external view returns (address);
    function market() external view returns (address);
    function params() external view returns (address);
    function depositBaseFee() external payable;
    function depositSellTax() external payable;
    function depositLaunchTax() external payable;
}
import {IV4PoolManager, PoolKey, SwapParams} from "./interfaces/IV4.sol";
import {IMD} from "./lib/IMD.sol";
import "./lib/Errors.sol";

/// @notice Immutable ETH/token v4 hook + buy adapter, selected as the IMD launch pool's hook.
/// @dev v3.9 fee model. The pool carries the platform LP fee 12500 (1.25%): LaunchFactory.claimFees pays 1%
/// of swap volume to the paying wallet (the team's swap income) and 0.25% to the IMD network. The hook adds
/// no network share of its own. After the stepped launch tax window it adds exactly PROJECT_BPS (1%) to
/// rewards on every swap, plus the progressive sell surcharge on sells. The LaunchFactory initializes the
/// pool, so afterInitialize authenticates its sender as `launcher` ($factory). No launch number is known at
/// construction: the registry is proven at bind time. The hook has no owner.
contract V4Market is ReentrancyGuard {
    using SafeERC20 for IERC20;
    bool private selling;
    /// @notice Hook share added to every swap after the launch window, entirely for reward buys.
    uint256 public constant PROJECT_BPS = 100;
    /// @notice Hard cap of the hook's total sell charge (base plus progressive surcharge).
    uint256 public constant TOTAL_CAP_BPS = 1500;
    uint160 public constant HOOK_FLAGS = 0x10cc; // afterInitialize, before/afterSwap and both swap deltas
    IV4PoolManager public immutable manager;
    address public immutable token;
    address public immutable launcher;
    bytes32 public immutable gameConfigHash;
    /// @notice The IMD ProjectFactory, fixed in bytecode (v3.14, src/lib/IMD.sol): never a constructor word.
    IApplicationFactory public constant applicationFactory = IApplicationFactory(IMD.PROJECT_FACTORY);
    IHookParams public params;
    IHookRouter public fees;
    uint256 public heldBase;
    uint256 public heldSellTax;
    uint256 public heldLaunchTax;
    /// @notice Launch protection, fixed in bytecode and anchored to the pool's one-time initialization.
    uint256 public constant LAUNCH_TAX_BPS = 9000;
    uint256 public constant LAUNCH_TAX_DECAY = 30 minutes;
    uint256 public constant LAUNCH_TAX_STEP = 10 minutes;
    event Bound(address indexed router, address indexed params);
    event FeesFlushed(uint256 base, uint256 sellTax);
    event LaunchTaxFlushed(uint256 amount);
    event LaunchTax(address indexed sender, uint256 ethInput, uint256 taxBps, uint256 launchTax);
    uint24 public immutable poolFee;
    int24 public immutable tickSpacing;
    bytes32 public immutable poolId;

    struct Volume {
        uint64 period;
        uint192 sells;
        uint192 buys;
    }
    Volume[12] private shortVolumes;
    Volume[24] private longVolumes;

    struct Observation {
        uint64 minute;
        uint256 cumulative;
    }
    Observation[32] private observations;
    uint256 public initializedAt;
    uint256 public updatedAt;
    uint256 public cumulative;
    uint256 public lastPrice;
    uint256 public storedFeeWad = 100 ether;
    uint256 public feeTimestamp;
    bool private buying;
    event PriceObserved(uint256 timestamp, uint256 tokensPerETH);
    event SellFee(
        address indexed sender,
        uint256 ethOutput,
        uint256 feeBps,
        uint256 hourImbalance,
        uint256 dayImbalance,
        uint256 deviation
    );

    uint24 public constant POOL_FEE = 12500;
    address public immutable desk;

    /// @param manager_ the PoolManager ($poolManager placeholder).
    /// @param launcher_ the LaunchFactory ($factory placeholder): it initializes the pool inside the launch transaction.
    /// @param desk_ the already-deployed SwarmDesk bootstrap; the canonical game is the one it binds to.
    /// @param gameConfigHash_ keccak256(abi.encode(starterRoot, freeRoot, snapshotBlock, endowment)).
    /// @dev v3.14: the ProjectFactory is the constant `applicationFactory`, no longer a constructor word.
    constructor(
        address manager_,
        address token_,
        uint24 fee_,
        int24 spacing_,
        address launcher_,
        address desk_,
        bytes32 gameConfigHash_
    ) {
        if (
            gameConfigHash_ == bytes32(0) || launcher_ == address(0) || manager_ == address(0) || token_ == address(0)
                || desk_ == address(0) || spacing_ <= 0 || spacing_ > 32767 || fee_ != POOL_FEE
        ) revert InvalidValue();
        gameConfigHash = gameConfigHash_;
        launcher = launcher_;
        manager = IV4PoolManager(manager_);
        token = token_;
        desk = desk_;
        poolFee = fee_;
        tickSpacing = spacing_;
        poolId = keccak256(abi.encode(PoolKey(address(0), token_, fee_, spacing_, address(this))));
        _validateHookAddress();
    }

    /// @notice Permissionless, one-time binding with bind-time proofs (v3.8). The caller supplies the
    /// registry's recorded factory coordinates. The registry must be the factory's CREATE2 result for its
    /// own exact initcode, its frozen configuration must match the commitment, its Params must be the
    /// Params of the registry the Desk bound to (the Desk proved that Params against pinned code and the
    /// factory), Params must point at the Desk, and in the strict path the Desk must have bound to it.
    function bindFeeRouter(address router, uint64 registryLaunch, uint256 registryIndex) external nonReentrant {
        if (address(fees) != address(0)) revert AlreadyDone();
        if (router.code.length == 0) revert InvalidAddress();
        if (registryLaunch == 0 || registryIndex >= 8) revert InvalidValue();
        IHookRouter candidate = IHookRouter(router);
        GameRegistry r = GameRegistry(candidate.registry());
        if (
            address(r.factory()) != address(applicationFactory) || r.token() != token || !_routerMarketValid(r.market())
        ) revert InvalidValue();
        if (keccak256(abi.encode(r.starterRoot(), r.freeRoot(), r.snapshotBlock(), r.endowment())) != gameConfigHash) {
            revert InvalidProof();
        }
        address p = r.params();
        _checkDesk(p);
        if (applicationFactory.predictContract(registryLaunch, registryIndex, _registryInitCode(r, p)) != address(r)) {
            revert InvalidProof();
        }
        if (!_canonical(r)) revert InvalidProof();
        // Enrollment proves exact FeeRouter initcode (including registry) and its factory CREATE2 address.
        if (
            r.module(6) != router || candidate.token() != token || candidate.market() != r.market()
                || candidate.params() != p
        ) {
            revert InvalidValue();
        }
        fees = candidate;
        params = IHookParams(p);
        emit Bound(router, p);
    }

    /// @dev The candidate's Params must be the Params of the registry the Desk bound to, pointing at the Desk.
    function _checkDesk(address p) private view {
        address bound = IHookDesk(desk).registry();
        if (bound == address(0) || GameRegistry(bound).params() != p || Params(p).swarmWallet() != desk) {
            revert InvalidProof();
        }
    }

    /// @dev Concatenation has a fixed, pinned creation-code prefix and one ABI tuple; no packed dynamic tuple.
    function _registryInitCode(GameRegistry r, address p) private view returns (bytes memory) {
        bytes memory args =
            abi.encode(r.token(), p, r.market(), r.starterRoot(), r.freeRoot(), r.snapshotBlock(), r.endowment());
        return bytes.concat(type(GameRegistry).creationCode, args);
    }

    /// @dev The Desk binds once; its registry is the canonical game.
    function _canonical(GameRegistry r) internal view virtual returns (bool) {
        return IHookDesk(desk).registry() == address(r);
    }

    /// @notice Permissionless forwarding, kept separate so a receiver cannot interrupt pool swaps.
    function flushFees() external nonReentrant {
        if (address(fees) == address(0)) revert NotConfigured();
        uint256 base = heldBase;
        uint256 excess = heldSellTax;
        uint256 launchTax = heldLaunchTax;
        if (base + excess + launchTax == 0) revert InsufficientBalance();
        heldBase = 0;
        heldSellTax = 0;
        heldLaunchTax = 0;
        if (base != 0) fees.depositBaseFee{value: base}();
        if (excess != 0) fees.depositSellTax{value: excess}();
        if (launchTax != 0) fees.depositLaunchTax{value: launchTax}();
        emit FeesFlushed(base, excess);
        if (launchTax != 0) emit LaunchTaxFlushed(launchTax);
    }

    function _routerMarketValid(address market_) internal view virtual returns (bool) {
        return market_ == address(this);
    }

    function _coefficient(uint8 key_, uint256 default_) private view returns (uint256) {
        return address(params) == address(0) ? default_ : params.get(key_);
    }

    function _validateHookAddress() internal view virtual {
        if (uint160(address(this)) & 0x3fff != HOOK_FLAGS) revert InvalidAddress();
    }

    /// @dev The progressive sell surcharge is part of the launch hook; the standard reference path disables it.
    function _surcharged() internal pure virtual returns (bool) {
        return true;
    }

    receive() external payable {
        if (msg.sender != address(manager)) revert Unauthorized();
    }

    function key() public view returns (PoolKey memory) {
        return PoolKey(address(0), token, poolFee, tickSpacing, address(this));
    }

    function _check(PoolKey calldata k) private view {
        if (msg.sender != address(manager) || keccak256(abi.encode(k)) != poolId) revert Unauthorized();
    }

    function spot() public view returns (uint256) {
        uint256 sqrt = uint160(uint256(manager.extsload(keccak256(abi.encode(poolId, uint256(6))))));
        if (sqrt == 0) revert NotConfigured();
        uint256 price = Math.mulDiv(Math.mulDiv(sqrt, sqrt, 1 << 96), 1 ether, 1 << 96);
        if (price == 0 || price > 1e40) revert InvalidValue();
        return price;
    }

    function afterInitialize(address sender, PoolKey calldata k, uint160, int24) external returns (bytes4) {
        _check(k);
        if (sender != launcher) revert Unauthorized();
        if (initializedAt != 0) revert AlreadyDone();
        initializedAt = block.timestamp;
        _observe(spot());
        return this.afterInitialize.selector;
    }

    function _observe(uint256 price) private {
        uint256 now_ = block.timestamp;
        if (initializedAt == 0) revert NotConfigured();
        if (updatedAt == 0) {
            updatedAt = now_;
            lastPrice = price;
            emit PriceObserved(now_, price);
            return;
        }
        uint256 first = updatedAt / 60 + 1;
        uint256 last = now_ / 60;
        if (last >= 32 && first < last - 31) first = last - 31;
        for (uint256 minute = first; minute <= last; ++minute) {
            uint256 c = cumulative + (1e60 / lastPrice) * (minute * 60 - updatedAt);
            observations[minute % 32] = Observation(uint64(minute), c);
        }
        cumulative += (1e60 / lastPrice) * (now_ - updatedAt);
        updatedAt = now_;
        lastPrice = price;
        emit PriceObserved(now_, price);
    }

    function _cumulativeAt(uint256 minute) private view returns (uint256) {
        uint256 ts = minute * 60;
        if (ts < initializedAt) revert NotConfigured();
        if (ts >= updatedAt) return cumulative + (1e60 / lastPrice) * (ts - updatedAt);
        Observation memory o = observations[minute % 32];
        if (o.minute != minute) revert NotConfigured();
        return o.cumulative;
    }

    function twap() public view returns (uint256) {
        if (initializedAt == 0 || block.timestamp < initializedAt + 31 minutes) revert NotConfigured();
        uint256 minute = block.timestamp / 60;
        uint256 averageETH = (_cumulativeAt(minute) - _cumulativeAt(minute - 30)) / 30 minutes;
        return 1e60 / averageETH;
    }

    /// @notice Tokens a system buy of `ethAmount` receives at TWAP after the hook's 1% share and the pool's
    /// LP fee (v3.14, audit a8730286 H: the router's slippage band covers only impact and TWAP deviation).
    function quote(uint256 ethAmount) external view returns (uint256) {
        uint256 netInput = ethAmount - ethAmount * PROJECT_BPS / 10000;
        netInput = netInput * (1_000_000 - poolFee) / 1_000_000;
        return Math.mulDiv(netInput, twap(), 1 ether);
    }

    function _record(bool sell, uint256 amount) private {
        if (amount > type(uint192).max) revert InvalidValue();
        uint256 p = block.timestamp / 5 minutes;
        Volume storage a = shortVolumes[p % 12];
        if (a.period != p) {
            delete shortVolumes[p % 12];
            a.period = uint64(p);
        }
        p = block.timestamp / 1 hours;
        Volume storage b = longVolumes[p % 24];
        if (b.period != p) {
            delete longVolumes[p % 24];
            b.period = uint64(p);
        }
        if (sell) {
            a.sells += uint192(amount);
            b.sells += uint192(amount);
        } else {
            a.buys += uint192(amount);
            b.buys += uint192(amount);
        }
    }

    function imbalances() public view returns (uint256 hour, uint256 day) {
        uint256 s;
        uint256 b;
        uint256 current = block.timestamp / 5 minutes;
        for (uint256 i; i < 12; ++i) {
            if (uint256(shortVolumes[i].period) + 12 > current) {
                s += shortVolumes[i].sells;
                b += shortVolumes[i].buys;
            }
        }
        if (s > b) hour = Math.mulDiv(s - b, 10000, s + b + 0.5 ether);
        s = 0;
        b = 0;
        current = block.timestamp / 1 hours;
        for (uint256 i; i < 24; ++i) {
            if (uint256(longVolumes[i].period) + 24 > current) {
                s += longVolumes[i].sells;
                b += longVolumes[i].buys;
            }
        }
        if (s > b) day = Math.mulDiv(s - b, 10000, s + b + 2 ether);
    }

    /// @notice The hook's own share after the launch window: exactly 1%, all to reward buys.
    function projectBps() public pure returns (uint256) {
        return PROJECT_BPS;
    }

    /// @notice Seconds since the pool was initialized (token launch). Zero before initialization.
    function sinceLaunch() public view returns (uint256) {
        return initializedAt == 0 ? 0 : block.timestamp - initializedAt;
    }

    /// @notice Immutable total buy-tax steps; the entire stepped tax funds reward buys.
    function currentBuyTaxBps() public view returns (uint256) {
        uint256 t = sinceLaunch();
        if (t < 10 minutes) return 9000;
        if (t < 20 minutes) return 5000;
        if (t < 30 minutes) return 2500;
        return PROJECT_BPS;
    }

    function launchTaxTimeLeft() public view returns (uint256) {
        uint256 t = sinceLaunch();
        return t >= LAUNCH_TAX_DECAY ? 0 : LAUNCH_TAX_DECAY - t;
    }

    function nextStepIn() public view returns (uint256) {
        uint256 t = sinceLaunch();
        return t >= LAUNCH_TAX_DECAY ? 0 : LAUNCH_TAX_STEP - t % LAUNCH_TAX_STEP;
    }

    /// @notice Compatibility views: buys are unlimited from the first block.
    function maxBuy() public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxBuyTimeLeft() public pure returns (uint256) {
        return 0;
    }

    function launchStatus() external view returns (uint256, uint256, uint256, uint256) {
        return (currentBuyTaxBps(), launchTaxTimeLeft(), type(uint256).max, 0);
    }

    function _sellFee(uint256 price) private returns (uint256 fee, uint256 hour, uint256 day, uint256 dev) {
        if (!_surcharged()) return (PROJECT_BPS, 0, 0, 0);
        (hour, day) = imbalances();
        uint256 average;
        // Trading is possible during warmup; the deviation component starts only when TWAP is ready.
        if (block.timestamp >= initializedAt + 31 minutes) average = twap();
        if (average != 0 && price > average) dev = Math.min(1000, 10000 - Math.mulDiv(average, 10000, price));
        uint256 target = PROJECT_BPS + _coefficient(24, 500) * hour / 10000 + _coefficient(25, 400) * day / 10000
            + _coefficient(26, 5000) * dev / 10000;
        target = Math.min(TOTAL_CAP_BPS, target) * 1 ether;
        uint256 fall = feeTimestamp == 0 ? 0 : (block.timestamp - feeTimestamp) * 100 ether / 10 minutes;
        uint256 decayed = storedFeeWad > fall ? storedFeeWad - fall : PROJECT_BPS * 1 ether;
        storedFeeWad = Math.max(target, decayed);
        feeTimestamp = block.timestamp;
        fee = Math.min(TOTAL_CAP_BPS, (storedFeeWad + 1 ether - 1) / 1 ether);
    }

    function beforeSwap(address sender, PoolKey calldata k, SwapParams calldata p, bytes calldata)
        external
        returns (bytes4, int256, uint24)
    {
        _check(k);
        if (p.amountSpecified >= 0) revert InvalidValue();
        _observe(spot());
        if (!p.zeroForOne) return (this.beforeSwap.selector, 0, 0);
        uint256 ethIn = uint256(-p.amountSpecified);
        uint256 taxBps = currentBuyTaxBps();
        uint256 fee = ethIn * taxBps / 10000;
        if (fee > uint256(uint128(type(int128).max))) revert InvalidValue();
        if (sinceLaunch() < LAUNCH_TAX_DECAY) {
            manager.take(address(0), address(this), fee);
            heldLaunchTax += fee;
            emit LaunchTax(sender, ethIn, taxBps, fee);
        } else {
            // Exactly PROJECT_BPS of the input, all of it the base stream (reward buys).
            _take(fee, 0);
        }
        return (this.beforeSwap.selector, int256(fee << 128), 0);
    }

    function afterSwap(address sender, PoolKey calldata k, SwapParams calldata p, int256 delta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        _check(k);
        if (p.amountSpecified >= 0) revert InvalidValue();
        uint256 price = spot();
        _observe(price);
        int128 ethDelta = int128(delta >> 128);
        if (p.zeroForOne) {
            if (ethDelta >= 0) revert InvalidValue();
            _record(false, uint256(-int256(ethDelta)));
            return (this.afterSwap.selector, 0);
        }
        if (ethDelta <= 0) revert InvalidValue();
        uint256 output = uint256(uint128(ethDelta));
        _record(true, output);
        return (this.afterSwap.selector, int128(int256(_chargeSell(sender, output, price))));
    }

    /// @dev Base 1% to rewards plus the progressive surcharge above it; both taken from the sell output.
    function _chargeSell(address sender, uint256 output, uint256 price) private returns (uint256) {
        (uint256 bps, uint256 hour, uint256 day, uint256 dev) = _sellFee(price);
        uint256 base = output * PROJECT_BPS / 10000;
        uint256 excess = output * (bps - PROJECT_BPS) / 10000;
        _take(base, excess);
        emit SellFee(sender, output, bps, hour, day, dev);
        return base + excess;
    }

    function _take(uint256 base, uint256 excess) private {
        uint256 total = base + excess;
        if (total != 0) manager.take(address(0), address(this), total);
        heldBase += base;
        heldSellTax += excess;
    }

    function buy(uint256 minOut, address recipient) external payable nonReentrant returns (uint256 received) {
        if (msg.sender != address(fees) || recipient == address(0) || msg.value == 0 || minOut == 0) {
            revert Unauthorized();
        }
        if (initializedAt == 0 || sinceLaunch() < LAUNCH_TAX_DECAY) revert TooEarly();
        twap();
        buying = true;
        received = abi.decode(manager.unlock(abi.encode(msg.value, minOut, recipient)), (uint256));
        buying = false;
    }

    /// @notice ETH a system sell of `amount` receives at TWAP after the pool's LP fee and the hook's 1% (v3.14).
    function quoteSell(uint256 amount) public view returns (uint256) {
        uint256 gross = Math.mulDiv(amount, 1 ether, twap());
        gross = gross * (1_000_000 - poolFee) / 1_000_000;
        return gross - gross * PROJECT_BPS / 10000;
    }

    /// @notice At most 0.1% of current virtual token reserves, additionally capped by 0.1 ETH TWAP value.
    function maxSellBatch() public view returns (uint256) {
        bytes32 slot = keccak256(abi.encode(poolId, uint256(6)));
        uint256 liquidity = uint128(uint256(manager.extsload(bytes32(uint256(slot) + 3))));
        uint256 sqrt = uint160(uint256(manager.extsload(slot)));
        uint256 depth = Math.mulDiv(liquidity, sqrt, 1 << 96);
        return Math.min(depth / 1000, twap() / 10);
    }

    function sell(uint256 amount, uint256 minOut, address recipient) external nonReentrant returns (uint256 received) {
        if (msg.sender != address(fees) || recipient != address(fees) || amount == 0 || minOut == 0) {
            revert Unauthorized();
        }
        if (amount > maxSellBatch()) revert InvalidValue();
        if (minOut < quoteSell(amount) * 9850 / 10000) revert InvalidValue();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        selling = true;
        received = abi.decode(manager.unlock(abi.encode(amount, minOut, recipient)), (uint256));
        selling = false;
    }

    function _sellCallback(bytes calldata data) private returns (bytes memory) {
        (uint256 amount, uint256 minimum, address recipient) = abi.decode(data, (uint256, uint256, address));
        _observe(spot());
        int256 delta = manager.swap(
            key(), SwapParams(false, -int256(amount), 1461446703485210103287273052203988822378723970341), ""
        );
        _observe(spot());
        int128 ethOut = int128(delta >> 128);
        int128 tokenIn = int128(delta);
        if (ethOut <= 0 || tokenIn >= 0 || uint256(-int256(tokenIn)) != amount) revert InsufficientBalance();
        uint256 gross = uint256(uint128(ethOut));
        uint256 base = gross * PROJECT_BPS / 10000;
        uint256 net = gross - base;
        if (net < minimum) revert InsufficientBalance();
        manager.sync(token);
        IERC20(token).safeTransfer(address(manager), amount);
        manager.settle();
        manager.take(address(0), address(this), gross);
        heldBase += base;
        _record(true, gross);
        (bool ok,) = recipient.call{value: net}("");
        if (!ok) revert TransferFailed();
        return abi.encode(net);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || (!buying && !selling)) revert Unauthorized();
        if (selling) return _sellCallback(data);
        (uint256 ethIn, uint256 minOut, address recipient) = abi.decode(data, (uint256, uint256, address));
        uint256 base = ethIn * PROJECT_BPS / 10000;
        uint256 input = ethIn - base;
        _observe(spot());
        // v4 suppresses a hook's callbacks on its own swaps. Account for this system buy explicitly.
        int256 delta = manager.swap(key(), SwapParams(true, -int256(input), 4295128740), "");
        _observe(spot());
        int128 ethDelta = int128(delta >> 128);
        int128 tokenDelta = int128(delta);
        if (
            ethDelta >= 0 || uint256(-int256(ethDelta)) != input || tokenDelta <= 0
                || uint256(uint128(tokenDelta)) < minOut
        ) {
            revert InsufficientBalance();
        }
        _record(false, input);
        manager.settle{value: input}();
        manager.take(token, recipient, uint256(uint128(tokenDelta)));
        heldBase += base;
        return abi.encode(uint256(uint128(tokenDelta)));
    }
}
