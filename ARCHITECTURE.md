# USDa Vault — Architecture Spec

A vault that takes USDC, provides concentrated liquidity to a Uniswap **v4 USDC/USDT pool** across 4 positions (1 fixed full-range backstop + 3 hook-driven percentile bands), and issues **USDa** shares.

**Scope:** hackathon MVP, deployed to **Ethereum mainnet**. Immutable (no proxy), no vault fee, no full audit/test suite. This doc is the build spec — read it fully before writing code. Items marked **`TODO(dev)`** require a value or decision the implementer must supply.

## 1. Core model

- **Share token (USDa):** extends **OpenZeppelin `ERC4626`** (v5), `asset = USDC`. Do not hand-roll mint/burn or conversion math.
- **NAV-based shares.** Share price = NAV / totalSupply. LP fees accrue into NAV → share price rises. No per-user time-weighting or manual fee bookkeeping — appreciation handles it.
- **NAV uses the vault pool's own spot price** (current `sqrtPriceX96`). **No external oracle.** USDT is valued at pool price, not assumed 1:1.
- **Deposits:** USDC only. **Withdrawals:** user chooses USDC or USDT; the vault swaps the other leg into the chosen asset. This is also the depeg valve — if USDT depegs, the user can take USDT instead of crystallising a loss into USDC.
- **No vault fee.** Holders keep all LP fees net of realised swap/gas costs.

## 2. Conventions (stated once — applies everywhere below)

- **Token ordering = Uniswap standard.** `currency0`/`currency1` are sorted by address; do **not** hardcode which is USDC. At init the contract records `usdcIsToken0 = (USDC == poolKey.currency0)` and derives every `amount0/amount1`, leg, and `zeroForOne` from it.
- **Price = Uniswap standard.** `price(token1/token0) = (sqrtPriceX96 / 2**96)**2`. Derive `P = USDC per USDT` from this and `usdcIsToken0` (invert when USDT is token0). Use `FullMath`/`TickMath` for all fixed-point; no float.
- **Decimals.** USDC and USDT are 6. USDa = `asset decimals + offset` = **6 + 6 = 12**.
- **Rounding.** Always in the vault's favour: shares down on deposit, assets down on withdraw.

## 3. Positions

Four v4 positions in the vault pool. Targets are allocation of NAV at deploy/rebalance time, not re-enforced between rebalances. Positions 1–3 are **nested, overlapping** percentile bands from the hook (band 1 ⊂ band 2 ⊂ band 3); stacked, they form a depth curve that is deep at spot and thins out in the wings. Position 0 is a fixed full-range backstop the hook can't (and shouldn't) produce:

| Idx | Position | Target | Range source | Rebalanced? |
|---|---|---|---|---|
| 0 | Full-range backstop | 1% | fixed (`minUsableTick`/`maxUsableTick`) | never |
| 1 | Active (tight) | 79% | hook 90% band | on threshold |
| 2 | Medium | 15% | hook 99% band | on threshold |
| 3 | Tail insurance | 5% | hook 99.9% band | on threshold |

Targets are `TODO(dev)`; they must sum to 100% when `bufferBps = 0`. Ranges 1–3 come from one call: `(Range[] ranges, bool ok) = hook.computeRanges(poolKey.toId(), [9000, 9900, 9990])` (§14). `ranges[0..2]` map to positions 1–3; tightest confidence = narrowest band = most capital. The hook only captures swaps within ~±5% of peg (its capture window), so even the 99.9% band is bounded near peg — position 0 is the true full-range backstop for larger depeg moves.

**Handle the sufficiency flag:** if `ok == false` (cold/thin pool, `total < minData`) hold all hook-driven positions — never reposition on near-empty data. **Validate each range before use:** tick-spacing aligned (the hook already aligns), `lower < upper` (the hook guarantees non-degenerate), width ∈ `[MIN_WIDTH, MAX_WIDTH]` `TODO(dev)`. A band need **not** bracket the current tick — a skewed distribution can yield a single-sided range, which `_amountsForRange` (§10c) deploys correctly; do not reject on that alone. On hook revert: skip rebalance, keep old range — never let the hook DoS user flow.

