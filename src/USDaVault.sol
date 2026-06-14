// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// --- OpenZeppelin (OZ v5.0.2, virtual-shares ERC4626) ---
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// --- v4 core types & libraries ---
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";

// --- v4 periphery: PositionManager + actions ---
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";

// --- Permit2 ---
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

// --- local interfaces ---
import {IVaultHook} from "./interfaces/IVaultHook.sol";
import {IUniversalRouter} from "./interfaces/IUniversalRouter.sol";
import {IBackupSwapRouter} from "./interfaces/IBackupSwapRouter.sol";

/**
 * @title USDaVault
 * @notice ERC4626 vault that takes USDC, provides concentrated USDC/USDT liquidity on a Uniswap v4
 *         pool across 4 positions (1 fixed full-range backstop + 3 hook-driven percentile bands),
 *         and issues USDa shares. NAV-based appreciation; no vault fee. See ARCHITECTURE.md.
 * @dev Build spec is ARCHITECTURE.md; section tags (§N) below map to it. Mainnet, immutable, no proxy.
 *
 *      ERC4626 integration uses "pattern (a)": override {totalAssets} (§5) + {_decimalsOffset}, and
 *      expose CUSTOM {deposit}/{withdraw} that reuse OZ's internal share math + virtual-shares
 *      defense. The vanilla 4626 mutating entrypoints are LOCKED (they assume single-asset
 *      balanceOf semantics that don't fit this vault).
 */
