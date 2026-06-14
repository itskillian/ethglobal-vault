# Distribution Hook — Architecture & Implementation Brief

> Spec for the distribution-hook codebase. Read top-to-bottom before laying out contracts.
> This is the full design; build to it.

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
- Base contracts: v4 `BaseHook` + OpenZeppelin `Ownable` (the owner gates the manual rebase).

**Not in this codebase (the vault, a separate component):** ERC20 credit shares, single-token
zap/auto-swap, repositioning, NAV. The hook just exposes the ranges; the vault consumes them.

---

## 1. State (per pool)

Sparse histogram using Uniswap's tick-bitmap pattern, plus a decay clock and config.

```solidity
struct PoolDist {
    // --- histogram (sparse; bitmap gives sorted iteration) ---
    mapping(int16 => uint256) bitmap;   // 1 bit per COMPRESSED tick = "has weight"
    mapping(int24 => uint256) weight;   // decay-inflated weight per COMPRESSED tick (WAD)
    int24  minTick;                     // lowest compressed tick ever touched (scan lower bound)
    int24  maxTick;                     // highest compressed tick ever touched (scan upper bound)

    // --- decay clock ---
    uint32 t0;                          // epoch start; reference for the growth factor & rebase

    // --- config ---
    uint32 halfLife;                    // seconds (default 30 days)
    uint8  weighting;                   // 0 = count (default), 1 = volume
    int24  tickSpacing;                 // cached from PoolKey at init
    bool   initialized;
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

---

## 2. Capture — `afterSwap` (the swap-path hot path)

On each swap, increment the **landing tick** (post-swap current tick) by an amount scaled by
the current growth factor. O(1).

```
afterSwap(sender, key, params, delta, hookData) -> (bytes4, int128):
    poolId = key.toId()
    P = pools[poolId]

    (, int24 tick, , ) = poolManager.getSlot0(poolId)     // StateLibrary; post-swap landing tick
    int24 c = compress(tick, P.tickSpacing)               // floor division — handle negatives!

    uint256 g      = growthFactor(P)                       // exp(λ·(now−t0)), WAD, clamped (Section 3)
    uint256 amount = (P.weighting == COUNT) ? WAD : volumeOf(delta)   // WAD-scaled

    uint256 w = P.weight[c]
    if (w == 0) {                                          // first time this tick has weight
        flipBit(P.bitmap, c)                              // set bitmap bit
        if (c < P.minTick) P.minTick = c
        if (c > P.maxTick) P.maxTick = c
    }
    P.weight[c] = w + amount * g / WAD

    return (IHooks.afterSwap.selector, 0)                  // no delta adjustment
```

- **Landing tick = post-swap tick** (`getSlot0` in `afterSwap`). This is count/volume
  weighting of *where swaps land*, not time-in-tick weighting. Every swap counts, including
  multiple swaps in the same block.
- `compress` must floor toward negative infinity (Uniswap does:
  `compressed = tick / spacing; if (tick < 0 && tick % spacing != 0) compressed--`).
- **Count weighting (default):** `amount = WAD` (1.0 per swap).
- **Volume weighting (optional, via `weighting` flag):** `volumeOf(delta)` picks one
  consistent measure — e.g. `abs(amount0)` or the input amount — scaled to WAD-comparable
  units. Volume overflows the growth factor sooner (Section 5), so count is the default.

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
  + epoch reset (takes effect going forward), so treat it as set-once-tune-rarely.
- `expWad` reverts once its input exceeds ~135 (≈ `g = 10⁵⁸`). The clamp guarantees swaps
  never revert even if a rebase is overdue — decay simply "saturates" until the next rebase.

---

## 4. Reading the distribution — `computeRanges` (view)

Walks the bitmap once and extracts the percentile bands. Lives in the hook (it owns the
layout). The vault calls it at mint/burn; the vault user pays the SLOADs.

```
computeRanges(poolId, uint16[] confidencesBps) view returns (Range[] memory):
    P = pools[poolId]

    // 1. Walk bitmap words from word(minTick) .. word(maxTick).
    //    For each set bit (ascending = sorted), SLOAD weight[c], push (c, w) to memory.
    //    Accumulate `total` in the same pass.  Use Kernighan bit-clear (bits &= bits-1)
    //    + leastSignificantBit (BitMath) to iterate set bits within a word.

    // 2. If total < MIN_DATA (or bitmap empty) -> return a sentinel.
    //    The vault must NOT reposition on this; it holds positions / uses a safe wide default.

    // 3. For each confidence c (bps): tail = (10000 - c) / 2.
    //      lowerThreshold = total * tail        / 10000
    //      upperThreshold = total * (10000-tail)/ 10000
    //    (90% -> 5% / 95%;  99% -> 0.5% / 99.5%;  99.9% -> 0.05% / 99.95%)

    // 4. Single ascending pass over the in-memory (c, w) array, running cum += w,
    //    recording the compressed tick as cum crosses each threshold (lower & upper for
    //    every confidence). All boundaries captured in one sweep; inner while-loop handles
    //    one fat tick crossing several thresholds at once.

    // 5. Decompress (× tickSpacing), align to tickSpacing, return [lowerTick, upperTick]
    //    per confidence.