## 4. State / config (immutables unless noted)

```
ERC4626(USDa, asset = USDC)
poolManager, positionManager, universalRouter, permit2, stateView   // §10
poolKey            // vault USDC/USDT pool
swapPoolKey        // PRIMARY swap venue: one deep USDC/USDT pool, ≠ poolKey; owner-configurable    TODO(dev)
backupRouter       // BACKUP venue: router called if the primary swap reverts (§10b); 0 = disabled  TODO(dev)
hook = poolKey.hooks // the vault pool's own hook; IVaultHook.computeRanges() provider
confidencesBps     // hook bands for positions 1–3, e.g. [9000, 9900, 9990]
usdcIsToken0       // §2, set at init
position[4]        // {lower, upper, liquidity}; idx per §3 (0=full-range backstop, 1–3=hook bands)
idleUSDC           // dust (+ optional buffer), tracked internally — never balanceOf
DECIMALS_OFFSET = 6        // OZ virtual shares (inflation-attack defense)
fullRangeLower/Upper      // min/max usable tick for spacing
rebalanceBand, reentryBand // hysteresis, per position (ticks)                      TODO(dev)
bufferBps = 0             // idle USDC reserve; 0 = invest everything on rebalance
pegLow, pegHigh           // peg band ~1.0 (e.g. 0.995–1.005); manipulation/depeg guard
swapMaxSlippageBps        // bounds minAmountOut on internal swaps (e.g. 30)
rebalanceGasCap           // inline rebalance skipped if gasleft() < this
owner, paused             // admin; rebalance() itself is permissionless
```

## 5. NAV — `totalAssets()` override

```
P = USDC per USDT, from pool sqrtPriceX96 (§2)
for each position i:
    (a0, a1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLower, sqrtUpper, position[i].liquidity)
    (f0, f1) = uncollected fees (feeGrowthInside delta, via StateView)
    add USDC-leg amounts as-is; add USDT-leg amounts * P
totalAssets = Σ USDC legs + Σ (USDT legs * P) + idleUSDC          // in USDC (6 dp)
```

Compute from **position liquidity + recorded fees + `idleUSDC` only — never `token.balanceOf`**. This makes raw token donations inert (no share-price manipulation via transfer).

## 6. Shares & conversions

OZ provides the math given `_decimalsOffset() = 6`:

```
shares = assets * (totalSupply + 10**6) / (totalAssets + 1)   // down
assets = shares * (totalAssets + 1) / (totalSupply + 10**6)   // down
```

Defense-in-depth (all three): (1) decimals offset = 6 (virtual shares); (2) **dead shares** — mint `MINIMUM_LIQUIDITY` (~1000) to `address(0)` on the first deposit / init; (3) internal accounting (§5).

## 7. Deposit — `deposit(usdcAmount, minShares, deadline)`

1. `nonReentrant`, not paused, `block.timestamp <= deadline`.
2. Pull USDC (`SafeERC20`). Compute `shares` from NAV **before** crediting the new funds.
3. `shares >= minShares` else revert. Mint USDa.
4. Add USDC to `idleUSDC`. Shares are priced off pre-deposit NAV (step 2), independent of any rebalance.
5. **Best-effort rebalance (§9):** `try _rebalance()`; on revert or `gasleft() < rebalanceGasCap`, skip — deposit still succeeds. New USDC is deployed here or waits in `idleUSDC` for the next trigger.

## 8. Withdraw — `withdraw(shares, wantToken, minOut, deadline)`

`wantToken ∈ {USDC, USDT}`. **The pro-rata slice governs the payout; `minOut` protects the user.**

1. `nonReentrant`, not paused, deadline check.
2. **Source the slice:**
   a. If `wantToken == USDC` and `idleUSDC` covers `convertToAssets(shares)`: pay from `idleUSDC` (preserves per-share NAV — value and shares removed in proportion).
   b. Else pull a **pro-rata slice from each position**: `DECREASE_LIQUIDITY(position[i].liquidity * shares / totalSupply)` + collect that share of fees. Yields USDC + USDT.