contract USDaVault is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    // ─────────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev OZ virtual-shares offset (§6). USDa decimals = USDC(6) + 6 = 12.
    uint8 internal constant DECIMALS_OFFSET = 6;
    /// @dev Unredeemable dead shares minted on initialize (§6, defense-in-depth alongside virtual shares).
    uint256 internal constant MINIMUM_LIQUIDITY = 1_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev UniversalRouter command byte for a v4 swap program. VERIFY-BEFORE-DEPLOY vs deployed UR.
    bytes1 internal constant CMD_V4_SWAP = 0x10;
    uint256 internal constant Q128 = FixedPoint128.Q128;

    /// @dev Canonical Permit2 (same address on every chain; verified in installed Permit2Lib).
    IAllowanceTransfer internal constant PERMIT2 =
        IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    uint16 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    // ─────────────────────────────────────────────────────────────────────────────
    // Immutables (§4)
    // ─────────────────────────────────────────────────────────────────────────────

    IERC20 public immutable USDC;
    IERC20 public immutable USDT;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IUniversalRouter public immutable universalRouter;

    // vault pool key, flattened (structs cannot be immutable)
    Currency internal immutable C0;
    Currency internal immutable C1;
    uint24 internal immutable POOL_FEE;
    int24 internal immutable TICK_SPACING;
    IHooks internal immutable HOOKS;

    /// @dev The vault pool's own hook (== poolKey.hooks); the IVaultHook.computeRanges provider (§3).
    address public immutable hook;
    PoolId internal immutable POOL_ID;

    bool public immutable usdcIsToken0; // §2
    int24 public immutable fullRangeLower; // minUsableTick(tickSpacing)
    int24 public immutable fullRangeUpper; // maxUsableTick(tickSpacing)

    // ─────────────────────────────────────────────────────────────────────────────
    // Config (mutable, owner-tunable) (§4, §12)
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev PRIMARY off-pool swap venue (§10b). Must differ from the vault pool.
    PoolKey public swapPoolKey;
    /// @dev BACKUP swap adapter (§10b). address(0) = disabled.
    address public backupRouter;

    /// @dev Hook confidence bands for positions 1–3 (e.g. [9000, 9900, 9990]).
    uint16[3] public confidencesBps;
    /// @dev NAV-allocation targets per position at (re)deploy, bps. Must sum to BPS when bufferBps==0.
    uint16[4] public targetsBps;

    uint256 public rebalanceBand; // drift (ticks) that marks a position for rebalance
    uint256 public reentryBand; // hysteresis: re-mark only after drift returns below this
    uint256 public minWidth; // min hook-band width (ticks) accepted
    uint256 public maxWidth; // max hook-band width (ticks) accepted

    uint256 public pegLow; // peg band lower bound, USDC-per-USDT in WAD (e.g. 0.995e18)
    uint256 public pegHigh; // peg band upper bound, USDC-per-USDT in WAD (e.g. 1.005e18)

    uint16 public bufferBps; // idle USDC reserve kept out of positions (0 = invest all)
    uint16 public swapMaxSlippageBps; // bounds minOut on internal swaps (e.g. 30)
    uint256 public rebalanceGasCap; // inline rebalance skipped if gasleft() < this

    bool public paused;
    bool public initialized;

    // ─────────────────────────────────────────────────────────────────────────────
    // Position state (§3, §4)
    // ─────────────────────────────────────────────────────────────────────────────

    struct Position {
        uint256 tokenId;
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    /// @dev idx 0 = full-range backstop (never rebalanced), 1–3 = hook bands.
    Position[4] public positions;

    /// @dev USDC dust (+ optional buffer), tracked internally — NEVER token.balanceOf (§5).
    uint256 public idleUSDC;
    /// @dev USDT held outside positions, tracked internally (delta-credited, donation-proof). Valued in NAV
    ///      at the clamped price. Fixes the residual leak where deploy slippage/dust escaped NAV (C3).
    uint256 public idleUSDT;

    /// @dev Pool-sqrt bounds of the peg band. NAV valuation clamps the spot price into [low, high] so an
    ///      in-block spot push cannot move NAV beyond the band (C2). Recomputed on setPegBand.
    uint160 internal navSqrtLow;
    uint160 internal navSqrtHigh;

    // ─────────────────────────────────────────────────────────────────────────────
    // Events / errors
    // ─────────────────────────────────────────────────────────────────────────────

    event Initialized(uint256 deadShares, uint256 seededUSDC);
    event RebalanceExecuted(uint8 indexed index, int24 lower, int24 upper, uint128 liquidity);
    event RangeUpdated(uint8 indexed index, int24 lower, int24 upper);
    event SwapVenueUpdated(PoolKey swapPoolKey, address backupRouter);
    event DualTokenWithdraw(address indexed user, uint256 usdc, uint256 usdt);
    event Paused(bool paused);

    error Expired();
    error SlippageExceeded();
    error ZeroAmount();
    error BadWantToken();
    error AlreadyInitialized();
    error NotInitialized();
    error IsPaused();
    error OnlySelf();
    error SwapPoolIsVaultPool();
    error VanillaEntrypointDisabled();
    error AmountTooLarge();
    error OffPeg();

    // ─────────────────────────────────────────────────────────────────────────────
    // Constructor (§11)
    // ─────────────────────────────────────────────────────────────────────────────

    constructor(
        IERC20 _usdc,
        IERC20 _usdt,
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IUniversalRouter _universalRouter,
        PoolKey memory vaultPoolKey,
        PoolKey memory _swapPoolKey,
        address _backupRouter,
        address _owner
    ) ERC20("Ascent USD", "USDa") ERC4626(_usdc) Ownable(_owner) {
        USDC = _usdc;
        USDT = _usdt;
        poolManager = _poolManager;
        positionManager = _positionManager;
        universalRouter = _universalRouter;

        C0 = vaultPoolKey.currency0;
        C1 = vaultPoolKey.currency1;
        POOL_FEE = vaultPoolKey.fee;
        TICK_SPACING = vaultPoolKey.tickSpacing;
        HOOKS = vaultPoolKey.hooks;
        hook = address(vaultPoolKey.hooks);
        POOL_ID = vaultPoolKey.toId();

        // §2: derive token0/leg orientation — never hardcode.
        usdcIsToken0 = (Currency.unwrap(vaultPoolKey.currency0) == address(_usdc));

        fullRangeLower = TickMath.minUsableTick(vaultPoolKey.tickSpacing);
        fullRangeUpper = TickMath.maxUsableTick(vaultPoolKey.tickSpacing);

        // §10b/§13: the vault must never swap its own pool.
        if (_samePool(_swapPoolKey.toId(), POOL_ID)) revert SwapPoolIsVaultPool();
        swapPoolKey = _swapPoolKey;
        backupRouter = _backupRouter;

        // Defaults (§3/§4 TODO(dev) — owner-tunable post-deploy).
        confidencesBps = [uint16(9000), 9900, 9990];
        targetsBps = [uint16(100), 7900, 1500, 500]; // 1% / 79% / 15% / 5% = 100%
        rebalanceBand = 50;
        reentryBand = 25;
        minWidth = uint256(uint24(vaultPoolKey.tickSpacing)); // ≥ one spacing
        maxWidth = 200_000;
        pegLow = 0.995e18;
        pegHigh = 1.005e18;
        bufferBps = 0;
        swapMaxSlippageBps = 30;
        rebalanceGasCap = 350_000;

        _recomputeNavSqrtBounds(); // C2: derive the NAV price-clamp band from pegLow/pegHigh
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // ERC4626 overrides (§5, §6)
    // ─────────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ERC4626
    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    /**
     * @notice NAV in USDC (6dp) (§5): Σ position (principal + uncollected fees) + idleUSDC + idleUSDT·P.
     *         Computed from liquidity + recorded feeGrowth + idle counters ONLY — never token.balanceOf,
     *         making raw token donations inert. The USDT leg is valued at the spot price CLAMPED into the
     *         peg band (`_navSqrt`), so an in-block spot manipulation cannot skew NAV beyond the band (C2).
     */
    function totalAssets() public view override returns (uint256 nav) {
        uint160 navSqrt = _navSqrt();
        nav = idleUSDC + _usdtToUsdc(idleUSDT, navSqrt);
        for (uint8 i = 0; i < 4; i++) {
            nav += _positionValueUSDC(i, navSqrt);
        }
    }

    // --- vanilla 4626 mutating entrypoints are LOCKED (§ pattern a) ---

    function deposit(uint256, address) public pure override returns (uint256) {
        revert VanillaEntrypointDisabled();
    }

    function mint(uint256, address) public pure override returns (uint256) {
        revert VanillaEntrypointDisabled();
    }

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert VanillaEntrypointDisabled();
    }

    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert VanillaEntrypointDisabled();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Deposit (§7)
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Deposit USDC, mint USDa priced off PRE-deposit NAV.
     * @param usdcAmount Amount of USDC to deposit.
     * @param minShares  Slippage floor on shares minted.
     * @param deadline   Tx deadline.
     */
    function deposit(uint256 usdcAmount, uint256 minShares, uint256 deadline)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (paused) revert IsPaused();
        if (block.timestamp > deadline) revert Expired();
        if (usdcAmount == 0) revert ZeroAmount();
        // C2: refuse to price shares while the vault pool spot is off peg (manipulated or genuinely
        // depegged). Blocks the mint-cheap half of the NAV-manipulation attack; deposits can wait.
        if (!_pegOk(_sqrtPriceX96())) revert OffPeg();

        // Pull USDC and measure ACTUAL received (defensive; §13). NAV ignores balanceOf, so totalAssets()
        // is still the pre-deposit value here — shares price off it correctly.
        uint256 before = USDC.balanceOf(address(this));
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        uint256 received = USDC.balanceOf(address(this)) - before;

        shares = _convertToShares(received, Math.Rounding.Floor);
        if (shares < minShares) revert SlippageExceeded();

        idleUSDC += received;
        _mint(msg.sender, shares);
        emit Deposit(msg.sender, msg.sender, received, shares);

        _bestEffortRebalance();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Withdraw (§8)
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Redeem USDa for USDC or USDT. The pro-rata slice governs the payout; `minOut` protects.
     * @param shares    USDa to burn.
     * @param wantToken USDC or USDT.
     * @param minOut    Minimum acceptable payout in `wantToken` (ignored on dual-token fallback).
     * @param deadline  Tx deadline.
     */
    function withdraw(uint256 shares, address wantToken, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 out)
    {
        if (paused) revert IsPaused();
        if (block.timestamp > deadline) revert Expired();
        if (shares == 0) revert ZeroAmount();
        if (wantToken != address(USDC) && wantToken != address(USDT)) revert BadWantToken();

        uint256 supply = totalSupply();

        // Fast path (§8.2a): pay USDC from idle if it fully covers the claim — preserves per-share NAV.
        if (wantToken == address(USDC)) {
            uint256 claim = _convertToAssets(shares, Math.Rounding.Floor);
            if (claim <= idleUSDC) {
                if (claim < minOut) revert SlippageExceeded();
                _burn(msg.sender, shares);
                idleUSDC -= claim;
                USDC.safeTransfer(msg.sender, claim);
                emit Withdraw(msg.sender, msg.sender, msg.sender, claim, shares);
                _bestEffortRebalance();
                return claim;
            }
        }

        // Slice path (§8.2b): pull pro-rata liquidity + fee share from each position, plus idle slice.
        (uint256 usdcAmt, uint256 usdtAmt) = _sliceAllPositions(shares, supply);

        // Effect before external swaps/transfers (CEI; reentrancy already guarded).
        _burn(msg.sender, shares);

        out = _consolidateAndPay(wantToken, usdcAmt, usdtAmt, minOut, shares);
        _bestEffortRebalance();
    }

    /**
     * @dev Pulls `f = shares/supply` of every position plus an `f` slice of both idle counters (§8.2b).
     *      C1 FIX: a v4 liquidity decrease settles 100% of a position's accrued fees, but the withdrawer
     *      is entitled only to their pro-rata fee share. We snapshot each poked position's fees, pay the
     *      withdrawer only `f·(principal+fees)`, and retain the `(1-f)·fees` surplus in the accounted idle
     *      counters so per-share NAV stays flat for remaining holders.
     */
    function _sliceAllPositions(uint256 shares, uint256 supply)
        internal
        returns (uint256 usdcAmt, uint256 usdtAmt)
    {
        uint256 got0;
        uint256 got1;
        uint256 surplus0;
        uint256 surplus1;
        for (uint8 i = 0; i < 4; i++) {
            uint128 liq = uint128(FullMath.mulDiv(positions[i].liquidity, shares, supply));
            if (liq == 0) continue;
            (uint256 f0, uint256 f1) = _positionFees(i); // 100% fees the decrease will settle
            (uint256 d0, uint256 d1) = _decrease(i, liq); // f·principal + 100% fees
            got0 += d0;
            got1 += d1;
            surplus0 += f0 - FullMath.mulDiv(f0, shares, supply); // (1-f)·fees retained
            surplus1 += f1 - FullMath.mulDiv(f1, shares, supply);
        }

        // Slice both idle counters BEFORE retaining the new surplus (so the withdrawer doesn't slice it).
        uint256 idleSlice0 = FullMath.mulDiv(idleUSDC, shares, supply);
        uint256 idleSlice1 = FullMath.mulDiv(idleUSDT, shares, supply);
        idleUSDC -= idleSlice0;
        idleUSDT -= idleSlice1;

        // Retain other holders' fee surplus in accounted idle (keeps per-share NAV flat).
        _creditIdle(surplus0, surplus1);

        // Withdrawer entitlement = (decreased tokens − retained surplus) + idle slice.
        (uint256 payUsdc, uint256 payUsdt) =
            usdcIsToken0 ? (got0 - surplus0, got1 - surplus1) : (got1 - surplus1, got0 - surplus0);
        usdcAmt = payUsdc + idleSlice0;
        usdtAmt = payUsdt + idleSlice1;
    }

    /// @dev Consolidate the unwanted leg into `wantToken` (§8.3), with dual-token fallback if swaps fail.
    function _consolidateAndPay(
        address wantToken,
        uint256 usdcAmt,
        uint256 usdtAmt,
        uint256 minOut,
        uint256 shares
    ) internal returns (uint256 out) {
        if (wantToken == address(USDC)) {
            out = usdcAmt;
            if (usdtAmt > 0) {
                (uint256 got, bool ok) = _swapExactInOffPool(address(USDT), usdtAmt, _minOut(usdtAmt));
                if (ok) {
                    out += got;
                } else {
                    return _payDualToken(usdcAmt, usdtAmt, shares);
                }
            }
            if (out < minOut) revert SlippageExceeded();
            USDC.safeTransfer(msg.sender, out);
        } else {
            out = usdtAmt;
            if (usdcAmt > 0) {
                (uint256 got, bool ok) = _swapExactInOffPool(address(USDC), usdcAmt, _minOut(usdcAmt));
                if (ok) {
                    out += got;
                } else {
                    return _payDualToken(usdcAmt, usdtAmt, shares);
                }
            }
            if (out < minOut) revert SlippageExceeded();
            USDT.safeTransfer(msg.sender, out);
        }
        emit Withdraw(msg.sender, msg.sender, msg.sender, out, shares);
    }

    /// @dev Both swap venues failed (§8.3): pay the user their pro-rata USDC + USDT directly. Never reverts.
    function _payDualToken(uint256 usdcAmt, uint256 usdtAmt, uint256 shares) internal returns (uint256) {
        if (usdcAmt > 0) USDC.safeTransfer(msg.sender, usdcAmt);
        if (usdtAmt > 0) USDT.safeTransfer(msg.sender, usdtAmt);
        emit DualTokenWithdraw(msg.sender, usdcAmt, usdtAmt);
        emit Withdraw(msg.sender, msg.sender, msg.sender, usdcAmt, shares);
        return usdcAmt;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Rebalance (§9)
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Permissionless rebalance (§9). Same logic as the best-effort inline call.
    function rebalance() external nonReentrant {
        if (!initialized) revert NotInitialized();
        _rebalance();
    }

    /// @dev Best-effort inline rebalance at the tail of deposit/withdraw — never blocks user flow.
    function _bestEffortRebalance() internal {
        if (paused || !initialized) return;
        if (gasleft() < rebalanceGasCap) return;
        try this._systemRebalance() {} catch {}
    }

    /// @dev External wrapper so the inline call can be try/caught. Self-only.
    function _systemRebalance() external {
        if (msg.sender != address(this)) revert OnlySelf();
        _rebalance();
    }

    /// @dev Core rebalance: hook ranges → validate → peg guard → at most one position per call (§9).
    function _rebalance() internal {
        if (paused) return;
        uint160 sqrtP = _sqrtPriceX96();
        if (!_pegOk(sqrtP)) return; // §9.2 — also the depeg breaker

        uint16[] memory confs = new uint16[](3);
        confs[0] = confidencesBps[0];
        confs[1] = confidencesBps[1];
        confs[2] = confidencesBps[2];

        IVaultHook.Range[] memory ranges;
        bool ok;
        try IVaultHook(hook).computeRanges(POOL_ID, confs) returns (IVaultHook.Range[] memory r, bool k) {
            ranges = r;
            ok = k;
        } catch {
            return; // never let the hook DoS user flow (§3)
        }
        if (!ok || ranges.length < 3) return;

        // §9.3 — positions 1,2,3 independently; at most one repositioned per call.
        for (uint8 j = 0; j < 3; j++) {
            uint8 i = j + 1;
            int24 nl = ranges[j].tickLower;
            int24 nu = ranges[j].tickUpper;
            if (!_validRange(nl, nu)) continue;
            uint256 drift = _absDiff(nl, positions[i].lower) + _absDiff(nu, positions[i].upper);
            if (drift > rebalanceBand) {
                uint256 v = _positionValueUSDC(i, sqrtP);
                try this._rebalanceStep(i, nl, nu, v) {
                    emit RebalanceExecuted(i, nl, nu, positions[i].liquidity);
                } catch {}
                return;
            }
        }
    }

    /**
     * @dev Atomic burn→swap→mint for one position (§9.4). Self-only and wrapped in try/catch by the
     *      caller: if the swap can't be filled within slippage we `require(ok)` → revert → the burn is
     *      rolled back and the OLD position is kept. Best-effort, retried next trigger.
     */
    function _rebalanceStep(uint8 i, int24 lower, int24 upper, uint256 valueUSDC) external {
        if (msg.sender != address(this)) revert OnlySelf();

        (uint256 b0, uint256 b1) = _tokenBalances(); // for residual reconciliation (C3)
        (uint256 got0, uint256 got1) = _burnPosition(i);

        (uint256 amt0, uint256 amt1, uint128 liquidity) = _amountsForRange(lower, upper, valueUSDC);
        if (liquidity == 0) revert ZeroAmount();

        bool ok = _swapToTarget(got0, got1, amt0, amt1);
        if (!ok) revert SlippageExceeded(); // rolls back the burn → keep old position

        positions[i].lower = lower;
        positions[i].upper = upper;
        _mintInto(i, lower, upper, amt0, amt1);
        // C3: fold leftover tokens (realised fees not redeployed, swap/rounding dust) back into accounted
        // idle via the signed balance delta, so they stay counted in NAV instead of leaking out.
        _reconcileIdle(b0, b1);
        emit RangeUpdated(i, lower, upper);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Initialize (§11)
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice One-shot bootstrap (owner): mint dead shares, then open all 4 positions. Requires a
     *         prior seed deposit (idleUSDC > 0). The pool has no swaps yet so the hook returns
     *         ok=false → positions 1–3 open at FALLBACK ranges (±1% / ±3% / ±5%); later rebalances
     *         adopt hook ranges once ok flips true (§9, §11).
     */
    function initialize() external onlyOwner nonReentrant {
        if (initialized) revert AlreadyInitialized();
        if (idleUSDC == 0) revert ZeroAmount();
        initialized = true;

        // Dead shares (§6): minted to an unredeemable address, backed by the seed.
        _mint(DEAD, MINIMUM_LIQUIDITY);

        uint160 sqrtP = _sqrtPriceX96();
        int24 cur = TickMath.getTickAtSqrtPrice(sqrtP);
        uint256 nav = idleUSDC;
        uint256 seeded = nav;

        // Position 0: full-range backstop.
        _initOne(0, fullRangeLower, fullRangeUpper, FullMath.mulDiv(nav, targetsBps[0], BPS));

        // Positions 1–3: fallback bands around the current tick (hook still cold).
        int24[3] memory halfWidth = [_align(100), _align(300), _align(500)]; // ~±1% / ±3% / ±5% in ticks
        for (uint8 j = 0; j < 3; j++) {
            uint8 i = j + 1;
            int24 lo = _clampTick(cur - halfWidth[j]);
            int24 hi = _clampTick(cur + halfWidth[j]);
            _initOne(i, lo, hi, FullMath.mulDiv(nav, targetsBps[i], BPS));
        }

        emit Initialized(MINIMUM_LIQUIDITY, seeded);
    }

    /// @dev Deploy `valueUSDC` of idle USDC into position `i` over [lower,upper]: split via swap, then mint.
    ///      Idle is debited by the ACTUAL net token outflow (signed balance delta), not the earmark, so
    ///      swap slippage and deploy dust stay accounted in NAV instead of leaking (C3).
    function _initOne(uint8 i, int24 lower, int24 upper, uint256 valueUSDC) internal {
        if (valueUSDC == 0) return;
        (uint256 amt0, uint256 amt1, uint128 liquidity) = _amountsForRange(lower, upper, valueUSDC);
        if (liquidity == 0) return;

        // We hold only USDC (idle). Provide it as the USDC leg; swap toward the target ratio.
        (uint256 have0, uint256 have1) = usdcIsToken0 ? (valueUSDC, uint256(0)) : (uint256(0), valueUSDC);
        (uint256 b0, uint256 b1) = _tokenBalances();

        bool ok = _swapToTarget(have0, have1, amt0, amt1);
        positions[i].lower = lower;
        positions[i].upper = upper;
        if (!ok) return; // swap venue down: guard rolled back, tokens untouched, idle unchanged
        _mintInto(i, lower, upper, amt0, amt1);
        _reconcileIdle(b0, b1); // remove net-consumed from idle; residual stays counted
        emit RangeUpdated(i, lower, upper);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // NAV helpers (§5)
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev USDC value (6dp) of position `i`: principal + uncollected fees, valued at `sqrtP`. Zero if empty.
    function _positionValueUSDC(uint8 i, uint160 sqrtP) internal view returns (uint256) {
        Position memory p = positions[i];
        if (p.liquidity == 0) return 0;

        // Principal: liquidity → token amounts at the (NAV-clamped) price clamped into the range.
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(p.lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(p.upper);
        uint160 sqrtClamped = sqrtP < sqrtA ? sqrtA : (sqrtP > sqrtB ? sqrtB : sqrtP);
        uint256 amt0 = SqrtPriceMath.getAmount0Delta(sqrtClamped, sqrtB, p.liquidity, false);
        uint256 amt1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtClamped, p.liquidity, false);

        (uint256 fee0, uint256 fee1) = _positionFees(i);
        return _valueUSDC(amt0 + fee0, amt1 + fee1, sqrtP);
    }

    /// @dev Uncollected fees (token0, token1) of position `i`: feeGrowthInside delta × liquidity / Q128
    ///      (wrapping subtraction). Price-independent. Used by NAV and by the withdraw fee-retention (C1).
    function _positionFees(uint8 i) internal view returns (uint256 fee0, uint256 fee1) {
        Position memory p = positions[i];
        if (p.liquidity == 0) return (0, 0);
        (, uint256 fg0Last, uint256 fg1Last) =
            poolManager.getPositionInfo(POOL_ID, address(positionManager), p.lower, p.upper, bytes32(p.tokenId));
        (uint256 fg0Cur, uint256 fg1Cur) = poolManager.getFeeGrowthInside(POOL_ID, p.lower, p.upper);
        unchecked {
            fee0 = FullMath.mulDiv(fg0Cur - fg0Last, p.liquidity, Q128);
            fee1 = FullMath.mulDiv(fg1Cur - fg1Last, p.liquidity, Q128);
        }
    }

    /// @dev Value (amt0, amt1) in USDC (6dp): USDC leg as-is + USDT leg priced at pool spot (§2).
    function _valueUSDC(uint256 amt0, uint256 amt1, uint160 sqrtP) internal view returns (uint256) {
        if (usdcIsToken0) {
            return amt0 + _usdtToUsdc(amt1, sqrtP);
        } else {
            return amt1 + _usdtToUsdc(amt0, sqrtP);
        }
    }

    /**
     * @dev Convert a USDT amount to USDC terms at pool spot, both 6dp (§2). price = (sqrtP/2^96)^2 is
     *      token1/token0. Computed via two FullMath.mulDiv to avoid forming a lossy intermediate P.
     */
    function _usdtToUsdc(uint256 usdtAmt, uint160 sqrtP) internal view returns (uint256) {
        if (usdtAmt == 0) return 0;
        if (usdcIsToken0) {
            // USDC=token0, USDT=token1 → USDC per USDT = 1/price = (2^96/sqrtP)^2
            uint256 t = FullMath.mulDiv(usdtAmt, FixedPoint96.Q96, sqrtP);
            return FullMath.mulDiv(t, FixedPoint96.Q96, sqrtP);
        } else {
            // USDT=token0, USDC=token1 → USDC per USDT = price = (sqrtP/2^96)^2
            uint256 t = FullMath.mulDiv(usdtAmt, sqrtP, FixedPoint96.Q96);
            return FullMath.mulDiv(t, sqrtP, FixedPoint96.Q96);
        }
    }

    /// @dev Spot USDC-per-USDT in WAD, for the peg-band guard. Reverts cleanly on an uninitialized pool
    ///      (sqrtP=0) so both token orderings fail identically rather than via a raw mulDiv panic.
    function _spotPriceWad(uint160 sqrtP) internal view returns (uint256) {
        if (sqrtP == 0) revert NotInitialized();
        return _usdtToUsdc(WAD, sqrtP);
    }

    function _pegOk(uint160 sqrtP) internal view returns (bool) {
        uint256 p = _spotPriceWad(sqrtP);
        return p >= pegLow && p <= pegHigh;
    }

    /// @dev Spot sqrtPrice CLAMPED into the peg-band sqrt bounds — the price used for ALL NAV valuation.
    ///      Bounds in-block spot manipulation of NAV to the band (C2). The peg CHECK still uses raw spot.
    function _navSqrt() internal view returns (uint160 s) {
        s = _sqrtPriceX96();
        if (s < navSqrtLow) s = navSqrtLow;
        else if (s > navSqrtHigh) s = navSqrtHigh;
    }

    /// @dev Recompute the NAV price-clamp band from pegLow/pegHigh (token-order aware). Called on init/setPegBand.
    function _recomputeNavSqrtBounds() internal {
        uint160 a = _priceWadToSqrt(pegLow);
        uint160 b = _priceWadToSqrt(pegHigh);
        (navSqrtLow, navSqrtHigh) = a < b ? (a, b) : (b, a);
    }

    /// @dev Pool sqrtPriceX96 whose `_spotPriceWad` equals `priceWad` (USDC-per-USDT), honouring token order.
    ///      usdcIsToken0: pool price = 1/P ⇒ sqrt = √(WAD·2^192 / P); else pool price = P ⇒ sqrt = √(P·2^192 / WAD).
    function _priceWadToSqrt(uint256 priceWad) internal view returns (uint160) {
        uint256 ratio = usdcIsToken0
            ? FullMath.mulDiv(WAD, uint256(1) << 192, priceWad)
            : FullMath.mulDiv(priceWad, uint256(1) << 192, WAD);
        return uint160(Math.sqrt(ratio));
    }

    /// @dev Credit token0/token1 amounts to the accounted idle counters. Donation-proof: callers pass
    ///      DELTAS of the vault's own operations, never absolute balances.
    function _creditIdle(uint256 amt0, uint256 amt1) internal {
        (uint256 u, uint256 t) = usdcIsToken0 ? (amt0, amt1) : (amt1, amt0);
        idleUSDC += u;
        idleUSDT += t;
    }

    /// @dev Apply the signed token-balance change since (b0,b1) to the idle counters (C3 residual fold-in).
    ///      Delta-based ⇒ donation-proof; floors at 0 so a donated token pulled into a position can't underflow.
    function _reconcileIdle(uint256 b0, uint256 b1) internal {
        (uint256 a0, uint256 a1) = _tokenBalances();
        (uint256 bU, uint256 bT) = usdcIsToken0 ? (b0, b1) : (b1, b0);
        (uint256 aU, uint256 aT) = usdcIsToken0 ? (a0, a1) : (a1, a0);
        idleUSDC = aU >= bU ? idleUSDC + (aU - bU) : _subFloor(idleUSDC, bU - aU);
        idleUSDT = aT >= bT ? idleUSDT + (aT - bT) : _subFloor(idleUSDT, bT - aT);
    }

    function _subFloor(uint256 x, uint256 y) internal pure returns (uint256) {
        return x > y ? x - y : 0;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Amounts-for-range sizing (§10c)
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @dev Size a target range to a USDC value (§10c). Off-pool swaps leave the vault-pool price P
     *      fixed, so this closed-form sizing is valid: trial L → value-per-L → scale → liquidity.
     */
    function _amountsForRange(int24 lower, int24 upper, uint256 valueUSDC)
        internal
        view
        returns (uint256 amt0, uint256 amt1, uint128 liquidity)
    {
        if (valueUSDC == 0) return (0, 0, 0);
        uint160 sqrtP = _sqrtPriceX96();
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        uint160 sqrtClamped = sqrtP < sqrtA ? sqrtA : (sqrtP > sqrtB ? sqrtB : sqrtP);

        uint128 trialL = uint128(WAD);
        uint256 t0 = SqrtPriceMath.getAmount0Delta(sqrtClamped, sqrtB, trialL, true);
        uint256 t1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtClamped, trialL, true);
        uint256 valuePerL = _valueUSDC(t0, t1, sqrtP);
        if (valuePerL == 0) return (0, 0, 0);

        uint256 L = FullMath.mulDiv(valueUSDC, WAD, valuePerL);
        if (L > type(uint128).max) revert AmountTooLarge();

        amt0 = SqrtPriceMath.getAmount0Delta(sqrtClamped, sqrtB, uint128(L), true);
        amt1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtClamped, uint128(L), true);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtA, sqrtB, amt0, amt1);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Liquidity plumbing — PositionManager (§10a)
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @dev MINT_POSITION + SETTLE_PAIR (§10a). Learns tokenId via nextTokenId(); vault holds the NFT.
     *      Liquidity is sized to the tokens ACTUALLY available, capped by (amt0Max, amt1Max) — the
     *      position's earmark. This (a) prevents the mint from draining idle/other earmarks (the maxes
     *      bound the pull), and (b) prevents a revert when a swap underdelivers by a few bps (liquidity
     *      shrinks to fit). Both maxes double as the SETTLE_PAIR slippage bounds.
     */
    function _mintInto(uint8 i, int24 lower, int24 upper, uint256 amt0Max, uint256 amt1Max) internal {
        (uint256 bal0, uint256 bal1) = _tokenBalances();
        uint128 max0 = uint128(bal0 < amt0Max ? bal0 : amt0Max);
        uint128 max1 = uint128(bal1 < amt1Max ? bal1 : amt1Max);

        uint160 sqrtP = _sqrtPriceX96();
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), max0, max1
        );
        if (liquidity == 0) return;

        uint256 tokenId = positionManager.nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(_poolKey(), lower, upper, uint256(liquidity), max0, max1, address(this), bytes(""));
        params[1] = abi.encode(C0, C1);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        positions[i].tokenId = tokenId;
        positions[i].lower = lower;
        positions[i].upper = upper;
        positions[i].liquidity = liquidity;
    }

    /// @dev DECREASE_LIQUIDITY + TAKE_PAIR for `liq`. Returns token0/token1 actually received (§10a).
    function _decrease(uint8 i, uint128 liq) internal returns (uint256 got0, uint256 got1) {
        if (liq == 0) return (0, 0);
        (uint256 b0, uint256 b1) = _tokenBalances();

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positions[i].tokenId, uint256(liq), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(C0, C1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        positions[i].liquidity -= liq;
        (uint256 a0, uint256 a1) = _tokenBalances();
        got0 = a0 - b0;
        got1 = a1 - b1;
    }

    /// @dev BURN_POSITION + TAKE_PAIR. Removes ALL remaining liquidity + fees; clears position (§10a).
    function _burnPosition(uint8 i) internal returns (uint256 got0, uint256 got1) {
        uint256 tokenId = positions[i].tokenId;
        if (tokenId == 0) return (0, 0);
        (uint256 b0, uint256 b1) = _tokenBalances();

        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(C0, C1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        positions[i].tokenId = 0;
        positions[i].liquidity = 0;
        (uint256 a0, uint256 a1) = _tokenBalances();
        got0 = a0 - b0;
        got1 = a1 - b1;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Off-pool swaps — primary + backup, never the vault pool (§10b)
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Two-tier exact-in swap (§10b): primary `swapPoolKey` via UniversalRouter, else
     *         `backupRouter`. Both tiers run inside a self-call that asserts a two-sided balance
     *         guard and reverts on violation — so a failed tier leaves NO net token movement.
     *         Returns (out, ok); ok=false (both failed) lets the caller degrade gracefully.
     */
    function _swapExactInOffPool(address tokenIn, uint256 amtIn, uint256 minOut)
        internal
        returns (uint256 out, bool ok)
    {
        if (amtIn == 0) return (0, false);
        if (amtIn > type(uint128).max) return (0, false);
        address tokenOut = tokenIn == address(USDC) ? address(USDT) : address(USDC);

        try this._guardedSwap(tokenIn, tokenOut, amtIn, minOut, false) returns (uint256 o) {
            return (o, true);
        } catch {
            if (backupRouter != address(0)) {
                try this._guardedSwap(tokenIn, tokenOut, amtIn, minOut, true) returns (uint256 o2) {
                    return (o2, true);
                } catch {}
            }
        }
        return (0, false);
    }

    /// @dev Self-only guarded swap: executes one tier, then asserts spent ≤ amtIn AND received ≥ minOut.
    function _guardedSwap(address tokenIn, address tokenOut, uint256 amtIn, uint256 minOut, bool useBackup)
        external
        returns (uint256 out)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        if (useBackup) {
            IERC20(tokenIn).forceApprove(backupRouter, amtIn);
            IBackupSwapRouter(backupRouter).swapExactIn(tokenIn, tokenOut, amtIn, minOut, address(this));
            IERC20(tokenIn).forceApprove(backupRouter, 0);
        } else {
            _primarySwap(tokenIn, amtIn, minOut);
        }

        uint256 spent = inBefore - IERC20(tokenIn).balanceOf(address(this));
        out = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        // Two-sided guard (§10b): bounds ANY route to "spent ≤ in, received ≥ out".
        if (!(spent <= amtIn && out >= minOut && out > 0)) revert SlippageExceeded();
    }

    /// @dev PRIMARY: single-hop exact-in on `swapPoolKey` via UniversalRouter V4_SWAP (§10b).
    function _primarySwap(address tokenIn, uint256 amtIn, uint256 minOut) internal {
        PoolKey memory sk = swapPoolKey;
        if (_samePool(sk.toId(), POOL_ID)) revert SwapPoolIsVaultPool();
        bool zeroForOne = (tokenIn == Currency.unwrap(sk.currency0));
        Currency cIn = zeroForOne ? sk.currency0 : sk.currency1;
        Currency cOut = zeroForOne ? sk.currency1 : sk.currency0;

        // Per-swap exact Permit2 allowance to the router (§10b "no standing max" at the spender layer).
        PERMIT2.approve(tokenIn, address(universalRouter), uint160(amtIn), type(uint48).max);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: sk,
                zeroForOne: zeroForOne,
                amountIn: uint128(amtIn),
                amountOutMinimum: uint128(minOut),
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(cIn, amtIn);
        params[2] = abi.encode(cOut, minOut);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        universalRouter.execute(commands, inputs, block.timestamp);
    }

    /**
     * @dev Swap held (have0, have1) toward target (amt0, amt1) with a single exact-in off-pool swap.
     *      Stables ~1:1 6dp/6dp, so converting the excess leg lands close to the target. Returns false
     *      if the required swap could not be filled.
     */
    function _swapToTarget(uint256 have0, uint256 have1, uint256 amt0, uint256 amt1) internal returns (bool) {
        if (have0 > amt0) {
            uint256 sell = have0 - amt0; // sell token0 → token1
            address tIn = usdcIsToken0 ? address(USDC) : address(USDT);
            if (sell > 0) {
                (, bool ok) = _swapExactInOffPool(tIn, sell, _minOut(sell));
                return ok;
            }
        } else if (have1 > amt1) {
            uint256 sell = have1 - amt1; // sell token1 → token0
            address tIn = usdcIsToken0 ? address(USDT) : address(USDC);
            if (sell > 0) {
                (, bool ok) = _swapExactInOffPool(tIn, sell, _minOut(sell));
                return ok;
            }
        }
        return true; // already balanced (or nothing to sell)
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Admin (§12)
    // ─────────────────────────────────────────────────────────────────────────────

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit Paused(p);
    }

    function setSwapVenue(PoolKey calldata _swapPoolKey, address _backupRouter) external onlyOwner {
        if (_samePool(_swapPoolKey.toId(), POOL_ID)) revert SwapPoolIsVaultPool();
        swapPoolKey = _swapPoolKey;
        backupRouter = _backupRouter;
        emit SwapVenueUpdated(_swapPoolKey, _backupRouter);
    }

    function setBands(uint256 _rebalanceBand, uint256 _reentryBand, uint256 _minWidth, uint256 _maxWidth)
        external
        onlyOwner
    {
        rebalanceBand = _rebalanceBand;
        reentryBand = _reentryBand;
        minWidth = _minWidth;
        maxWidth = _maxWidth;
    }

    function setPegBand(uint256 _pegLow, uint256 _pegHigh) external onlyOwner {
        pegLow = _pegLow;
        pegHigh = _pegHigh;
        _recomputeNavSqrtBounds(); // keep the NAV clamp in sync with the peg band (C2)
    }

    function setRiskParams(uint16 _bufferBps, uint16 _swapMaxSlippageBps, uint256 _rebalanceGasCap)
        external
        onlyOwner
    {
        bufferBps = _bufferBps;
        swapMaxSlippageBps = _swapMaxSlippageBps;
        rebalanceGasCap = _rebalanceGasCap;
    }

    /// @notice One-time Permit2 approvals (§10a/§13): token→Permit2 (max) and Permit2→spender for
    ///         {PositionManager, UniversalRouter}, for both USDC and USDT. Owner-callable, idempotent.
    function approveAll() external onlyOwner {
        _approveViaPermit2(USDC, address(positionManager));
        _approveViaPermit2(USDC, address(universalRouter));
        _approveViaPermit2(USDT, address(positionManager));
        _approveViaPermit2(USDT, address(universalRouter));
    }

    function _approveViaPermit2(IERC20 token, address spender) internal {
        token.forceApprove(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(token), spender, type(uint160).max, type(uint48).max);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Misc helpers
    // ─────────────────────────────────────────────────────────────────────────────

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({currency0: C0, currency1: C1, fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: HOOKS});
    }

    function _sqrtPriceX96() internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = poolManager.getSlot0(POOL_ID);
    }

    function _samePool(PoolId a, PoolId b) internal pure returns (bool) {
        return PoolId.unwrap(a) == PoolId.unwrap(b);
    }

    function _tokenBalances() internal view returns (uint256 b0, uint256 b1) {
        b0 = IERC20(Currency.unwrap(C0)).balanceOf(address(this));
        b1 = IERC20(Currency.unwrap(C1)).balanceOf(address(this));
    }

    function _minOut(uint256 amtIn) internal view returns (uint256) {
        return FullMath.mulDiv(amtIn, BPS - swapMaxSlippageBps, BPS);
    }

    function _validRange(int24 lower, int24 upper) internal view returns (bool) {
        if (lower >= upper) return false;
        uint256 width = uint256(int256(upper) - int256(lower));
        return width >= minWidth && width <= maxWidth;
    }

    function _absDiff(int24 a, int24 b) internal pure returns (uint256) {
        return a >= b ? uint256(int256(a) - int256(b)) : uint256(int256(b) - int256(a));
    }

    /// @dev Round a tick delta down to a multiple of tickSpacing (≥ one spacing).
    function _align(int24 ticks) internal view returns (int24) {
        int24 s = TICK_SPACING;
        int24 a = (ticks / s) * s;
        return a < s ? s : a;
    }

    function _clampTick(int24 t) internal view returns (int24) {
        if (t < fullRangeLower) return fullRangeLower;
        if (t > fullRangeUpper) return fullRangeUpper;
        // align to spacing
        int24 s = TICK_SPACING;
        return (t / s) * s;
    }
}
