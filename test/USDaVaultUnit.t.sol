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

    // ── C2: NAV price-clamp band ────────────────────────────────────────

    function test_navBand_edgesMapToPegPrices_bothOrderings() public view {
        // Valuing 1 USDT at each band edge must yield exactly the peg-band prices (0.995 / 1.005), and
        // the two edges must be the two bounds — in both token orderings.
        for (uint256 k = 0; k < 2; k++) {
            USDaVaultHarness v = k == 0 ? vaultUsdc0 : vaultUsdt0;
            (uint160 lo, uint160 hi) = v.navBand();
            assertLt(lo, hi, "band ordered");
            uint256 atLo = v.exp_navValueOfUsdt(1e18, lo);
            uint256 atHi = v.exp_navValueOfUsdt(1e18, hi);
            uint256 min_ = atLo < atHi ? atLo : atHi;
            uint256 max_ = atLo < atHi ? atHi : atLo;
            assertApproxEqRel(min_, 0.995e18, 1e15, "low edge ~ pegLow"); // 0.1% tol
            assertApproxEqRel(max_, 1.005e18, 1e15, "high edge ~ pegHigh");
        }
    }

    /// @dev Core C2 property: NAV's USDT-leg valuation cannot be pushed beyond the peg band no matter how
    ///      far spot is manipulated, in BOTH token orderings.
    function test_navClamp_boundsUsdtValuationUnderManipulation() public view {
        // Push spot way down and way up; the clamped valuation of 1e18 USDT must stay within [0.995,1.005].
        uint160 wayDown = uint160(uint256(Q96) / 2); // price far below peg
        uint160 wayUp = uint160(uint256(Q96) * 2); // price far above peg
        for (uint256 k = 0; k < 2; k++) {
            USDaVaultHarness v = k == 0 ? vaultUsdc0 : vaultUsdt0;
            uint256 vd = v.exp_navValueOfUsdt(1e18, wayDown);
            uint256 vu = v.exp_navValueOfUsdt(1e18, wayUp);
            assertGe(vd, 0.995e18 - 1e12, "clamped low >= pegLow");
            assertLe(vd, 1.005e18 + 1e12, "clamped low <= pegHigh");
            assertGe(vu, 0.995e18 - 1e12, "clamped high >= pegLow");
            assertLe(vu, 1.005e18 + 1e12, "clamped high <= pegHigh");
        }
    }

    function test_navClamp_passesThroughInsideBand() public view {
        // At exactly peg, the clamp is a no-op and valuation is 1:1.
        assertApproxEqAbs(vaultUsdc0.exp_navValueOfUsdt(1e18, Q96), 1e18, 1e9);
        assertApproxEqAbs(vaultUsdt0.exp_navValueOfUsdt(1e18, Q96), 1e18, 1e9);
    }

    // ── C3: dual-token idle accounting backbone ─────────────────────────

    function test_creditIdle_mapsByTokenOrdering() public {
        // usdc0: token0=USDC, token1=USDT → credit(amt0,amt1) adds amt0 to idleUSDC, amt1 to idleUSDT.
        vaultUsdc0.exp_creditIdle(100, 7);
        assertEq(vaultUsdc0.idleUSDC(), 100, "usdc0 idleUSDC");
        assertEq(vaultUsdc0.idleUSDT(), 7, "usdc0 idleUSDT");
        // usdt0: token0=USDT, token1=USDC → mapping flips.
        vaultUsdt0.exp_creditIdle(100, 7);
        assertEq(vaultUsdt0.idleUSDC(), 7, "usdt0 idleUSDC");
        assertEq(vaultUsdt0.idleUSDT(), 100, "usdt0 idleUSDT");
    }

    /// @dev _reconcileIdle applies the SIGNED balance delta since (b0,b1) to the idle counters — this is
    ///      what folds deploy residuals back into NAV (C3). Donation-proof because it uses deltas only.
    function test_reconcileIdle_appliesSignedDelta() public {
        // Seed harness token balances: 1000 USDC (token0), 400 USDT (token1).
        usdc.mint(address(vaultUsdc0), 1000);
        usdt.mint(address(vaultUsdc0), 400);
        // Pretend before-balances were (1200, 300): USDC dropped 200 (consumed), USDT rose 100 (gained).
        vaultUsdc0.exp_reconcileIdle(1200, 300);
        // idleUSDC -= 200 (floored at 0 since it was 0) → 0; idleUSDT += 100 → 100.
        assertEq(vaultUsdc0.idleUSDC(), 0, "usdc floored (consumed > prior idle)");
        assertEq(vaultUsdc0.idleUSDT(), 100, "usdt gained credited");
    }

    function test_reconcileIdle_creditsResidualGain() public {
        // Pre-seed idle via creditIdle, then reconcile a net gain on both legs.
        vaultUsdc0.exp_creditIdle(500, 500); // idleUSDC=500, idleUSDT=500
        usdc.mint(address(vaultUsdc0), 600);
        usdt.mint(address(vaultUsdc0), 600);
        // before-balances (100,100): both rose by 500 → credit 500 each.
        vaultUsdc0.exp_reconcileIdle(100, 100);
        assertEq(vaultUsdc0.idleUSDC(), 1000, "idleUSDC += 500");
        assertEq(vaultUsdc0.idleUSDT(), 1000, "idleUSDT += 500");
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
