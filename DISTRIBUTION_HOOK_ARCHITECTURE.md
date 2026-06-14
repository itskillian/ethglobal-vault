# Distribution Hook — Architecture & Implementation Brief

> Spec for the distribution-hook codebase, kept in sync with `src/vaultHook.sol`.
> Read top-to-bottom before touching the contract.

---

## 0. Context & scope

We're building a **1-click single-token vault** on Uniswap v4. A user deposits one token
(e.g. USDC), receives an ERC20 credit share that appreciates as fees accrue (rETH-style),
and the vault deploys capital into **three master LP positions** whose ranges are set
algorithmically from where price actually trades.

**This codebase is the distribution hook only.** Its single job: on every swap, cheaply
record a *time-decayed distribution* of where price trades, and expose a function that turns
that distribution into three nested percentile ranges — **90% / 99% / 99.9% confidence
bands**. Those three bands are the vault's three positions (tight 90% band carries most
capital near price; wide 99.9% band is thin tail insurance).

Key facts:
- The hook does **not** set fees. A v4 pool has exactly one hook, so vault pools run this one.
- **Singleton hook:** one deployed contract serves many pools. **All state is keyed by `PoolId`.**
- The three positions are three **confidence bands** derived from a **single** decayed
  distribution. The exponential decay **half-life** (default 30 days, configurable per pool)
  *is* the lookback window — there is no multi-timeframe machinery.
- Only swaps landing inside a **capture window** (~±5% around the peg, per-pool) are recorded;
  out-of-range / MEV outliers are ignored (Section 2).
- Pools **self-maintain**: a permissionless `poke` renormalises and prunes on a cadence
  (default weekly), so neither a keeper nor the owner is needed for routine upkeep (Section 5).
- Base contracts: v4 `BaseHook` + OpenZeppelin `Ownable`. The owner only tunes config and can
  *force* a rebase; routine rebase/prune is permissionless.

**Not in this codebase (the vault, a separate component):** ERC20 credit shares, single-token
zap/auto-swap, repositioning, NAV. The hook just exposes the ranges; the vault consumes them.

---

## 1. State (per pool)

Sparse histogram using Uniswap's tick-bitmap pattern, plus a decay clock and per-pool config.

```solidity
struct PoolDist {
    // --- histogram (sparse; bitmap gives sorted iteration) ---
    mapping(int16 => uint256) bitmap;   // 1 bit per COMPRESSED tick = "has weight"
    mapping(int24 => uint256) weight;   // decay-inflated weight per COMPRESSED tick (WAD)
    int24   minTick;                    // lowest compressed tick with weight (scan lower bound)
    int24   maxTick;                    // highest compressed tick with weight (scan upper bound)

    // --- decay clock ---
    uint32  t0;                         // epoch start; reference for the growth factor & rebase

    // --- config ---
    uint32  halfLife;                   // seconds (default 30 days)
    uint8   weighting;                  // 0 = count (default), 1 = volume; locked after first weight
    int24   tickSpacing;                // cached from PoolKey at init
    int24   captureLowerTick;           // compressed; swaps landing below are ignored
    int24   captureUpperTick;           // compressed; swaps landing above are ignored
    uint32  rebaseInterval;             // seconds between auto-rebases via poke() (default 7 days)
    bool    initialized;
    bool    started;                    // set on first recorded weight; locks `weighting`
    uint256 minData;                    // sufficiency floor, decay-normalised WAD (default 3e18)
    uint256 pruneFraction;              // rebase prunes ticks < total/pruneFraction; 0 = disabled
}

mapping(PoolId => PoolDist) internal pools;
```

- `bitmap` and `weight` are keyed by the **compressed** tick (`tick / tickSpacing`), exactly
  like Uniswap's `tickBitmap`. `minTick`/`maxTick` are stored compressed too. The vault
  receives **decompressed** (raw) ticks back from `computeRanges`.
- **No running `totalWeight` is stored** — it's summed during the read walk (Section 4).
  Keeping it on-chain would add an SSTORE to every swap for no benefit.
- One bitmap + one weight mapping handles both the dense core (price's usual band = a few
  full words) and rare outliers (a depeg spike = one lone set bit far away) — no special-
  casing of common vs rare ticks.
