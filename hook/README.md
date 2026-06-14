vault - https://sepolia.etherscan.io/address/0x1638fcb8a56a19e8226e2d15c7b3c2cc2f3c6040

hook - https://sepolia.etherscan.io/address/0xfba82aec5c132db641e22464d7ce7f71994d9040

init pool txnId - 0xeab8a38523999977664889e6ae28b8f6fca7358be5b96c9c94749fca22cc4e88

vault deposit, USDa mint txnId - 0xd8d747f0d23334005a55cb76a241490eb11faf5a290204cfe007df33f12b5d67, 0x9396dd7376e8bf554cbad1cee4ba385c361f2939629d032a8b567074055fd85a 


USDa is a yield-bearing stablecoin vault. You deposit USDC and receive USDa, an ERC-20 share token. The vault supplies the deposited capital as concentrated USDC/USDT liquidity on Uniswap v4; the trading fees it earns accrue to the share price, so USDa appreciates against USDC over time with no claiming or compounding step. It's an ERC-4626 vault internally (OpenZeppelin v5), but the standard mint/redeem entrypoints are disabled in favor of custom deposit/withdraw functions.

How it works:

Adaptive positioning. The vault reads a companion Uniswap v4 hook that records where swaps land and returns the tick ranges covering 90% / 99% / 99.9% of trading volume. The vault holds four positions: a thin full-range backstop plus three positions placed in those hook-reported bands, so most capital sits where most fees are generated.

Self-rebalancing. A best-effort rebalance runs at the end of every deposit and withdrawal (and can also be triggered permissionlessly), moving the hook-driven positions as the market drifts. No keeper or off-chain bot is required.

Donation-proof NAV. Net asset value is computed from position liquidity, uncollected fees, and internally tracked idle balances only — never from token.balanceOf. Sending tokens directly to the contract therefore cannot move the share price, which closes the standard ERC-4626 inflation/donation attack.

Oracle-free pricing with a peg clamp. Prices come from the pool's own sqrtPriceX96, not an external oracle. For valuation, that price is clamped into a configurable peg band, so an in-block price manipulation cannot inflate or deflate NAV to mint shares cheaply or redeem them richly. Deposits are also rejected when the pool is off peg.

Off-pool swaps. When the vault needs to rebalance token ratios, it never swaps in its own pool (which would move the price it values itself against). It routes through a separate deep pool with a backup router, behind a two-sided balance check that bounds any swap to "spent ≤ in, received ≥ out" — a bad quote can only fail, not cause a loss.

Pro-rata fee accounting on exit. A Uniswap position settles 100% of its accrued fees on any liquidity decrease; the vault withdrawal path detects this and pays each user only their proportional share of principal and fees, retaining the remainder for other holders.

Dual-token exit. Withdrawals can be taken in USDC or USDT. If USDT depegs, a user can redeem in USDT rather than realize a loss converting to USDC; the same peg-band logic that guards NAV also gates this path.

The codebase includes the vault contract, the distribution hook, a unit/fork test suite, and an adversarial security review (AUDIT.md) that found and fixed two critical issues (fee over-collection on withdrawal and spot-price NAV manipulation) plus several lower-severity items.