3. **Consolidate (best-effort):** swap the unwanted leg → `wantToken` via §10b (primary `swapPoolKey`, then `backupRouter` on revert; `minOut` from `swapMaxSlippageBps`).
   - **Dual-token fallback:** if both primary and backup swap fail (`ok == false`), do **not** revert the withdrawal — pay the user their pro-rata **USDC + USDT** directly (no consolidation). Users can always exit regardless of swap-venue health; pairs with the depeg valve.
4. **Withdrawer bears their own swap cost** — it comes out of their proceeds, never socialised into NAV.
5. `amountOut >= minOut` else revert. Burn USDa. Transfer `wantToken` (`SafeERC20`).
6. **Best-effort rebalance (§9):** `try _rebalance()`, same as deposit.

## 9. Rebalance — `_rebalance()` (best-effort inline) + `rebalance()` (permissionless)

Primary trigger is the best-effort call at the end of deposit/withdraw (self-maintaining, no keeper). Also exposed as permissionless `rebalance()` for quiet periods. Same logic both ways. Rebalance work is at the vault level, so swap slippage lands in NAV → socialised across holders; only gas falls on the caller (bounded by `rebalanceGasCap`, or borne by a keeper via the public call).

1. `nonReentrant`, not paused. `(ranges, ok) = hook.computeRanges(poolKey.toId(), [9000, 9900, 9990])`; **validate (§3)** — if `!ok`, invalid, or revert, return without touching positions.
2. **Peg-band guard (no oracle):** require pool spot price ∈ `[pegLow, pegHigh]`; else return (withdrawals fall back to single-asset, §8). Uses the stablecoin peg in place of a TWAP (v4 has no native oracle) and doubles as the depeg breaker. Residual: within-band nudging can skew NAV by ≤ band width on the USDT leg — keep the band tight.
3. For positions 1, 2 and 3 **independently**: if drift `> rebalanceBand` → mark (hysteresis: only re-mark after returning inside `reentryBand`). **At most one position per call** (gas bound); the next trigger handles the others.
   - **`TODO(dev)`: define the drift metric** — e.g. `|Δlower| + |Δupper|` in ticks vs `rebalanceBand`.
4. For the marked position: `BURN_POSITION` + collect fees → swap proceeds into the new range's ratio via §10b (primary then backup; §10c sizes the amount) → `MINT_POSITION`. If the swap returns `ok == false` (both venues failed within slippage), abort this rebalance and keep the old position — best-effort, retried next trigger.
5. Unmarked positions: optionally sweep `idleUSDC` above `bufferBps` in at current ratio.
6. Leftover dust → `idleUSDC`.

## 10. Uniswap v4 execution

On-chain only via two contracts: **`PositionManager`** (liquidity) and **`UniversalRouter`** (swaps). Do not integrate UniswapX or the Trading API (off-chain only).

### 10a. Liquidity — `PositionManager.modifyLiquidities(abi.encode(actions, params), deadline)`
Vault owns positions as NFTs, recipient = `address(this)`. Action pairs:

| Op | Actions |
|---|---|
| Open | `MINT_POSITION` + `SETTLE_PAIR` |
| Add | `INCREASE_LIQUIDITY` + `SETTLE_PAIR` |
| Trim | `DECREASE_LIQUIDITY` + `TAKE_PAIR` |
| Collect fees | `DECREASE_LIQUIDITY(0)` + `TAKE_PAIR` |
| Close | `BURN_POSITION` + `TAKE_PAIR` |

Setup: approve token→**Permit2**, then Permit2→PositionManager. Read fee/position state via `StateView`.

### 10b. Swaps — primary pool + backup router, never the vault pool

