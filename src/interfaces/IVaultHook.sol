// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/**
 * @title IVaultHook
 * @notice Minimal view interface onto the distribution hook (see ../vault-hook/VaultHook.sol).
 *         The hook records a time-decayed histogram of where price trades on the vault pool and
 *         turns it into nested percentile bands. The vault consumes those bands as positions 1–3.
 * @dev `Range` mirrors the hook's struct exactly (two packed int24, raw tickSpacing-aligned ticks);
 *      ABI decoding is structural, so an identical local definition decodes the hook's return value.
 *      `ok == false` means too little data to reposition on — the vault must hold / use fallbacks.
 */
interface IVaultHook {
    struct Range {
        int24 tickLower;
        int24 tickUpper;
    }

    /// @param id             The vault pool's id (`poolKey.toId()`).
    /// @param confidencesBps Confidence levels in bps (e.g. [9000, 9900, 9990]); each ≤ 10000.
    /// @return ranges One `[tickLower, tickUpper]` per confidence, raw and tickSpacing-aligned.
    /// @return ok     False when total weight < minData (cold/thin pool); `ranges` is then zeroed.
    function computeRanges(PoolId id, uint16[] calldata confidencesBps)
        external
        view
        returns (Range[] memory ranges, bool ok);
}
