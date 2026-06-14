// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {USDaVault} from "../src/USDaVault.sol";
import {USDaVaultHarness} from "./USDaVaultHarness.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/**
 * @title USDaVault unit tests (no fork)
 * @notice Covers the correctness-keystone math that needs no live v4: NAV USDT↔USDC valuation across
 *         BOTH token orderings, peg guard, slippage floor, decimals/offset, and the locked vanilla
 *         ERC4626 entrypoints. Liquidity/swap/deposit flows are exercised by the mainnet fork suite.
 */
contract USDaVaultUnitTest is Test {
    uint160 internal constant Q96 = 79228162514264337593543950336; // 2**96 => price 1.0

    MockERC20 usdc;
    MockERC20 usdt;

    // Two harnesses to cover both token orderings of the vault pool.
    USDaVaultHarness vaultUsdc0; // usdcIsToken0 == true
    USDaVaultHarness vaultUsdt0; // usdcIsToken0 == false

    address owner = address(0xA11CE);
    address dummyPM = address(0x1111);
    address dummyPosm = address(0x2222);
    address dummyUR = address(0x3333);
    address dummyHook = address(0x4444);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether", "USDT", 6);

        vaultUsdc0 = _deploy(Currency.wrap(address(usdc)), Currency.wrap(address(usdt)));
        vaultUsdt0 = _deploy(Currency.wrap(address(usdt)), Currency.wrap(address(usdc)));
    }

    function _deploy(Currency c0, Currency c1) internal returns (USDaVaultHarness v) {
        PoolKey memory vaultKey =
            PoolKey({currency0: c0, currency1: c1, fee: 100, tickSpacing: 1, hooks: IHooks(dummyHook)});
        // swap pool must differ from the vault pool (different fee => different id)
        PoolKey memory swapKey =
            PoolKey({currency0: c0, currency1: c1, fee: 500, tickSpacing: 10, hooks: IHooks(address(0))});
        v = new USDaVaultHarness(
            IERC20(address(usdc)),
            IERC20(address(usdt)),
            IPoolManager(dummyPM),
            IPositionManager(dummyPosm),
            IUniversalRouter(dummyUR),
            vaultKey,
            swapKey,
            address(0),
            owner
        );
    }

    // ── orientation wiring ──────────────────────────────────────────────

    function test_usdcIsToken0_derivedBothWays() public view {
        assertTrue(vaultUsdc0.usdcIsToken0(), "USDC should be token0");
        assertFalse(vaultUsdt0.usdcIsToken0(), "USDT should be token0");
    }

    function test_decimals_is12() public view {
        // USDa = asset(6) + offset(6) = 12
        assertEq(vaultUsdc0.decimals(), 12);
        assertEq(vaultUsdt0.decimals(), 12);
    }

    // ── NAV price valuation (§2/§5) ─────────────────────────────────────

    function test_usdtToUsdc_atPeg_isIdentity_bothOrderings() public view {
        assertEq(vaultUsdc0.exp_usdtToUsdc(1_000_000, Q96), 1_000_000, "usdc0 @peg");
        assertEq(vaultUsdt0.exp_usdtToUsdc(1_000_000, Q96), 1_000_000, "usdt0 @peg");
    }

    function test_spotPriceWad_atPeg_isOne_bothOrderings() public view {
        assertEq(vaultUsdc0.exp_spotPriceWad(Q96), 1e18, "usdc0 spot");
        assertEq(vaultUsdt0.exp_spotPriceWad(Q96), 1e18, "usdt0 spot");
    }

    function test_valueUSDC_atPeg_sumsLegs_bothOrderings() public view {
        // 100 USDC leg + 100 USDT leg @ peg == 200 USDC, regardless of which token is token0.
        assertEq(vaultUsdc0.exp_valueUSDC(100e6, 100e6, Q96), 200e6, "usdc0 value");
        assertEq(vaultUsdt0.exp_valueUSDC(100e6, 100e6, Q96), 200e6, "usdt0 value");
    }

    /// @dev When USDT is dearer than USDC (price moves), the USDT leg must be valued >1:1 and the
    ///      orientation must flip consistently so both harnesses agree on the USDT value.
    function test_usdtToUsdc_offPeg_consistentAcrossOrderings() public view {
        // sqrtP for token1/token0 price = 1.0201 (sqrt = 1.01): USDC0 => USDC-per-USDT = 1/1.0201.
        uint160 sqrtUp = uint160((uint256(Q96) * 101) / 100); // ~ +1% sqrt
        uint256 vUsdc0 = vaultUsdc0.exp_usdtToUsdc(1_000_000, sqrtUp); // USDC token0: 1/price < 1
        uint256 vUsdt0 = vaultUsdt0.exp_usdtToUsdc(1_000_000, sqrtUp); // USDT token0: price > 1

        // usdc0 prices USDT below 1 (USDT got cheaper in USDC terms); usdt0 prices it above 1.
        assertLt(vUsdc0, 1_000_000, "usdc0 off-peg < 1");
        assertGt(vUsdt0, 1_000_000, "usdt0 off-peg > 1");
        // Both legs are reciprocals (1/price and price); product ≈ 1e12 within the rounding of two
        // separate mulDivs + the crude sqrt approximation used to build sqrtUp. 0.1% tolerance.
        assertApproxEqRel(vUsdc0 * vUsdt0, 1e12, 1e15); // within 0.1% relative
    }

    // ── peg guard (§9.2) ────────────────────────────────────────────────

    function test_pegOk_true_atPeg() public view {
        assertTrue(vaultUsdc0.exp_pegOk(Q96));
        assertTrue(vaultUsdt0.exp_pegOk(Q96));
    }

    function test_pegOk_false_whenDepegged() public view {
        // ~ -10% in sqrt => price ~0.81; well outside [0.995, 1.005].
        uint160 sqrtDown = uint160((uint256(Q96) * 90) / 100);
        assertFalse(vaultUsdc0.exp_pegOk(sqrtDown));
        assertFalse(vaultUsdt0.exp_pegOk(sqrtDown));
    }

    // ── slippage floor (§10b) ───────────────────────────────────────────

    function test_minOut_appliesSlippageBps() public view {
        // default swapMaxSlippageBps = 30 => minOut = amt * 9970 / 10000
        assertEq(vaultUsdc0.exp_minOut(1_000_000), 997_000);
    }

    // ── locked vanilla ERC4626 entrypoints (§ pattern a) ────────────────

    function test_vanillaEntrypoints_revert() public {
        vm.expectRevert(USDaVault.VanillaEntrypointDisabled.selector);
        vaultUsdc0.deposit(1, address(this));

        vm.expectRevert(USDaVault.VanillaEntrypointDisabled.selector);
        vaultUsdc0.mint(1, address(this));

        vm.expectRevert(USDaVault.VanillaEntrypointDisabled.selector);
        vaultUsdc0.withdraw(1, address(this), address(this));

        vm.expectRevert(USDaVault.VanillaEntrypointDisabled.selector);
        vaultUsdc0.redeem(1, address(this), address(this));
    }

    // ── access control ──────────────────────────────────────────────────

    function test_selfOnly_guardedSwap_reverts() public {
        vm.expectRevert(USDaVault.OnlySelf.selector);
        vaultUsdc0._guardedSwap(address(usdc), address(usdt), 1, 1, false);
    }

    function test_selfOnly_rebalanceStep_reverts() public {
        vm.expectRevert(USDaVault.OnlySelf.selector);
        vaultUsdc0._rebalanceStep(1, -10, 10, 1);
    }

    function test_onlyOwner_setPaused() public {
        vm.expectRevert();
        vaultUsdc0.setPaused(true);

        vm.prank(owner);
        vaultUsdc0.setPaused(true);
        assertTrue(vaultUsdc0.paused());
    }

    function test_constructor_rejectsSwapEqualsVaultPool() public {
        PoolKey memory k =
            PoolKey({currency0: Currency.wrap(address(usdc)), currency1: Currency.wrap(address(usdt)), fee: 100, tickSpacing: 1, hooks: IHooks(dummyHook)});
        vm.expectRevert(USDaVault.SwapPoolIsVaultPool.selector);
        new USDaVaultHarness(
            IERC20(address(usdc)),
            IERC20(address(usdt)),
            IPoolManager(dummyPM),
            IPositionManager(dummyPosm),
            IUniversalRouter(dummyUR),
            k,
            k, // same key => same id => must revert
            address(0),
            owner
        );
    }
}