Internal swaps (withdraw consolidation §8, rebalance ratio §9) go through one helper, `_swapExactInOffPool(tokenIn, amtIn, minOut) → (out, ok)`, with a **two-tier** execution path. Both tiers share the same guard, so neither can give a bad fill — the only question is whether *a* fill happens.

1. **Primary — hardcoded pool.** Single-hop exact-in on `swapPoolKey` (one deep USDC/USDT pool, owner-configurable) via `UniversalRouter`: `Commands.V4_SWAP` = `SWAP_EXACT_IN_SINGLE` + `SETTLE_ALL` + `TAKE_ALL`, carrying `amountOutMinimum` and `sqrtPriceLimitX96`.
2. **Backup — fallback router.** If the primary `try` reverts (slippage, thin/dislocated quote, paused pool), call the owner-configured `backupRouter` with the same `tokenIn/amtIn/minOut`. It's a `UniversalRouter` program reaching Uniswap **v2/v3/v4** (the deepest USDC/USDT liquidity is v3), so one pool failing doesn't strand the vault.
3. **Both fail → `ok = false`.** The helper returns `(0, false)` instead of reverting, so the caller degrades gracefully: withdrawals fall back to **dual-token payout** (§8), rebalance **skips** (§9). No swap ever forces a user action to revert.

**Safety guard (both tiers).** Approve **exactly `amtIn`** per swap (no standing max; USDT needs `approve(0)` first), recipient = the vault, and assert a **two-sided balance delta** around the call: `tokenIn spent ≤ amtIn` **and** `wantToken received ≥ minOut`. This bounds *any* route — including a misconfigured or caller-supplied backup — to "spent ≤ in, received ≥ out", so the worst case is a revert / `ok=false`, never a loss. For stables both legs are 6-dp and ~1:1, so `minOut = amtIn * (10000 - swapMaxSlippageBps) / 10000`.

**Never the vault pool.** Assert `swapPoolKey.toId() != poolKey.toId()` and that no route targets `poolKey`. Modifying liquidity on the vault pool is *price-neutral* — only a *swap* moves `sqrtPriceX96` — so routing every swap off-pool lets the vault reposition without moving the price its own NAV (§5) and `_amountsForRange` (§10c) are valued at. Self-swapping would move the NAV reference reflexively and pollute the hook's `afterSwap` distribution. See **§15** for the full rejected-alternatives rationale (self-swap, flash-loan ordering, manufactured-arb, single-`unlock`).

### 10c. Amounts for a target range — `LiquidityAmounts` + `TickMath`
`_amountsForRange(lower, upper, valueUSDC) → (amt0, amt1, liquidity)`:
```
sqrtA = TickMath.getSqrtPriceAtTick(lower)
sqrtB = TickMath.getSqrtPriceAtTick(upper)
sqrtP = pool current sqrtPriceX96            // same price as NAV §5
P     = USDC per USDT from sqrtP (§2)
(a0,a1)     = getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, 1e18)        // trial L
valuePerL   = (USDC leg of a0/a1) + (USDT leg) * P                      // in USDC
L           = valueUSDC * 1e18 / valuePerL
(amt0,amt1) = getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, L)
liquidity   = getLiquidityForAmounts(sqrtP, sqrtA, sqrtB, amt0, amt1)   // ≤ L, mint-safe
```
Deploy = swap holdings to `(amt0, amt1)` via 10b, then `MINT`/`INCREASE` with `liquidity` and maxes `(amt0, amt1)`. Dust → `idleUSDC`.

## 11. Initialization & deployment

**Ethereum mainnet addresses (chain 1)** — verified against `developers.uniswap.org/contracts/v4/deployments` (2026-06). Wired into `script/Deploy.s.sol`. Permit2 is the same canonical address on every chain. (Quoter is off-chain use only — see §10b/§15.)

| Contract | Address |
|---|---|
| PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| PositionManager | `0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e` |
| StateView | `0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227` |
| Quoter | `0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203` (off-chain only) |
| UniversalRouter | `0x4C82D1fBFe28C977cBB58D8C7FF8FCF9F70a2cCA` (**v2.1.1** — see caveat) |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |

