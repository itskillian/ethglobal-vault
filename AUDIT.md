# USDaVault — Security Review

Adversarial multi-agent audit of `src/USDaVault.sol` (8 subsystem reviewers → triage → 3-lens
adversarial verification → synthesis; 23 raw findings → 15 candidates → 10 confirmed, 5 refuted).
The panel corrected several of its own reviewers' overclaims (noted below), so the surviving findings
are source-grounded, not speculative.

## Confirmed findings

| ID | Sev | Title | Status |
|----|-----|-------|--------|
| C1 | 🔴 Critical | Withdraw slice path pays out 100% of each poked position's accrued fees while burning only pro-rata shares → drains fees from remaining holders | **FIXED** |
| C2 | 🔴 Critical | Spot-manipulable NAV: `deposit`/`withdraw` had no peg guard, enabling mint-cheap / redeem-rich | **FIXED** |
| C3 | 🟠 High | Rebalance/init leftover tokens (swap slippage + dust) never credited to idle → invisible to NAV, one-way share-price leak | **FIXED** |
| C7 | 🟡 Med | `initialize()` silently no-ops position deployment if `approveAll()` wasn't called, yet burns the one-shot flag (bricks the LP product) | follow-up |
| C9 | 🟢 Low | `_minOut` reverts (uint16 underflow) if owner sets `swapMaxSlippageBps > 10000` → DoSes internal swaps | follow-up |
| C11 | 🟢 Low | Rebalance consolidation swaps sandwichable up to `swapMaxSlippageBps`, slippage socialised into NAV | follow-up |
| C6 | 🟢 Low | `reentryBand` hysteresis declared but never implemented (rebalance can thrash) | follow-up |
| C12 | 🟢 Low | `bufferBps` idle-sweep unimplemented (idle USDC only deploys on a drift-triggered rebalance) | follow-up |
| C13 | 🟢 Low | Dual-token fallback `Withdraw` event/return under-reports assets for a USDT-requested withdraw | follow-up |
| C15 | 🟢 Low | Spec names a `Rebalance` event; code emits richer `RebalanceExecuted` (naming mismatch) | follow-up |

## Refuted (correctly, by the verification panel)

- **C4** — mint-into-0 stranding a position: unreachable (a few-bps swap underfill changes liquidity by bps, not to 0; the USDC leg always holds real idle).
- **C5** — `totalAssets`/`_usdtToUsdc` overflow DoS: infeasible (the clamped per-position legs are coupled; worst-case numerator sits ~2^66 below the `FullMath.mulDiv` revert threshold; pool sqrtP is hard-bounded).
- **C10** — degenerate-band div-by-zero in `initialize`: short-circuited by the `valuePerL == 0` guard before any divide.

## Fixes applied (this commit)

**C1 — pro-rata fee retention.** `_sliceAllPositions` snapshots each poked position's uncollected fees
(`_positionFees`, the same `feeGrowthInside·L/Q128` formula v4 settles with) before the decrease, pays the
withdrawer only `(decreased tokens − (1−f)·fees)` per leg, and retains the `(1−f)·fees` surplus in the
accounted idle counters via `_creditIdle`. Per-share NAV is provably unchanged for remaining holders; the
surplus can't underflow because `_positionFees == fees-settled` at the same block.

**C2 — peg-clamped NAV + deposit guard.** `totalAssets`/`_positionValueUSDC` value at `_navSqrt()` — the
spot price **clamped into the peg-band sqrt bounds** (`navSqrtLow/High`, derived from `pegLow/pegHigh` via
`_priceWadToSqrt`, recomputed in the constructor and `setPegBand`). An in-block spot push therefore can't
move NAV (split **or** valuation) beyond the band. `deposit` additionally reverts `OffPeg` when the raw
spot is outside the band. The peg **check** still uses raw spot. Verified by unit tests
(`test_navClamp_boundsUsdtValuationUnderManipulation`, both token orderings).

**C3 — dual-token idle + residual reconciliation.** Added an `idleUSDT` counter (valued in NAV at the
clamped price). `_initOne`/`_rebalanceStep` now call `_reconcileIdle(b0,b1)`, which folds the **signed
balance delta** of the deploy back into the idle counters (floored at 0). Deploy slippage/dust stays
counted in NAV; still donation-proof because only deltas are applied, never absolute `balanceOf`. Verified
by unit tests (`test_creditIdle_mapsByTokenOrdering`, `test_reconcileIdle_*`).

### Verification status

- 20 unit tests pass (NAV clamp band + manipulation bound, idle-accounting backbone, valuation both
  orderings, peg guard, access control, locked entrypoints).
- 6 mainnet-fork tests (run with `ETH_RPC_URL=… forge test --match-path test/USDaVault.fork.t.sol`):
  deployed-contract bytecode, wiring, deposit/NAV/share-math, donation-inertness, USDC fast-path withdraw,
  and the **C2 deposit-OffPeg revert**.
- **Full C1/C3 lifecycle regression** (positions accruing fees → tiny withdraw → per-share NAV unchanged)
  needs a vault pool carrying the VaultHook + a seeded swap pool; outlined as a TODO in the fork suite.
  The accounting backbone for both is unit-tested.

## Deferred (follow-ups, not in this commit)

C7, C9, C11, C6, C12, C13, C15 above — none are fund-theft. Recommended next batch: bound
`swapMaxSlippageBps ≤ BPS` (C9), make `initialize` assert positions opened / fold in `approveAll` (C7),
fix `_payDualToken` event/return (C13), and either implement or remove `reentryBand`/`bufferBps`
(C6/C12).