- The config fields (`halfLife`, `weighting`, `minData`, `captureLowerTick`/`captureUpperTick`,
  `rebaseInterval`, `pruneFraction`) are seeded with defaults at `afterInitialize` and are
  **per-pool, owner-tunable** (Section 6). `weighting` is the exception: it locks once
  `started` flips, because mixing count and volume units would corrupt the histogram.

---

## 2. Capture — `afterSwap` (the swap-path hot path)

On each swap, increment the **landing tick** (post-swap current tick) by an amount scaled by
the current growth factor — but only if the landing tick is inside the capture window. O(1).

```
afterSwap(sender, key, params, delta, hookData) -> (bytes4, int128):
    poolId = key.toId()
    P = pools[poolId]

    (, int24 tick, , ) = poolManager.getSlot0(poolId)     // StateLibrary; post-swap landing tick
    int24 c = compress(tick, P.tickSpacing)               // floor division — handle negatives!

    // Capture window: ignore swaps landing outside [captureLowerTick, captureUpperTick].
    if (c < P.captureLowerTick || c > P.captureUpperTick)
        return (IHooks.afterSwap.selector, 0)             // out of range / MEV — not recorded

    uint256 g         = growthFactor(P)                   // exp(λ·(now−t0)), WAD, clamped (Section 3)
    uint256 amount    = (P.weighting == COUNT) ? WAD : volumeOf(delta)   // WAD-scaled
    uint256 increment = fullMulDiv(amount, g, WAD)        // 512-bit intermediate; saturated g can't revert
    if (increment == 0) return (IHooks.afterSwap.selector, 0)   // zero-volume swap records nothing

    uint256 w = P.weight[c]
    if (w == 0) {                                         // first time this tick has weight
        flipBit(P.bitmap, c)                             // set bitmap bit
        if (c < P.minTick) P.minTick = c
        if (c > P.maxTick) P.maxTick = c
    }
    P.weight[c] = w + increment
    if (!P.started) P.started = true

    return (IHooks.afterSwap.selector, 0)                 // no delta adjustment
```

- **Landing tick = post-swap tick** (`getSlot0` in `afterSwap`). This is count/volume
  weighting of *where swaps land*, not time-in-tick weighting. Every captured swap counts,
  including multiple swaps in the same block.
- `compress` must floor toward negative infinity (Uniswap does:
  `compressed = tick / spacing; if (tick < 0 && tick % spacing != 0) compressed--`).
- **Count weighting (default):** `amount = WAD` (1.0 per swap).
- **Volume weighting (optional, via `weighting` flag):** `volumeOf(delta) = abs(amount0)`,
  scaled to WAD-comparable units. Volume overflows the growth factor sooner (Section 5), so
  count is the default. The increment uses `fullMulDiv` so even a saturated `g` cannot revert.

**Capture window.** Seeded at `afterInitialize` to `compress(initialTick ± CAPTURE_HALF_WIDTH)`
— ~±500 ticks ≈ ±5% in price (≈ 0.951–1.051) around the init (peg) tick — and owner-tunable
via `setCaptureWindow`. Its purpose is twofold:
- **Reject noise:** a one-off MEV sandwich or a far out-of-range swap never enters the
  distribution, so the bands reflect where price *actually trades*.
- **Bound the scan:** `minTick`/`maxTick` can only widen within the window, capping the number
  of words `computeRanges` and `rebase` walk (the cost the vault pays at mint/burn).

The trade-off: a genuine repeg beyond the window is not recorded until the owner widens it.
For a stable-pegged vault that's the intended behaviour; the owner moves the window on a real
repeg. Out-of-window weight recorded *before* a window tightening is left in place — the window
only stops the range widening further.

---

## 3. The growth / decay factor — how decay works

**Core idea: inflate increments on write; decay is invisible on read.** Instead of shrinking
old weights (which would mean touching every entry), each new increment is scaled *up* by a
factor that grows over time.

```
g(t) = exp(λ · (t − t0)),   λ = ln2 / halfLife        // doubles every half-life
stored increment = amount · g(now)
```

Why this is exactly exponential decay, with zero per-entry work:
- A tick's stored value is `Σ amountₖ · g(tₖ)` over the times it was hit.
- Its true decayed weight at read time `t_read` is `e^(−λ·t_read) · stored`.
- That factor `e^(−λ·t_read)` is the **same for every tick**, so in percentile *ratios*
  (`cum / total`) it **cancels**. ⇒ **The read path needs no decay math at all** — it's
  identical to a no-decay histogram. You only change the write.

