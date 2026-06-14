// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/**
 * @title VaultHook — distribution hook for the 1-click single-token vault
 * @notice On every swap this hook cheaply records a *time-decayed distribution* of where price
 *         trades, and exposes {computeRanges} which turns that distribution into nested percentile
 *         bands (e.g. 90% / 99% / 99.9%) — the three master LP positions the vault deploys.
 *
 * @dev Singleton: one deployment serves many pools; all state is keyed by `PoolId`.
 *
 *      Decay is implemented by *inflating increments on write* rather than shrinking old weights:
 *      each new increment is scaled by a global growth factor `g = exp(ln2 * dt / halfLife)` that
 *      doubles every half-life. Because `g` is identical for every tick at a given instant, it
 *      cancels in the percentile *ratios* read by {computeRanges} — so the read path needs no decay
 *      math and the swap path stays O(1). See the architecture brief for the full derivation.
 *
 *      Only the absolute {MIN_DATA} sufficiency gate needs `g` (an absolute threshold does not
 *      cancel), so {computeRanges} normalises the summed weight back to "now" before comparing.
 */
contract VaultHook is BaseHook, Ownable {
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    // --- weighting modes ---
    uint8 internal constant COUNT = 0; // +1.0 per swap (default)
    uint8 internal constant VOLUME = 1; // +|amount0| per swap

    // --- fixed point ---
    uint256 internal constant WAD = 1e18;
    uint256 internal constant LN2_WAD = 693147180559945309; // ln(2) * 1e18
    /// @dev Clamp on the decay exponent. solady's expWad reverts at ~135.3e18; staying under it
    ///      guarantees a swap never reverts even if a rebase is badly overdue (decay just saturates).
    uint256 internal constant MAX_EXP = 100e18;

    // --- config bounds / defaults ---
    uint32 internal constant DEFAULT_HALF_LIFE = 30 days;
    uint32 internal constant MIN_HALF_LIFE = 1 days;
    uint32 internal constant MAX_HALF_LIFE = 365 days;
    /// @dev Default sufficiency floor, expressed as decay-normalised weight (WAD). For count
    ///      weighting this is ~"effective recent swaps", so 3e18 ≈ 3 recent swaps. Deliberately low
    ///      so a freshly-seeded pool produces ranges after only a few swaps; tune via {setConfig}.
    uint256 internal constant DEFAULT_MIN_DATA = 3e18;
    /// @dev Guardrails on owner-set `minData`: 0 would disable the sentinel (reposition on noise);
    ///      an absurdly large value would starve the vault of usable ranges forever.
    uint256 internal constant MIN_MIN_DATA = 1e18; // ~1 effective recent swap
    uint256 internal constant MAX_MIN_DATA = 1e30;

    /// @dev Default half-width of the capture window, in raw ticks, applied symmetrically around the
    ///      pool's initial (peg) tick. ~500 ticks ≈ ±5% in price (≈ 0.951–1.051). Swaps landing
    ///      outside the window are ignored, which keeps the distribution focused and bounds the
    ///      min/max scan range (so the vault's computeRanges/rebase gas). Tune via {setCaptureWindow}.
    int24 internal constant CAPTURE_HALF_WIDTH = 500;

    /// @dev Default auto-rebase cadence: {poke} renormalises a pool once this much time has elapsed
    ///      since the last epoch. Frequent + cheap; keeps stored magnitudes small and `g` near 1.
    uint32 internal constant DEFAULT_REBASE_INTERVAL = 7 days;
    uint32 internal constant MIN_REBASE_INTERVAL = 1 days;
    uint32 internal constant MAX_REBASE_INTERVAL = 365 days;
    /// @dev On each rebase, prune ticks holding less than `total / pruneFraction` — i.e. decayed to
    ///      negligible — and re-tighten the scan bounds to the survivors. How fast a tick reaches
    ///      this dust threshold is governed by the half-life, not the rebase cadence. Per-pool
    ///      configurable (see {setPruneFraction}); a larger value prunes less aggressively.
    ///
    ///      Default `1e4` ⇒ dust = 0.01% of total: comfortably below the tightest band's tail
    ///      (99.9% trims 0.05% per side = total/2000), so pruning clears stray MEV ticks without
    ///      ever clipping a live band. `MIN_PRUNE_FRACTION = 2000` caps the *most aggressive* setting
    ///      at exactly that 99.9% tail granularity; `0` is the sentinel for "pruning disabled".
    uint256 internal constant DEFAULT_PRUNE_FRACTION = 1e4;
    uint256 internal constant MIN_PRUNE_FRACTION = 2000;

    struct PoolDist {
        // histogram (sparse; bitmap gives sorted iteration), keyed by COMPRESSED tick
        mapping(int16 => uint256) bitmap; // 1 bit per compressed tick = "has weight"
        mapping(int24 => uint256) weight; // decay-inflated weight per compressed tick (WAD)
        int24 minTick; // lowest compressed tick ever touched (scan lower bound)
        int24 maxTick; // highest compressed tick ever touched (scan upper bound)
        // decay clock
        uint32 t0; // epoch start; reference for the growth factor & rebase
        // config
        uint32 halfLife; // seconds
        uint8 weighting; // COUNT | VOLUME
        int24 tickSpacing; // cached from PoolKey at init
        int24 captureLowerTick; // compressed; swaps landing below this are ignored
        int24 captureUpperTick; // compressed; swaps landing above this are ignored
        uint32 rebaseInterval; // seconds between auto-rebases via poke()
        bool initialized;
        bool started; // set once the first weight is recorded; locks `weighting` thereafter
        uint256 minData; // sufficiency floor (decay-normalised WAD)
        uint256 pruneFraction; // rebase prunes ticks < total/pruneFraction; 0 = pruning disabled
    }

    /// @notice A percentile band returned to the vault: `[tickLower, tickUpper]` in *raw* ticks.
    struct Range {
        int24 tickLower;
        int24 tickUpper;
    }

    mapping(PoolId => PoolDist) internal pools;

    error NotInitialized();
    error InvalidHalfLife();
    error InvalidWeighting();
    error InvalidMinData();
    error InvalidConfidence();
    error WeightingLocked();
    error InvalidCaptureWindow();
    error InvalidRebaseInterval();
    error InvalidPruneFraction();

    event Rebased(PoolId indexed id, uint256 factor);
    event ConfigUpdated(PoolId indexed id, uint32 halfLife, uint8 weighting, uint256 minData);
    event CaptureWindowUpdated(PoolId indexed id, int24 lowerTick, int24 upperTick);

    constructor(IPoolManager _poolManager, address initialOwner) BaseHook(_poolManager) Ownable(initialOwner) {}

    // -------------------------------------------------------------------------
    // Hook permissions
    // -------------------------------------------------------------------------

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // seed config + decay clock + tick bounds
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true, // capture path
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false, // returns 0 delta
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -------------------------------------------------------------------------
    // afterInitialize — cold-pool seeding
    // -------------------------------------------------------------------------

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolDist storage P = pools[key.toId()];
        int24 spacing = key.tickSpacing;
        int24 c = _compress(tick, spacing);

        P.tickSpacing = spacing;
        P.t0 = uint32(block.timestamp);
        P.halfLife = DEFAULT_HALF_LIFE;
        P.weighting = COUNT;
        P.minData = DEFAULT_MIN_DATA;
        P.rebaseInterval = DEFAULT_REBASE_INTERVAL;
        P.pruneFraction = DEFAULT_PRUNE_FRACTION;
        // Capture window ≈ ±5% around the init (peg) tick. Initialise the pool at the peg.
        P.captureLowerTick = _compress(tick - CAPTURE_HALF_WIDTH, spacing);
        P.captureUpperTick = _compress(tick + CAPTURE_HALF_WIDTH, spacing);
        // Seed bounds so the first swap's min/max comparison is against a real tick, not 0.
        // No bitmap bit / weight is set yet: the first swap creates those.
        P.minTick = c;
        P.maxTick = c;
        P.initialized = true;

        return IHooks.afterInitialize.selector;
    }

    // -------------------------------------------------------------------------
    // afterSwap — the O(1) capture path
    // -------------------------------------------------------------------------

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        PoolDist storage P = pools[id];

        // Landing tick = post-swap current tick.
        (, int24 tick,,) = poolManager.getSlot0(id);
        int24 c = _compress(tick, P.tickSpacing);

        // Ignore swaps landing outside the capture window: keeps the distribution focused on the
        // useful range and bounds the min/max scan that the vault pays for at mint/burn.
        if (c < P.captureLowerTick || c > P.captureUpperTick) {
            return (IHooks.afterSwap.selector, int128(0));
        }

        uint256 g = _growthFactor(P);
        uint256 amount = (P.weighting == COUNT) ? WAD : _volumeOf(delta);

        // stored increment = amount * g / WAD. fullMulDiv keeps the intermediate product in 512 bits
        // so a saturated `g` cannot make this revert. A zero-volume swap records nothing (and so
        // never leaves a weightless bit in the bitmap).
        uint256 increment = FixedPointMathLib.fullMulDiv(amount, g, WAD);
        if (increment == 0) return (IHooks.afterSwap.selector, int128(0));

        uint256 w = P.weight[c];
        if (w == 0) {
            // First time this tick carries weight: set its bitmap bit and extend the scan bounds.
            _flipBit(P, c);
            if (c < P.minTick) P.minTick = c;
            if (c > P.maxTick) P.maxTick = c;
        }
        P.weight[c] = w + increment;
        if (!P.started) P.started = true;

        return (IHooks.afterSwap.selector, int128(0));
    }

    // -------------------------------------------------------------------------
    // computeRanges — the percentile read (view; vault pays the SLOADs at mint/burn)
    // -------------------------------------------------------------------------

    /**
     * @notice Walk the distribution once and extract nested percentile bands.
     * @param id Pool to read.
     * @param confidencesBps Confidence levels in bps, each in `[0, 10000]`, e.g. `[9000, 9900, 9990]`.
     *        Order is preserved: `ranges[i]` is the band for `confidencesBps[i]` (pass ascending to
     *        get nested-by-index bands). Reverts {InvalidConfidence} if any entry exceeds 10000.
     * @return ranges One `[tickLower, tickUpper]` (raw, tickSpacing-aligned) per confidence.
     * @return ok False when there is too little (decay-normalised) data to reposition on; the vault
     *         must then hold its positions / use a safe wide default. When false, `ranges` is zeroed.
     */
    function computeRanges(PoolId id, uint16[] calldata confidencesBps)
        external
        view
        returns (Range[] memory ranges, bool ok)
    {
        uint256 nConf = confidencesBps.length;
        for (uint256 i; i < nConf; i++) {
            if (confidencesBps[i] > 10000) revert InvalidConfidence();
        }
        ranges = new Range[](nConf);

        PoolDist storage P = pools[id];
        if (!P.initialized) return (ranges, false);

        (int24[] memory cs, uint256[] memory ws, uint256 total) = _collect(P);
        if (cs.length == 0) return (ranges, false);

        // Sufficiency gate. The decay factor does NOT cancel for an absolute threshold, so compare
        // against MIN_DATA scaled up to the current epoch: total < minData * g / WAD.
        if (total < FixedPointMathLib.fullMulDiv(P.minData, _growthFactor(P), WAD)) {
            return (ranges, false);
        }

        ranges = _extractRanges(cs, ws, total, confidencesBps, P.tickSpacing);
        ok = true;
    }

    /// @dev Walk the bitmap once (per word, ascending) and return the touched compressed ticks with
    ///      their weights, in ascending order, plus the summed total. Two passes over the bitmap
    ///      words (count, then fill); the second pass's word SLOADs are warm.
    function _collect(PoolDist storage P)
        internal
        view
        returns (int24[] memory cs, uint256[] memory ws, uint256 total)
    {
        int16 minWord = _wordPos(P.minTick);
        int16 maxWord = _wordPos(P.maxTick);

        uint256 count;
        for (int16 word = minWord;; word++) {
            uint256 bits = P.bitmap[word];
            while (bits != 0) {
                count++;
                bits &= bits - 1; // Kernighan: clear lowest set bit
            }
            if (word == maxWord) break;
        }

        cs = new int24[](count);
        ws = new uint256[](count);
        if (count == 0) return (cs, ws, 0);

        uint256 idx;
        for (int16 word = minWord;; word++) {
            uint256 bits = P.bitmap[word];
            while (bits != 0) {
                uint8 lsb = BitMath.leastSignificantBit(bits);
                int24 c = int24(word) * 256 + int24(uint24(lsb));
                uint256 w = P.weight[c];
                cs[idx] = c;
                ws[idx] = w;
                total += w;
                idx++;
                bits &= bits - 1;
            }
            if (word == maxWord) break;
        }
    }

    /// @dev Turn the (ascending) histogram into nested percentile bands in a single sweep.
    ///      `thresholds`/`crossings` are flattened: index `2j` = lower side, `2j+1` = upper side of
    ///      confidence `j`. A crossing left at the int24-min sentinel means "not yet reached".
    function _extractRanges(
        int24[] memory cs,
        uint256[] memory ws,
        uint256 total,
        uint16[] calldata confidencesBps,
        int24 spacing
    ) internal pure returns (Range[] memory ranges) {
        uint256 n = confidencesBps.length;
        uint256 m = 2 * n;
        uint256[] memory thresholds = new uint256[](m);
        int24[] memory crossings = new int24[](m);
        for (uint256 j; j < n; j++) {
            // confidencesBps entries are validated <= 10000 by the caller (computeRanges).
            uint256 tail = (10000 - uint256(confidencesBps[j])) / 2;
            thresholds[2 * j] = FixedPointMathLib.fullMulDiv(total, tail, 10000);
            thresholds[2 * j + 1] = FixedPointMathLib.fullMulDiv(total, 10000 - tail, 10000);
            crossings[2 * j] = type(int24).min;
            crossings[2 * j + 1] = type(int24).min;
        }

        uint256 cum;
        for (uint256 i; i < cs.length; i++) {
            cum += ws[i];
            for (uint256 k; k < m; k++) {
                if (crossings[k] == type(int24).min && cum >= thresholds[k]) crossings[k] = cs[i];
            }
        }

        // Decompress (× tickSpacing → already aligned) and guarantee a non-degenerate range.
        ranges = new Range[](n);
        for (uint256 j; j < n; j++) {
            int24 lower = crossings[2 * j] * spacing;
            int24 upper = crossings[2 * j + 1] * spacing;
            if (upper <= lower) upper = lower + spacing;
            ranges[j] = Range(lower, upper);
        }

        // Enforce nesting by index: with ascending confidences each band must contain the previous
        // (tighter) one. The raw crossings are already nested, but the per-band degenerate-widen
        // above can push a collapsed inner band's upper one spacing past an equal-width outer band,
        // breaking containment. Grow each band outward to cover its predecessor so ranges[j-1] ⊆
        // ranges[j] always holds. (No-op when no band collapsed, so dense distributions are unchanged.)
        for (uint256 j = 1; j < n; j++) {
            if (ranges[j].tickLower > ranges[j - 1].tickLower) ranges[j].tickLower = ranges[j - 1].tickLower;
            if (ranges[j].tickUpper < ranges[j - 1].tickUpper) ranges[j].tickUpper = ranges[j - 1].tickUpper;
        }
    }

    // -------------------------------------------------------------------------
    // Rebase — owner-only renormalisation (keeps `g` far from any ceiling)
    // -------------------------------------------------------------------------

    /// @notice Force a rebase now (owner). Routine maintenance normally happens via {poke}.
    function rebase(PoolId id) external onlyOwner {
        PoolDist storage P = pools[id];
        if (!P.initialized) revert NotInitialized();
        emit Rebased(id, _rebase(P));
    }

    /// @notice Permissionlessly rebase a pool once its interval has elapsed; a cheap no-op otherwise.
    ///         The vault calls this at mint/burn so pools self-maintain with no keeper — and swappers
    ///         never pay for a rebase. Anyone may call it.
    function poke(PoolId id) public {
        PoolDist storage P = pools[id];
        if (P.initialized && block.timestamp - P.t0 >= P.rebaseInterval) {
            emit Rebased(id, _rebase(P));
        }
    }

    /// @notice Set the per-pool auto-rebase cadence (owner). Bounded to a sane range.
    function setRebaseInterval(PoolId id, uint32 interval) external onlyOwner {
        PoolDist storage P = pools[id];
        if (!P.initialized) revert NotInitialized();
        if (interval < MIN_REBASE_INTERVAL || interval > MAX_REBASE_INTERVAL) revert InvalidRebaseInterval();
        P.rebaseInterval = interval;
    }

    /// @notice Set the per-pool prune aggressiveness (owner). On rebase, up to `total / fraction` of
    ///         cumulative weight is trimmed from each tail (never interior ticks). A larger `fraction`
    ///         prunes less; `0` disables tail pruning entirely. Non-zero values must be ≥
    ///         {MIN_PRUNE_FRACTION} so a fat-finger can't set a tail budget that reaches a live band.
    function setPruneFraction(PoolId id, uint256 fraction) external onlyOwner {
        PoolDist storage P = pools[id];
        if (!P.initialized) revert NotInitialized();
        if (fraction != 0 && fraction < MIN_PRUNE_FRACTION) revert InvalidPruneFraction();
        P.pruneFraction = fraction;
    }

    /// @dev Divide every weight by the current growth factor `R` and reset the epoch — this changes
    ///      no ratios, so the percentile bands are identical pre/post. Then prune the negligible
    ///      tails (up to total / pruneFraction of cumulative weight from each end, never interior
    ///      ticks) and re-tighten the scan bounds to the survivors, so reads only walk the live
    ///      band without ever clipping it. Integer-division rounding is sub-wei.
    function _rebase(PoolDist storage P) internal returns (uint256 R) {
        R = _growthFactor(P);
        int16 minWord = _wordPos(P.minTick);
        int16 maxWord = _wordPos(P.maxTick);

        // Pass 1: renormalise every weight by R and sum the new total.
        uint256 newTotal;
        for (int16 word = minWord;; word++) {
            uint256 bits = P.bitmap[word];
            while (bits != 0) {
                uint8 lsb = BitMath.leastSignificantBit(bits);
                int24 c = int24(word) * 256 + int24(uint24(lsb));
                uint256 nw = FixedPointMathLib.fullMulDiv(P.weight[c], WAD, R);
                P.weight[c] = nw;
                newTotal += nw;
                bits &= bits - 1;
            }
            if (word == maxWord) break;
        }

        // Pass 2: prune the negligible tails and re-tighten the scan bounds (own frame: keeps the
        // legacy, non-via-ir stack from overflowing).
        _pruneTails(P, minWord, maxWord, newTotal);
        P.t0 = uint32(block.timestamp); // g back to 1
    }

    /// @dev Prune the negligible (decayed) TAILS of the distribution and re-tighten [minTick,
    ///      maxTick] to the survivors. Pruning trims at most `dust` of CUMULATIVE weight from each
    ///      END — never an interior tick — so a live confidence band is never clipped: a tick's own
    ///      weight is irrelevant, only its position in the cumulative tail matters. The bound is
    ///      strict (`< dust`) so even the most aggressive setting cannot reach the tightest band's
    ///      tail mass. Dead (rounded-to-zero) ticks are always swept. pruneFraction == 0 disables
    ///      tail pruning (dust == 0 then drops only zero-weight ticks).
    function _pruneTails(PoolDist storage P, int16 minWord, int16 maxWord, uint256 newTotal) internal {
        uint256 pf = P.pruneFraction; // cache: read once instead of twice across the ternary
        uint256 dust = pf == 0 ? 0 : newTotal / pf;
        int24 newMin = type(int24).max;
        int24 newMax = type(int24).min;
        bool any;
        uint256 cum; // running cumulative weight, low → high, over ALL ticks (pruned or not)
        for (int16 word = minWord;; word++) {
            uint256 bits = P.bitmap[word];
            uint256 clear; // bits to drop from this word; coalesced into one RMW after the inner loop
            while (bits != 0) {
                uint8 lsb = BitMath.leastSignificantBit(bits);
                int24 c = int24(word) * 256 + int24(uint24(lsb));
                uint256 w = P.weight[c];
                // Drop iff dead, or inside the bottom tail (cumulative-from-low, cum + w, < dust), or
                // inside the top tail (cumulative-from-high, newTotal - cum, < dust). `cum` here is
                // still the mass strictly below this tick.
                if (w == 0 || cum + w < dust || newTotal - cum < dust) {
                    clear |= uint256(1) << lsb; // defer the drop (clears are commutative)
                    delete P.weight[c]; // free the slot (gas refund)
                } else {
                    if (c < newMin) newMin = c;
                    if (c > newMax) newMax = c;
                    any = true;
                }
                cum += w;
                bits &= bits - 1;
            }
            // Apply all of this word's drops at once: one SLOAD+SSTORE per word, not per pruned bit.
            if (clear != 0) P.bitmap[word] &= ~clear;
            if (word == maxWord) break;
        }
        if (any) {
            P.minTick = newMin;
            P.maxTick = newMax;
        }
    }

    // -------------------------------------------------------------------------
    // Config & access control
    // -------------------------------------------------------------------------

    /// @notice Update per-pool config. Renormalises first (rebase) so a new `halfLife` takes effect
    ///         cleanly going forward.
    /// @dev `weighting` is locked once the pool has recorded any weight: switching it would mix the
    ///      units of stored weight with future increments, corrupting the distribution. Set it (if
    ///      ever) before the pool's first swap. `minData` is in decay-normalised WAD (see {MIN_MIN_DATA}).
    function setConfig(PoolId id, uint32 halfLife, uint8 weighting, uint256 minData) external onlyOwner {
        PoolDist storage P = pools[id];
        if (!P.initialized) revert NotInitialized();
        if (halfLife < MIN_HALF_LIFE || halfLife > MAX_HALF_LIFE) revert InvalidHalfLife();
        if (weighting > VOLUME) revert InvalidWeighting();
        if (minData < MIN_MIN_DATA || minData > MAX_MIN_DATA) revert InvalidMinData();
        if (weighting != P.weighting && P.started) revert WeightingLocked();

        _rebase(P); // renormalise at the OLD half-life, reset epoch
        P.halfLife = halfLife;
        P.weighting = weighting;
        P.minData = minData;
        emit ConfigUpdated(id, halfLife, weighting, minData);
    }

    /// @notice Set the per-pool capture window in raw ticks. Swaps landing outside `[lowerTick,
    ///         upperTick]` are ignored. Already-recorded out-of-window weight (if any) is left in
    ///         place; the bounds simply stop the window widening further.
    function setCaptureWindow(PoolId id, int24 lowerTick, int24 upperTick) external onlyOwner {
        PoolDist storage P = pools[id];
        if (!P.initialized) revert NotInitialized();
        if (lowerTick >= upperTick) revert InvalidCaptureWindow();
        P.captureLowerTick = _compress(lowerTick, P.tickSpacing);
        P.captureUpperTick = _compress(upperTick, P.tickSpacing);
        emit CaptureWindowUpdated(id, lowerTick, upperTick);
    }

    // -------------------------------------------------------------------------
    // Views (for the vault / observability)
    // -------------------------------------------------------------------------

    function poolConfig(PoolId id)
        external
        view
        returns (
            uint32 t0,
            uint32 halfLife,
            uint8 weighting,
            int24 tickSpacing,
            int24 minTick,
            int24 maxTick,
            uint256 minData,
            bool initialized
        )
    {
        PoolDist storage P = pools[id];
        return (P.t0, P.halfLife, P.weighting, P.tickSpacing, P.minTick, P.maxTick, P.minData, P.initialized);
    }

    /// @notice The pool's capture window in raw, tickSpacing-aligned ticks.
    function captureWindow(PoolId id) external view returns (int24 lowerTick, int24 upperTick) {
        PoolDist storage P = pools[id];
        return (P.captureLowerTick * P.tickSpacing, P.captureUpperTick * P.tickSpacing);
    }

    /// @notice The pool's auto-rebase cadence (seconds) and prune fraction (0 = pruning disabled).
    function rebaseConfig(PoolId id) external view returns (uint32 rebaseInterval, uint256 pruneFraction) {
        PoolDist storage P = pools[id];
        return (P.rebaseInterval, P.pruneFraction);
    }

    /// @notice Current decay growth factor `g` (WAD) for a pool; 0 if the pool is uninitialised.
    function growthFactor(PoolId id) external view returns (uint256) {
        PoolDist storage P = pools[id];
        if (!P.initialized) return 0;
        return _growthFactor(P);
    }

    /// @notice Stored (decay-inflated) weight at a raw tick. Mostly for tests/observability.
    function weightAt(PoolId id, int24 rawTick) external view returns (uint256) {
        PoolDist storage P = pools[id];
        if (!P.initialized) return 0; // tickSpacing is 0 here; avoid div-by-zero in _compress
        return P.weight[_compress(rawTick, P.tickSpacing)];
    }

    // -------------------------------------------------------------------------
    // Internal math
    // -------------------------------------------------------------------------

    /// @dev g(t) = exp(ln2 * (now - t0) / halfLife), WAD. Clamped so expWad never reverts.
    function _growthFactor(PoolDist storage P) internal view returns (uint256) {
        uint256 dt = block.timestamp - P.t0;
        uint256 expo = (LN2_WAD * dt) / P.halfLife;
        if (expo > MAX_EXP) expo = MAX_EXP;
        return uint256(FixedPointMathLib.expWad(int256(expo)));
    }

    /// @dev Volume measure for VOLUME weighting: |amount0| (token0 units).
    function _volumeOf(BalanceDelta delta) internal pure returns (uint256) {
        int128 a0 = delta.amount0();
        return uint256(uint128(a0 < 0 ? -a0 : a0));
    }

    /// @dev Floor division toward -∞ (Uniswap's tick compression).
    function _compress(int24 tick, int24 spacing) internal pure returns (int24 c) {
        c = tick / spacing;
        if (tick < 0 && tick % spacing != 0) c--;
    }

    /// @dev Bitmap word index for a compressed tick (arithmetic shift preserves sorted order).
    function _wordPos(int24 c) internal pure returns (int16) {
        return int16(c >> 8);
    }

    /// @dev Set the bitmap bit for compressed tick `c` (only ever called when its weight was 0).
    function _flipBit(PoolDist storage P, int24 c) internal {
        int16 wordPos = int16(c >> 8);
        uint8 bitPos = uint8(int8(c % 256));
        P.bitmap[wordPos] |= (uint256(1) << bitPos);
    }
}