> **UniversalRouter version caveat:** the vault encodes the **6-field** `IV4Router.ExactInputSingleParams` (with `minHopPriceX36`) from the installed v4-periphery, which matches UniversalRouter **v2.1.1** (`0x4C82…`), **not** the original v4-launch router (`0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af`, 5-field struct). Deploy against the router whose `V4Router` ABI matches the encoding, or swaps revert. Confirm `execute(bytes,bytes[],uint256)` (selector `0x3593564c`) and the `V4_SWAP`=`0x10` command byte against the deployed router before mainnet use.

**`TODO(dev)` — must provide before deploy:**
- Canonical mainnet USDC and USDT token addresses.
- `poolKey` — the USDC/USDT vault pool (create & initialise it if absent), incl. its fee/tickSpacing/hook.
- `swapPoolKey` — the **primary** swap pool (§10b): the deepest canonical USDC/USDT pool (e.g. Uniswap v3 0.01%/0.05% reached via `UniversalRouter`); **must not** be the vault pool and need not use this hook.
- `backupRouter` — the **backup** swap router (§10b): a `UniversalRouter` program reaching v2/v3/v4, called only if the primary swap reverts.
- `hook` — the vault pool's own hook (`poolKey.hooks`): a `VaultHook` exposing `computeRanges()` (§14). Same address as `poolKey.hooks`, not a separate contract.
- `confidencesBps` — the band percentiles for positions 1–3 (default `[9000, 9900, 9990]`).
- Parameters left `TODO(dev)` in §3/§4 (range widths, bands, peg band, slippage, gas cap).

**Bootstrap sequence (immutable, constructor + one-time `initialize`):**
1. Deploy vault with all immutables above (constructor).
2. Owner approves token→Permit2 and Permit2→PositionManager.
3. Owner sends a seed USDC deposit.
4. `initialize()` (owner-only, one-shot): mint dead shares (§6), then open all **4** positions. The pool has had no swaps yet, so `computeRanges` returns `ok=false` — open positions 1–3 at **fallback default ranges** (e.g. active ±1%, medium ±3%, tail ±5% around the peg tick; `TODO(dev)`) and position 0 at full-range. Later rebalances adopt hook ranges once `ok` flips true (§9). Separate from normal `deposit`.

## 12. Admin (lean)
`owner` can: `pause()`/`unpause()`, set the `TODO(dev)` tunables (`*Band`, `peg*`, `bufferBps`, `swapMaxSlippageBps`, `rebalanceGasCap`), and repoint the swap venues (`swapPoolKey`, `backupRouter`) so a thin/rugged pool can be swapped out without a redeploy. No timelock for the MVP. Emit `Deposit`, `Withdraw`, `Rebalance`, `RangeUpdated`, `SwapVenueUpdated`.

## 13. Correctness checklist
- `nonReentrant` on deposit/withdraw/rebalance; checks-effects-interactions; mint USDa only after assets received.
- `SafeERC20` everywhere. **USDT is non-standard:** no bool return, approve-race (`approve(0)` first), `received != sent` possible.
- Token ordering & price derived per §2 — never hardcoded.
- Rounding in the vault's favour (§2). Dust parked in `idleUSDC`, counted in NAV.
- `deposit`/`withdraw` carry `minShares`/`minOut` + `deadline`; internal swaps carry `minAmountOut` (§10b).
- Hook untrusted: validate ranges, treat `ok=false` as hold (§3), tolerate revert, never DoS user flow.
- Vault never swaps its own pool: assert `swapPoolKey.toId() != poolKey.toId()` and that no route targets `poolKey` (§10b). Self-swaps would move the NAV reference price and pollute the hook distribution.
- Swaps are two-tier (primary `swapPoolKey` → `backupRouter`) and guarded: per-swap exact approval, recipient = vault, two-sided balance delta (`spent ≤ amtIn`, `received ≥ minOut`). Both fail → `ok=false`; caller degrades (withdraw → dual-token §8, rebalance → skip §9).
- `initialize()` opens 4 positions; positions 1–3 bootstrap from fallback ranges until the hook has data (§11).
- Permit2 approvals set once at init to PositionManager + UniversalRouter only.
- `initialize()` seeds dead shares + positions, one-shot, separate from `deposit`.