Worked example (30-day half-life, one count per swap on the same tick):

| swap | day | g    | stored (+= 1·g) | true weight at day 60 (÷ g(60)=4) |
|------|-----|------|-----------------|-----------------------------------|
| 1    | 0   | 1.0  | 1.0             | 0.25  (2 half-lives → ¼)          |
| 2    | 30  | 2.0  | 2.0             | 0.50  (1 half-life → ½)           |
| 3    | 60  | 4.0  | 4.0             | 1.00  (fresh)                     |

Intuition: **you never shrink old data — you grow new data.** A later swap is *stored as a
bigger number*; as the global scale climbs, older (smaller-stored) entries fade in relative
terms. The factor is `exp(λ·t_swap)` — **exponential in absolute time, same for all ticks at
a given instant** — NOT linear in the gap since the last swap.

Fixed-point implementation (WAD = 1e18; use a fixed-point `expWad`, e.g. solady):

```
growthFactor(P):
    dt   = block.timestamp - P.t0
    expo = ln2Wad * dt / P.halfLife          // WAD; ln2Wad ≈ 6.931e17
    if (expo > MAX_EXP) expo = MAX_EXP        // clamp (~100e18) so expWad never reverts
    return uint256(expWad(int256(expo)))      // WAD; = 1e18 at dt = 0, 2e18 after one half-life
```

- `halfLife` is per-pool config (default 30 days). Changing it live must be done via a rebase
  + epoch reset (takes effect going forward), so treat it as set-once-tune-rarely. `setConfig`
  does this for you (it rebases at the old half-life first).
- `expWad` reverts once its input exceeds ~135 (≈ `g = 10⁵⁸`). The clamp guarantees swaps
  never revert even if a rebase is overdue — decay simply "saturates" until the next rebase.

---

## 4. Reading the distribution — `computeRanges` (view)

Walks the bitmap once and extracts the percentile bands. Lives in the hook (it owns the
layout). The vault calls it at mint/burn; the vault user pays the SLOADs.

```
computeRanges(poolId, uint16[] confidencesBps) view returns (Range[] ranges, bool ok):
    P = pools[poolId]
    validate every confidence <= 10000 (else revert InvalidConfidence)
    if (!P.initialized) return (zeroed, false)

    // 1. Walk bitmap words from word(minTick) .. word(maxTick).
    //    For each set bit (ascending = sorted), SLOAD weight[c], collect (c, w).
    //    Accumulate `total` in the same pass. Kernighan bit-clear (bits &= bits-1)
    //    + leastSignificantBit (BitMath) to iterate set bits within a word.
    if (no set bits) return (zeroed, false)

    // 2. Sufficiency gate (decay-normalised). An ABSOLUTE threshold does NOT cancel `g`, so
    //    compare against MIN_DATA scaled up to the current epoch:
    if (total < minData * g / WAD) return (zeroed, false)   // ok = false

    // 3. For each confidence c (bps): tail = (10000 - c) / 2.
    //      lowerThreshold = total * tail         / 10000
    //      upperThreshold = total * (10000-tail) / 10000
    //    (90% -> 5% / 95%;  99% -> 0.5% / 99.5%;  99.9% -> 0.05% / 99.95%)

    // 4. Single ascending pass over the in-memory (c, w) array, running cum += w,
    //    recording the compressed tick as cum crosses each threshold (lower & upper for
    //    every confidence). One fat tick can cross several thresholds at once.

    // 5. Decompress (× tickSpacing, already aligned). Guarantee a non-degenerate range
    //    (upper = lower + spacing if they collapse). Return [lowerTick, upperTick] per
    //    confidence, and ok = true.
```

The vault passes `[9000, 9900, 9990]` and gets back three `[lowerTick, upperTick]` ranges =
its three positions, plus `ok`. **Confidence** here means "the tightest tick band that contains
that fraction of decay-weighted swap activity" (a 90% band trims the lightest 5% from each
tail) — not a ±5% offset from the extremes. The decay factor never appears in the band ratios
(Section 3); it appears *only* in the sufficiency gate of step 2, because an absolute floor
doesn't cancel.

- **`ok == false`** when the pool is uninitialised, has no recorded weight, or has too little
  (decay-normalised) data. The vault must **not** reposition on this — it holds its positions
  or uses a safe wide default. `ranges` is zeroed in that case.
