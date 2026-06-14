// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {USDaVault} from "../src/USDaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @dev Exposes internal NAV/price/sizing helpers for unit testing (no fork needed for pure math).
contract USDaVaultHarness is USDaVault {
    constructor(
        IERC20 _usdc,
        IERC20 _usdt,
        IPoolManager _pm,
        IPositionManager _posm,
        IUniversalRouter _ur,
        PoolKey memory vaultPoolKey,
        PoolKey memory swapPoolKey_,
        address _backupRouter,
        address _owner
    ) USDaVault(_usdc, _usdt, _pm, _posm, _ur, vaultPoolKey, swapPoolKey_, _backupRouter, _owner) {}

    function exp_usdtToUsdc(uint256 usdtAmt, uint160 sqrtP) external view returns (uint256) {
        return _usdtToUsdc(usdtAmt, sqrtP);
    }

    function exp_valueUSDC(uint256 amt0, uint256 amt1, uint160 sqrtP) external view returns (uint256) {
        return _valueUSDC(amt0, amt1, sqrtP);
    }

    function exp_spotPriceWad(uint160 sqrtP) external view returns (uint256) {
        return _spotPriceWad(sqrtP);
    }

    function exp_pegOk(uint160 sqrtP) external view returns (bool) {
        return _pegOk(sqrtP);
    }

    function exp_minOut(uint256 amtIn) external view returns (uint256) {
        return _minOut(amtIn);
    }

    function exp_align(int24 ticks) external view returns (int24) {
        return _align(ticks);
    }

    function exp_priceWadToSqrt(uint256 priceWad) external view returns (uint160) {
        return _priceWadToSqrt(priceWad);
    }

    function navBand() external view returns (uint160 lo, uint160 hi) {
        return (navSqrtLow, navSqrtHigh);
    }

    /// @dev The C2 clamp applied to an arbitrary input sqrt (mirrors _navSqrt without reading the pool).
    function exp_clampToNavBand(uint160 s) external view returns (uint160) {
        if (s < navSqrtLow) return navSqrtLow;
        if (s > navSqrtHigh) return navSqrtHigh;
        return s;
    }

    /// @dev USDT→USDC valuation at the clamped input price — the value NAV would assign the USDT leg.
    function exp_navValueOfUsdt(uint256 usdtAmt, uint160 spotSqrt) external view returns (uint256) {
        uint160 s = spotSqrt < navSqrtLow ? navSqrtLow : (spotSqrt > navSqrtHigh ? navSqrtHigh : spotSqrt);
        return _usdtToUsdc(usdtAmt, s);
    }

    // C3 idle-accounting backbone (no pool read; _reconcileIdle reads token balanceOf):
    function exp_creditIdle(uint256 amt0, uint256 amt1) external {
        _creditIdle(amt0, amt1);
    }

    function exp_reconcileIdle(uint256 b0, uint256 b1) external {
        _reconcileIdle(b0, b1);
    }
}
