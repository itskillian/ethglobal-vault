// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IBackupSwapRouter
 * @notice Minimal adapter interface for the vault's BACKUP swap venue (ARCHITECTURE §10b, tier 2).
 *         The vault keeps no v2/v3/v4 routing knowledge itself: the owner deploys an adapter that
 *         internally builds a UniversalRouter (or other) program reaching the deepest USDC/USDT
 *         liquidity, and exposes this one function. The vault `forceApprove`s exactly `amountIn` to
 *         the adapter, calls `swapExactIn`, then resets the approval and asserts a two-sided balance
 *         guard around the whole call — so a misbehaving adapter can only revert, never cause a loss.
 * @dev The adapter MUST pull `amountIn` of `tokenIn` from the caller (the vault) and deliver the
 *      output of `tokenOut` to `recipient`, reverting if it cannot deliver at least `minOut`.
 */
interface IBackupSwapRouter {
    /// @param tokenIn   Token the vault is selling (USDC or USDT).
    /// @param tokenOut  Token the vault wants (the other leg).
    /// @param amountIn  Exact input amount the vault has approved.
    /// @param minOut    Minimum acceptable output; adapter must revert if unmet.
    /// @param recipient Address to receive `tokenOut` (always the vault).
    /// @return out      Amount of `tokenOut` delivered.
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 out);
}