- **`minData`** is per-pool config in decay-normalised WAD. For count weighting it reads as
  "effective recent swaps", so the default `3e18 ≈ 3 recent swaps` — deliberately low so a
  freshly-seeded pool produces ranges almost immediately (a hackathon convenience; the vault
  seeds the pool's initial liquidity range itself). Tune via `setConfig`.

---

## 5. Rebase & prune — owner force + permissionless `poke`

`g` grows forever. Two ceilings, both far away: `expWad` reverts ~16 years out (30d half-life),
and uint256 accumulation is well beyond that. A **rebase** renormalises so neither is hit — and
while it's walking every tick anyway, it **prunes** ones that have decayed to dust and
re-tightens the scan bounds.

```
_rebase(P):
    R = growthFactor(P)                               // current g (WAD)

    // Pass 1: renormalise every weight by R, sum the new total.
    newTotal = 0
    walk bitmap minTick..maxTick:
        P.weight[c] = P.weight[c] * WAD / R           // same R for all -> ratios unchanged
        newTotal   += P.weight[c]

    // Pass 2: prune dust and re-tighten [minTick, maxTick] to the survivors.
    dust = (P.pruneFraction == 0) ? 0 : newTotal / P.pruneFraction
    walk bitmap minTick..maxTick:
        if (P.weight[c] <= dust):
            clear bitmap bit; delete P.weight[c]      // free the slot (gas refund)
        else:
            extend newMin/newMax to c
    P.minTick, P.maxTick = newMin, newMax (if any survived)
    P.t0 = block.timestamp                            // g back to 1
```

- **Renormalise:** dividing **every** weight by the same `R` changes **no ratios**, so all
  percentiles are identical pre/post. Integer-division rounding is sub-wei.
- **Prune:** a tick holding `< total / pruneFraction` is decayed to negligible; dropping it
  keeps reads walking only the live band and reclaims storage. `pruneFraction` is per-pool
  config (default `1e4` ⇒ dust = 0.01% of total). That's comfortably below the tightest band's
  tail (99.9% trims 0.05% per side = `total/2000`), so pruning never clips a live band; the
  `MIN_PRUNE_FRACTION = 2000` floor caps the most-aggressive setting at exactly that tail
  granularity, and `0` disables pruning entirely (a tick that rounded to zero weight is still
  dropped). How fast a tick reaches the dust threshold is governed by the **half-life**, not
  the rebase cadence.

Two entry points:

```
poke(poolId):                  // permissionless
    if (P.initialized && block.timestamp - P.t0 >= P.rebaseInterval) _rebase(P)

rebase(poolId):                // onlyOwner — force one now
    _rebase(P)
```

- **`poke`** is the routine path: anyone may call it, and the vault calls it at mint/burn, so
  pools self-maintain with **no keeper** and **swappers never pay for a rebase**. It's a cheap
  no-op until `rebaseInterval` has elapsed.
- **Cadence:** `rebaseInterval` defaults to **7 days** (weekly) and is owner-tunable in
  `[1 day, 365 days]` via `setRebaseInterval`. Frequent rebasing keeps `g` near 1 and clears
  stray/MEV ticks promptly, instead of letting them linger for years. It is cheap relative to
  the percentile read that triggers it.
- The `MAX_EXP` clamp (Section 3) is the backstop that makes an overdue rebase safe — swaps
  never revert even if `poke` is never called.

---

## 6. Config & access control

- OpenZeppelin `Ownable`; defaults are seeded per-pool at `afterInitialize`.
- **Owner-only setters** (each bounds its input and reverts on a bad value):
  - `setConfig(poolId, halfLife, weighting, minData)` — rebases at the **old** half-life first
    so the new one takes effect cleanly. `weighting` may only change while the pool is unstarted
    (`WeightingLocked` otherwise). `halfLife ∈ [1d, 365d]`, `minData ∈ [1e18, 1e30]`.
  - `setCaptureWindow(poolId, lowerTick, upperTick)` — raw ticks; requires `lower < upper`.
  - `setRebaseInterval(poolId, interval)` — `interval ∈ [1d, 365d]`.
  - `setPruneFraction(poolId, fraction)` — `fraction == 0` (disabled) or `>= 2000`.
  - `rebase(poolId)` — force an immediate rebase + prune.
- **Permissionless:** `poke(poolId)` — interval-gated rebase; the only state-changing call open
  to anyone (and a no-op before the interval elapses).
- **Views:** `poolConfig`, `captureWindow`, `rebaseConfig` (interval + pruneFraction),
  `growthFactor`, `weightAt` — for the vault and observability.

---

## 7. Hook permissions (v4 flags)

- `afterInitialize = true` — cache `tickSpacing`, set `t0 = block.timestamp`, apply default
  config (`halfLife`, `weighting`, `minData`, `rebaseInterval`, `pruneFraction`), seed the
  capture window to `compress(initialTick ± CAPTURE_HALF_WIDTH)`, seed
  `minTick = maxTick = compress(initialTick)`, set `initialized`.
- `afterSwap = true` — the capture path.
- `afterSwapReturnDelta = false` — returns 0 delta.
- All other callbacks `false`. (Permission-flag address bits: `afterInitialize | afterSwap`.)

---

## 8. Edge cases & guardrails

- **Cold pool init:** seed `minTick`/`maxTick`/`t0`/config in `afterInitialize` so the first
  swap doesn't compare against zero-initialised bounds. No bitmap bit is set until the first
  captured swap.
- **Capture window:** swaps landing outside `[captureLowerTick, captureUpperTick]` are dropped
  (Section 2) — this is the primary guard against MEV/out-of-range data and the bound on read
  cost. Widen it (owner) only on a genuine repeg.
- **Negative ticks:** `compress` floors toward −∞ (see Section 2). Signed arithmetic
  throughout; `minTick`/`maxTick` are signed.
- **Insufficient data:** `computeRanges` returns `ok = false` when `total < minData·g/WAD`, the
  bitmap is empty, or the pool is uninitialised. The vault treats this as "don't reposition".
- **Long idle pool:** if no swaps for a very long time, the `MAX_EXP` clamp keeps the next swap
  from reverting; data is just stale until activity/`poke`/rebase resume.
- **Same-block swaps:** all counted (count/volume weighting), provided they land in-window.
- **Read cost grows with distinct touched ticks** but is capped by the capture window and kept
  tight by pruning at each rebase (no longer an optional cleanup — it runs every `_rebase`).
- **Volume weighting** (if used) overflows sooner than count and needs a defined, scaled
  measure ⇒ shorten `rebaseInterval`. `fullMulDiv` keeps the `amount·g` product from reverting
  even when `g` is saturated.

---

## 9. Gas profile (ballpark, mainnet rules)

- **Per swap (captured):** +~5–9k (read config/`t0`, one `expWad`, read+write `weight[c]`).
  One-time ~+20k the first time a brand-new in-window tick is touched (new slot + bitmap bit).
  **Out-of-window swap:** just the `getSlot0` + compare, then early return — near-free.
- **`computeRanges` (view, paid inside vault mint/burn):** O(touched ticks) SLOADs ≈
  ~250–650k for a stablepool — bounded by the capture window.
- **`rebase` / `poke`:** like a read but with an SSTORE per surviving tick and slot-clears
  (refunds) for pruned ones; folded into vault mint/burn via `poke` on the `rebaseInterval`
  cadence (default weekly), so there's no keeper and swappers never pay for it.

The expensive percentile work sits on mint/burn (vault users), keeping the swap path cheap —
that's the whole point of the inflate-on-write design.

---

## 10. Defaults summary

- Weighting: **count** (`weighting = 0`); volume available via flag, locked once data exists.
- Half-life: **30 days**, per-pool configurable (`[1d, 365d]`).
- Confidence bands: **90% / 99% / 99.9%**, passed as a `computeRanges` parameter.
- Capture window: **~±5%** (`CAPTURE_HALF_WIDTH = 500` ticks) around the peg, per-pool
  configurable via `setCaptureWindow`.
- `computeRanges` lives in the **hook**, returns raw ticks plus an `ok` flag.
- `minData`: sufficiency floor in decay-normalised WAD, **default `3e18`** (~3 effective recent
  swaps), per-pool configurable (`[1e18, 1e30]`); deliberately low for fast hackathon activation.
- Rebase cadence (`rebaseInterval`): **7 days**, per-pool configurable (`[1d, 365d]`); routine
  rebase/prune is permissionless via `poke`, owner can force via `rebase`.
- `pruneFraction`: **default `1e4`** (dust = 0.01% of total), per-pool configurable; `>= 2000`
  or `0` to disable.
- `MAX_EXP`: clamp (~100·WAD) on the decay exponent so `expWad` never reverts.
