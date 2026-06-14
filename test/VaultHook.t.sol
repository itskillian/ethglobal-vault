// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {VaultHook} from "../src/vaultHook.sol";

contract VaultHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    VaultHook internal hook;
    PoolKey internal key_;
    PoolId internal id_;

    int24 internal constant TICK_SPACING = 60; // fee 3000
    uint16[] internal CONF; // [9000, 9900, 9990]

    address internal owner = address(this);
    address internal attacker = address(0xBEEF);

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Mine-free deploy: etch the hook at an address whose low bits encode its permissions.
        address flags = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG));
        deployCodeTo("vaultHook.sol:VaultHook", abi.encode(IPoolManager(address(manager)), owner), flags);
        hook = VaultHook(flags);

        (key_, id_) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

        // Wide liquidity so swaps have room to move the tick across many spacings.
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({tickLower: -12000, tickUpper: 12000, liquidityDelta: int256(100e18), salt: 0}),
            ZERO_BYTES
        );

        CONF.push(9000);
        CONF.push(9900);
        CONF.push(9990);
    }

    // --- helpers ----------------------------------------------------------------

    /// @dev Alternating exact-in swaps so the tick oscillates and scatters weight across ticks.
    function _seedSwaps(uint256 n, uint256 amt) internal {
        for (uint256 i; i < n; i++) {
            swap(key_, i % 2 == 0, -int256(amt), ZERO_BYTES);
        }
    }

    function _currentTick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(id_);
    }

    // --- afterInitialize --------------------------------------------------------

    function test_afterInitialize_seedsState() public view {
        (
            uint32 t0,
            uint32 halfLife,
            uint8 weighting,
            int24 tickSpacing,
            int24 minTick,
            int24 maxTick,
            uint256 minData,
            bool initialized
        ) = hook.poolConfig(id_);

        assertEq(t0, uint32(block.timestamp), "t0");
        assertEq(halfLife, 30 days, "halfLife");
        assertEq(weighting, 0, "count weighting default");
        assertEq(tickSpacing, TICK_SPACING, "tickSpacing");
        assertEq(minTick, maxTick, "bounds seeded equal at init");
        assertEq(minData, 3e18, "minData default");
        assertTrue(initialized, "initialized");
    }

    function test_afterInitialize_seedsCaptureWindow() public view {
        // Pool initialised at tick 0 -> window ~ ±500 ticks (~±5%), tickSpacing-aligned.
        (int24 lower, int24 upper) = hook.captureWindow(id_);
        assertLt(lower, int24(0), "window lower below peg");
        assertGt(upper, int24(0), "window upper above peg");
        assertGe(lower, int24(-600), "lower ~ -5%");
        assertLe(upper, int24(600), "upper ~ +5%");
    }

    // --- afterSwap capture -------------------------------------------------------

    function test_afterSwap_recordsWeight() public {
        swap(key_, true, -1e18, ZERO_BYTES);
        int24 tick = _currentTick();
        assertGt(hook.weightAt(id_, tick), 0, "weight recorded at landing tick");
    }

    function test_afterSwap_movesAcrossTicks() public {
        _seedSwaps(20, 1e18);
        (,,,, int24 minTick, int24 maxTick,,) = hook.poolConfig(id_);
        assertLt(minTick, maxTick, "distribution spans multiple ticks");
    }

    function test_negativeTicks_recorded() public {
        // Push price down (zeroForOne); a 1e18 swap lands ~-200 ticks: negative but inside the window.
        swap(key_, true, -1e18, ZERO_BYTES);
        int24 tick = _currentTick();
        assertLt(tick, int24(0), "landed at negative tick");
        assertGt(hook.weightAt(id_, tick), 0, "weight recorded at negative tick");
    }

    function test_captureWindow_skipsOutOfWindow() public {
        hook.setCaptureWindow(id_, -60, 60); // very tight window: compressed [-1, 1]
        swap(key_, true, -1e18, ZERO_BYTES); // lands well past -60 ticks
        int24 tick = _currentTick();
        assertLt(tick, int24(-60), "swap landed outside the tight window");
        assertEq(hook.weightAt(id_, tick), 0, "out-of-window swap not recorded");
        (,,,, int24 minTick, int24 maxTick,,) = hook.poolConfig(id_);
        assertEq(minTick, maxTick, "skipped swap did not widen the scan bounds");
    }

    function test_setCaptureWindow_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.setCaptureWindow(id_, -60, 60);
    }

    function test_setCaptureWindow_rejectsBadRange() public {
        vm.expectRevert(VaultHook.InvalidCaptureWindow.selector);
        hook.setCaptureWindow(id_, 60, 60); // lower >= upper
    }

    // --- computeRanges -----------------------------------------------------------

    function test_computeRanges_insufficientData() public {
        swap(key_, true, -1e18, ZERO_BYTES); // 1 swap < MIN_DATA (3)
        (VaultHook.Range[] memory ranges, bool ok) = hook.computeRanges(id_, CONF);
        assertFalse(ok, "insufficient data -> sentinel");
        assertEq(ranges.length, 3, "length still matches request");
    }

    function test_computeRanges_emptyPool() public view {
        (, bool ok) = hook.computeRanges(id_, CONF);
        assertFalse(ok, "no swaps -> sentinel");
    }

    function test_computeRanges_nestedBands() public {
        _seedSwaps(40, 1e18);
        (VaultHook.Range[] memory r, bool ok) = hook.computeRanges(id_, CONF);
        assertTrue(ok, "sufficient data");

        for (uint256 j; j < 3; j++) {
            assertLe(r[j].tickLower, r[j].tickUpper, "lower <= upper");
            assertEq(r[j].tickLower % TICK_SPACING, int24(0), "lower aligned");
            assertEq(r[j].tickUpper % TICK_SPACING, int24(0), "upper aligned");
        }
        // Nesting: 99.9% band ⊇ 99% band ⊇ 90% band.
        assertLe(r[1].tickLower, r[0].tickLower, "99% lower <= 90% lower");
        assertGe(r[1].tickUpper, r[0].tickUpper, "99% upper >= 90% upper");
        assertLe(r[2].tickLower, r[1].tickLower, "99.9% lower <= 99% lower");
        assertGe(r[2].tickUpper, r[1].tickUpper, "99.9% upper >= 99% upper");
    }

    // --- decay: ratios cancel on read; absolute MIN_DATA does not ---------------

    function test_decay_ratiosCancel_rangesStableShortWarp() public {
        _seedSwaps(40, 1e18);
        (VaultHook.Range[] memory before, bool okBefore) = hook.computeRanges(id_, CONF);
        assertTrue(okBefore);

        // No swaps; advance a fraction of a half-life. Stored weights are unchanged and the decay
        // factor cancels in the percentile ratios -> identical ranges.
        vm.warp(block.timestamp + 7 days);
        (VaultHook.Range[] memory afterWarp, bool okAfter) = hook.computeRanges(id_, CONF);
        assertTrue(okAfter, "still enough data after short warp");

        for (uint256 j; j < 3; j++) {
            assertEq(afterWarp[j].tickLower, before[j].tickLower, "lower stable under decay");
            assertEq(afterWarp[j].tickUpper, before[j].tickUpper, "upper stable under decay");
        }
    }

    function test_decay_dataGoesStale() public {
        _seedSwaps(20, 1e18); // ~20 effective recent swaps
        (, bool okFresh) = hook.computeRanges(id_, CONF);
        assertTrue(okFresh, "fresh data ok");

        vm.warp(block.timestamp + 120 days); // 4 half-lives -> ~20/16 < MIN_DATA(10)
        (, bool okStale) = hook.computeRanges(id_, CONF);
        assertFalse(okStale, "stale data falls below MIN_DATA");
    }

    function test_growthFactor_doublesPerHalfLife() public {
        assertApproxEqRel(hook.growthFactor(id_), 1e18, 1e12, "g=1 at t0");
        vm.warp(block.timestamp + 30 days);
        assertApproxEqRel(hook.growthFactor(id_), 2e18, 1e15, "g=2 after one half-life");
        vm.warp(block.timestamp + 30 days);
        assertApproxEqRel(hook.growthFactor(id_), 4e18, 1e15, "g=4 after two half-lives");
    }

    function test_growthFactor_clampedNoRevert() public {
        // 100 years idle: exponent saturates at MAX_EXP, expWad must not revert.
        vm.warp(block.timestamp + 36500 days);
        uint256 g = hook.growthFactor(id_);
        assertGt(g, 0, "clamped growth factor finite");
        // A swap after a wildly overdue period must still succeed.
        swap(key_, true, -1e18, ZERO_BYTES);
    }

    // --- rebase ------------------------------------------------------------------

    function test_rebase_preservesRanges() public {
        _seedSwaps(40, 1e18);
        vm.warp(block.timestamp + 45 days); // let g grow before rebasing
        (VaultHook.Range[] memory before,) = hook.computeRanges(id_, CONF);

        hook.rebase(id_);

        (VaultHook.Range[] memory afterRebase, bool ok) = hook.computeRanges(id_, CONF);
        assertTrue(ok, "still ok after rebase");
        for (uint256 j; j < 3; j++) {
            assertEq(afterRebase[j].tickLower, before[j].tickLower, "lower preserved across rebase");
            assertEq(afterRebase[j].tickUpper, before[j].tickUpper, "upper preserved across rebase");
        }
        assertApproxEqRel(hook.growthFactor(id_), 1e18, 1e12, "g reset to 1 after rebase");
    }

    function test_rebase_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.rebase(id_);
    }

    // --- poke (auto-rebase) -----------------------------------------------------

    function test_poke_noopBeforeInterval() public {
        _seedSwaps(10, 1e18);
        (uint32 t0Before,,,,,,,) = hook.poolConfig(id_);
        vm.warp(block.timestamp + 3 days); // < 7-day default interval
        hook.poke(id_);
        (uint32 t0After,,,,,,,) = hook.poolConfig(id_);
        assertEq(t0After, t0Before, "no rebase before the interval elapses");
    }

    function test_poke_rebasesAfterInterval() public {
        _seedSwaps(40, 1e18);
        (VaultHook.Range[] memory before,) = hook.computeRanges(id_, CONF);

        vm.warp(block.timestamp + 8 days); // > 7-day interval
        hook.poke(id_); // permissionless

        assertApproxEqRel(hook.growthFactor(id_), 1e18, 1e12, "epoch reset by poke");
        (VaultHook.Range[] memory afterPoke, bool ok) = hook.computeRanges(id_, CONF);
        assertTrue(ok, "still ok after poke");
        for (uint256 j; j < 3; j++) {
            // Dense distribution -> nothing is dust -> bands identical pre/post.
            assertEq(afterPoke[j].tickLower, before[j].tickLower, "lower preserved by poke");
            assertEq(afterPoke[j].tickUpper, before[j].tickUpper, "upper preserved by poke");
        }
    }

    function test_poke_prunesStaleTicks() public {
        hook.setCaptureWindow(id_, -12000, 12000); // widen so we can place a far tick
        // A: an early swap far from peg, recorded while g ~ 1.
        swap(key_, true, -1e18, ZERO_BYTES);
        int24 tickA = _currentTick();
        swap(key_, false, -1e18, ZERO_BYTES); // drift back toward peg
        assertGt(hook.weightAt(id_, tickA), 0, "A present before prune");

        // Many half-lives later, build a dense high-g cluster elsewhere that dwarfs A.
        vm.warp(block.timestamp + 750 days);
        swap(key_, false, -3e18, ZERO_BYTES); // push price up, away from A
        _seedSwaps(10, 1e18);

        hook.poke(id_); // interval long elapsed -> rebase + prune
        assertEq(hook.weightAt(id_, tickA), 0, "stale far tick pruned out");
    }

    function test_setRebaseInterval_bounds() public {
        vm.expectRevert(VaultHook.InvalidRebaseInterval.selector);
        hook.setRebaseInterval(id_, 1 hours); // below MIN
        vm.expectRevert(VaultHook.InvalidRebaseInterval.selector);
        hook.setRebaseInterval(id_, 400 days); // above MAX
        hook.setRebaseInterval(id_, 14 days); // ok
    }

    function test_setRebaseInterval_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.setRebaseInterval(id_, 14 days);
    }

    function test_setPruneFraction_bounds() public {
        vm.expectRevert(VaultHook.InvalidPruneFraction.selector);
        hook.setPruneFraction(id_, 1999); // non-zero but below MIN_PRUNE_FRACTION
        hook.setPruneFraction(id_, 0); // 0 is the "pruning disabled" sentinel, allowed
        hook.setPruneFraction(id_, 2000); // at the floor, ok
        hook.setPruneFraction(id_, 1e6); // less aggressive, ok
    }

    function test_setPruneFraction_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.setPruneFraction(id_, 1e5);
    }

    function test_rebaseConfig_view() public {
        (uint32 interval, uint256 frac) = hook.rebaseConfig(id_);
        assertEq(interval, 7 days, "default rebase interval");
        assertEq(frac, 1e4, "default prune fraction");

        hook.setRebaseInterval(id_, 14 days);
        hook.setPruneFraction(id_, 5000);
        (interval, frac) = hook.rebaseConfig(id_);
        assertEq(interval, 14 days, "updated rebase interval");
        assertEq(frac, 5000, "updated prune fraction");
    }

    /// @dev Mirror of {test_poke_prunesStaleTicks} but with pruning disabled: the same far stale tick
    ///      that would normally be swept must survive (its renormalised weight is tiny but non-zero).
    function test_setPruneFraction_disabledKeepsStaleTicks() public {
        hook.setPruneFraction(id_, 0); // disable pruning
        hook.setCaptureWindow(id_, -12000, 12000);
        swap(key_, true, -1e18, ZERO_BYTES);
        int24 tickA = _currentTick();
        swap(key_, false, -1e18, ZERO_BYTES);

        vm.warp(block.timestamp + 750 days);
        swap(key_, false, -3e18, ZERO_BYTES);
        _seedSwaps(10, 1e18);

        hook.poke(id_); // rebase fires, but with pruneFraction == 0 nothing non-zero is dropped
        assertGt(hook.weightAt(id_, tickA), 0, "stale far tick retained when pruning disabled");
    }

    // --- config ------------------------------------------------------------------

    function test_setConfig_updates() public {
        hook.setConfig(id_, 60 days, 1, 5e18);
        (, uint32 halfLife, uint8 weighting,,,, uint256 minData,) = hook.poolConfig(id_);
        assertEq(halfLife, 60 days);
        assertEq(weighting, 1);
        assertEq(minData, 5e18);
    }

    function test_setConfig_rejectsBadHalfLife() public {
        vm.expectRevert(VaultHook.InvalidHalfLife.selector);
        hook.setConfig(id_, 1 hours, 0, 10e18); // below MIN_HALF_LIFE
        vm.expectRevert(VaultHook.InvalidHalfLife.selector);
        hook.setConfig(id_, 400 days, 0, 10e18); // above MAX_HALF_LIFE
    }

    function test_setConfig_rejectsBadWeighting() public {
        vm.expectRevert(VaultHook.InvalidWeighting.selector);
        hook.setConfig(id_, 30 days, 2, 10e18);
    }

    function test_setConfig_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.setConfig(id_, 30 days, 0, 10e18);
    }

    function test_setConfig_rejectsBadMinData() public {
        vm.expectRevert(VaultHook.InvalidMinData.selector);
        hook.setConfig(id_, 30 days, 0, 0); // 0 disables the sentinel
        vm.expectRevert(VaultHook.InvalidMinData.selector);
        hook.setConfig(id_, 30 days, 0, 1e31); // above MAX_MIN_DATA
    }

    function test_setConfig_weightingChangeBeforeDataAllowed() public {
        hook.setConfig(id_, 30 days, 1, 1e18); // no swaps recorded yet -> allowed
        (,, uint8 weighting,,,,,) = hook.poolConfig(id_);
        assertEq(weighting, 1, "weighting switched before data");
    }

    function test_setConfig_weightingLockedAfterData() public {
        _seedSwaps(2, 1e18); // records weight -> started = true
        vm.expectRevert(VaultHook.WeightingLocked.selector);
        hook.setConfig(id_, 30 days, 1, 10e18); // COUNT -> VOLUME blocked
        // Same weighting (tuning halfLife/minData) is still allowed after data.
        hook.setConfig(id_, 60 days, 0, 10e18);
        (, uint32 halfLife,,,,,,) = hook.poolConfig(id_);
        assertEq(halfLife, 60 days, "halfLife still tunable after data");
    }

    function test_computeRanges_rejectsBadConfidence() public {
        _seedSwaps(20, 1e18);
        uint16[] memory bad = new uint16[](1);
        bad[0] = 10001;
        vm.expectRevert(VaultHook.InvalidConfidence.selector);
        hook.computeRanges(id_, bad);
    }

    function test_views_uninitializedPoolDoNotRevert() public view {
        PoolId fake = PoolId.wrap(bytes32(uint256(0xdead)));
        assertEq(hook.growthFactor(fake), 0, "growthFactor 0 for uninit");
        assertEq(hook.weightAt(fake, 100), 0, "weightAt 0 for uninit (no div-by-zero)");
    }

    // --- volume weighting --------------------------------------------------------

    function test_volumeWeighting_accumulatesByAmount() public {
        hook.setCaptureWindow(id_, -12000, 12000); // widen so the larger probe swap is captured
        hook.setConfig(id_, 30 days, 1, 1e18); // VOLUME, low MIN_DATA
        swap(key_, true, -3e18, ZERO_BYTES);
        int24 tick = _currentTick();
        // Volume weighting stores ~|amount0| * g; with g≈1 right after the config rebase, the stored
        // weight should be on the order of the swap size, far above the WAD a count would add.
        assertGt(hook.weightAt(id_, tick), 2e18, "volume weight scales with swap size");
    }
}
