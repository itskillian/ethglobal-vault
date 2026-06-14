// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {USDaVault} from "../src/USDaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/**
 * @title USDaVault mainnet-fork tests
 * @notice Exercises the vault against the REAL v4 deployment + real USDC/USDT. Run with an RPC:
 *           ETH_RPC_URL=<https-mainnet-rpc> forge test --match-path test/USDaVault.fork.t.sol -vv
 *         Self-skips (no failure) when ETH_RPC_URL is unset.
 *
 *         Scope: deposit → NAV → withdraw share-math against real chain state (real USDC token,
 *         real PoolManager.getSlot0). This needs NO seeded pool liquidity because pre-initialize the
 *         vault holds value as idleUSDC and touches no positions. The FULL pool lifecycle
 *         (initialize → 4 positions → swap → rebalance) additionally requires a deployed USDC/USDT
 *         v4 pool carrying YOUR VaultHook plus a seeded primary swap pool — wire those in to extend.
 */
contract USDaVaultForkTest is Test {
    // verified mainnet (chain id 1)
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant UNIVERSAL_ROUTER = 0x4C82D1fBFe28C977cBB58D8C7FF8FCF9F70a2cCA;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    USDaVault vault;
    address user = address(0xBEEF);
    address owner = address(0xA11CE);
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // skip suite without an RPC
        vm.createSelectFork(rpc);
        forked = true;

        // Vault pool: USDC/USDT, no hook (rebalance's hook call is try/caught → degrades to "hold").
        PoolKey memory vaultKey = _key(USDC, USDT, 100, 1, address(0));
        // Primary swap pool: a different USDC/USDT pool id (different fee/spacing).
        PoolKey memory swapKey = _key(USDC, USDT, 500, 10, address(0));

        vault = new USDaVault(
            IERC20(USDC),
            IERC20(USDT),
            IPoolManager(POOL_MANAGER),
            IPositionManager(POSITION_MANAGER),
            IUniversalRouter(UNIVERSAL_ROUTER),
            vaultKey,
            swapKey,
            address(0),
            owner
        );
    }

    function _key(address a, address b, uint24 fee, int24 spacing, address h) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(h)
        });
    }

    function test_deployedV4ContractsHaveCode() public view {
        if (!forked) return;
        assertGt(POOL_MANAGER.code.length, 0, "PoolManager");
        assertGt(POSITION_MANAGER.code.length, 0, "PositionManager");
        assertGt(UNIVERSAL_ROUTER.code.length, 0, "UniversalRouter");
        assertGt(PERMIT2.code.length, 0, "Permit2");
        assertGt(USDC.code.length, 0, "USDC");
        assertGt(USDT.code.length, 0, "USDT");
    }

    function test_wiring() public view {
        if (!forked) return;
        assertEq(vault.decimals(), 12, "USDa decimals");
        assertTrue(vault.usdcIsToken0(), "USDC is token0 on mainnet (0xA0.. < 0xdA..)");
        assertEq(vault.asset(), USDC, "asset == USDC");
    }

    /// @dev Deposit prices off pre-deposit NAV; NAV uses idleUSDC, never balanceOf (donation-proof).
    function test_deposit_navAndShares() public {
        if (!forked) return;
        uint256 amt = 10_000e6; // 10k USDC
        deal(USDC, user, amt);

        vm.startPrank(user);
        IERC20(USDC).approve(address(vault), amt);
        uint256 shares = vault.deposit(amt, 0, block.timestamp);
        vm.stopPrank();

        assertEq(vault.idleUSDC(), amt, "idle credited");
        assertEq(vault.totalAssets(), amt, "NAV == deposit");
        assertGt(shares, 0, "shares minted");
        // First deposit with offset 6: shares = amt * (0 + 1e6) / (0 + 1) = amt * 1e6.
        assertEq(shares, amt * 1e6, "share math (virtual shares offset 6)");
        assertEq(vault.balanceOf(user), shares, "user holds shares");
    }

    /// @dev Raw token donation must NOT move share price (NAV ignores balanceOf).
    function test_donationIsInert() public {
        if (!forked) return;
        deal(USDC, user, 1_000e6);
        vm.startPrank(user);
        IERC20(USDC).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, 0, block.timestamp);
        vm.stopPrank();

        uint256 navBefore = vault.totalAssets();
        deal(USDC, address(this), 500e6);
        IERC20(USDC).transfer(address(vault), 500e6); // donation
        assertEq(vault.totalAssets(), navBefore, "donation inert");
    }

    /// @dev USDC withdraw fast path: paid from idle, preserves per-share NAV.
    function test_withdraw_fastPath() public {
        if (!forked) return;
        uint256 amt = 5_000e6;
        deal(USDC, user, amt);
        vm.startPrank(user);
        IERC20(USDC).approve(address(vault), amt);
        uint256 shares = vault.deposit(amt, 0, block.timestamp);

        uint256 half = shares / 2;
        uint256 out = vault.withdraw(half, USDC, 0, block.timestamp);
        vm.stopPrank();

        // ~half minus the tiny virtual-share/dead-share haircut (forgiving abs tolerance).
        assertApproxEqAbs(out, amt / 2, 1e3, "out ~ half (rounding)");
        assertEq(IERC20(USDC).balanceOf(user), out, "user received USDC");
        assertApproxEqAbs(vault.totalAssets(), amt - out, 1e3, "NAV reduced by payout");
    }
}
