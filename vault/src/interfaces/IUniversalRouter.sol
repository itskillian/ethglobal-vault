// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IUniversalRouter
 * @notice Minimal local interface onto Uniswap's UniversalRouter (NOT vendored in these libs — it
 *         lives in the separate Uniswap/universal-router repo). The vault only needs `execute`.
 * @dev VERIFY-BEFORE-DEPLOY: confirm the deployed router on the target chain exposes the 3-arg
 *      `execute(bytes,bytes[],uint256)` form (selector 0x3593564c). Some older deployments only
 *      expose the 2-arg form without a deadline.
 */
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}