```

The vault passes `[9000, 9900, 9990]` and gets back three `[lowerTick, upperTick]` ranges =
its three positions. The decay factor never appears here — ratios cancel it. Confidence levels
are a parameter so the vault can tune them without a hook redeploy.

---

## 5. Rebase — owner-only, manual

`g` grows forever. Two ceilings, both far away: `expWad` reverts ~16 years out (30d
half-life), and uint256 accumulation is orders of magnitude beyond that. A **rebase**
renormalises so neither is ever hit.

```
rebase(poolId):   // onlyOwner
    P = pools[poolId]
    R = growthFactor(P)                          // current g (WAD)
    walk bitmap minTick..maxTick:
        P.weight[c] = P.weight[c] * WAD / R      // divide every weight by the same R
    P.t0 = block.timestamp                        // reset epoch -> g back to 1
```

- Dividing **every** weight by the same `R` changes **no ratios**, so all percentiles are
  identical pre/post rebase. Integer-division rounding is negligible and monotonic.
- After reset, old (rebased) weights act as the baseline that future inflated increments
  outgrow at the same rate — decay continues seamlessly.
- Cadence: with a 30-day half-life, rebasing roughly every 1–2 years caps `g` at ~10⁷,
  leaving ~50 orders of magnitude of headroom under both ceilings. It is a rare maintenance
  call, not an operational burden.
- The `MAX_EXP` clamp (Section 3) is the backstop that makes an overdue rebase safe — swaps
  never revert.
- (A later optimisation could fold the rebase into `computeRanges` at mint/burn when
  `now − t0` exceeds a bound — that read already iterates every tick, so the marginal cost is
  one SSTORE per tick with no keeper. Not required to ship.)

---

## 6. Config & access control

- OpenZeppelin `Ownable`.
- Owner-only: `rebase(poolId)`, `setConfig(poolId, halfLife, weighting)` (and any per-pool
  params). Bound `halfLife` to a sane range.
- Per-pool config is set at `afterInitialize` (defaults) and adjustable by the owner.

---

## 7. Hook permissions (v4 flags)

- `afterInitialize = true` — cache `tickSpacing`, set `t0 = block.timestamp`, seed
  `minTick = maxTick = compress(initialTick)`, set `initialized`, apply default config.
- `afterSwap = true` — the capture path.
- `afterSwapReturnDelta = false` — returns 0 delta.
- All other callbacks `false`.

---

## 8. Edge cases & guardrails

- **Cold pool init:** seed `minTick`/`maxTick`/`t0` in `afterInitialize` so the first swap
  doesn't compare against zero-initialised bounds.
- **Negative ticks:** `compress` must floor toward −∞ (see Section 2). Signed arithmetic
  throughout; `minTick`/`maxTick` are signed.
- **Insufficient data:** `computeRanges` returns a sentinel when `total < MIN_DATA` or the
  bitmap is empty. The vault treats this as "don't reposition" (hold current positions or use
  a safe wide default) — never compute ranges off near-empty data.
- **Long idle pool:** if no swaps for a very long time, the `MAX_EXP` clamp keeps the next
  swap from reverting; data is just stale until activity/rebase resume.
- **Same-block swaps:** all counted (count/volume weighting).
- **Read cost grows with distinct touched ticks.** For a stablepool it plateaus at the band
  width. Far outliers leave set bits in place; pruning bits whose rebased weight rounds to ~0
  during rebase is an optional cleanup.
- **Volume weighting** (if used) overflows sooner than count and needs a defined, scaled
  measure ⇒ rebase more often.
- **Intermediate overflow:** `amount * g` before `/ WAD` is fine under uint256 for realistic
  values; keep an eye on it for volume + a very large `g` (i.e. overdue rebase).

---

## 9. Gas profile (ballpark, mainnet rules)

- **Per swap:** +~5–9k (read config/`t0`, one `expWad`, read+write `weight[c]`). One-time
  ~+20k the first time a brand-new tick is touched (new slot + bitmap bit).
- **`computeRanges` (view, paid inside vault mint/burn):** O(touched ticks) SLOADs ≈
  ~250–650k for a stablepool.
- **`rebase`:** like a read but with an SSTORE per tick; ~once every 1–2 years.

The expensive percentile work sits on mint/burn (vault users), keeping the swap path cheap —
that's the whole point of the inflate-on-write design.

---

## 10. Defaults summary

- Weighting: **count** (`weighting = 0`); volume available via flag.
- Half-life: **30 days**, per-pool configurable.
- Confidence bands: **90% / 99% / 99.9%**, passed as a `computeRanges` parameter.
- `computeRanges` lives in the **hook**, returns raw ticks.
- `MIN_DATA`: a configurable minimum total weight below which `computeRanges` returns a
  sentinel.
- `MAX_EXP`: clamp (~100·WAD) on the decay exponent so `expWad` never reverts.
- Rebase: manual, owner-only.