## 14. Interfaces (sketch)

```solidity
import {PoolId} from "v4-core/src/types/PoolId.sol";
interface IVaultHook {
    struct Range { int24 tickLower; int24 tickUpper; }   // raw, tickSpacing-aligned ticks
    function computeRanges(PoolId id, uint16[] calldata confidencesBps)
        external view returns (Range[] memory ranges, bool ok);
}

function initialize() external;          // owner, one-shot: dead shares + open 4 positions
function deposit(uint256 usdcAmount, uint256 minShares, uint256 deadline) external returns (uint256 shares);
function withdraw(uint256 shares, address wantToken, uint256 minOut, uint256 deadline) external returns (uint256 out);
function rebalance() external;           // permissionless; also runs best-effort inside deposit/withdraw
function totalAssets() public view override returns (uint256);   // NAV, §5

// internal
function _amountsForRange(int24 lower, int24 upper, uint256 valueUSDC)
    internal view returns (uint256 amt0, uint256 amt1, uint128 liquidity);   // §10c
function _swapExactInOffPool(address tokenIn, uint256 amtIn, uint256 minOut) internal returns (uint256 out, bool ok); // §10b primary→backup, two-sided guard
function _mintOrIncrease(uint8 i, uint256 amt0, uint256 amt1) internal;      // §10a
function _burnOrDecrease(uint8 i, uint256 liquidity) internal returns (uint256 got0, uint256 got1); // §10a
```

**Invariant:** USDa share price (NAV/supply) is non-decreasing except for realised swap/gas costs and depeg revaluation; no user action can move it via donation.

## 15. Rejected alternatives (swap execution)

Recorded so they are not re-litigated:

- **Self-swap in the vault pool — even via flash loan or clever ordering.** Any swap on `poolKey` moves `sqrtPriceX96`; funding it with a flash loan or reordering burn/swap/mint changes *who fronts the tokens*, never *whether price moves*. And trading against liquidity you own is a no-op for your inventory (you reclaim it on burn) — only **non-vault** liquidity converts your ratio, so the more you dominate the pool the *more* gross volume and price impact a given net conversion needs. Self-swapping also corrupts NAV (§5) and the hook distribution. Always swap off-pool.
- **Manufacturing an arb by moving our own price to harvest fees.** Net-negative by construction: opening a gap Δ hands arbers a profit they take only when `arb_profit > fee`, so you leak more than you collect (textbook LVR). Fees and LVR both accrue pro-rata to liquidity share, so dominance can't decouple them. Capturing arb legitimately needs an oracle (rejected — this vault is oracle-free) or a `beforeSwap` auction hook (out of scope).
- **On-chain best-execution routing.** Optimal multi-pool splitting is solved off-chain by aggregators/quoters; the v4 Quoter is non-`view` and off-chain-only. On-chain we keep closed-form sizing (§10c — valid precisely because off-pool swaps leave `P` fixed) plus a fixed primary + fallback `backupRouter`, never an on-chain router search.
- **Single-`unlock` rebalance (burn→swap→mint, net-settled via flash accounting).** Saves ~tens of k gas but traps swaps in v4-only: `poolManager.swap` can't reach deep v3 liquidity, and you can't call `UniversalRouter` from inside an `unlock` (nested `unlock` reverts). On mainnet the liquidity access is worth far more than the gas on an infrequent, gas-capped rebalance, so we use periphery — separate `PositionManager` + `UniversalRouter` calls (§10).
- **Hook-side blacklist of the vault address.** Can't work: a v4 hook sees `sender = router` (the immediate `PoolManager` caller), not the vault, so it can't target the vault and would penalise every other user of that router. The "never self-swap" guarantee is enforced **vault-side** (§10b), not in the hook.
