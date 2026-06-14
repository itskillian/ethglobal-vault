// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {USDaVault} from "../src/USDaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/**
 * @title Deploy USDaVault to Ethereum mainnet
 * @notice Canonical mainnet addresses below are VERIFIED against Uniswap's developer docs
 *         (developers.uniswap.org/contracts/v4/deployments, chain id 1) as of 2026-06.
 *
 *         CRITICAL — UniversalRouter version: the vault encodes the 6-field `ExactInputSingleParams`
 *         (with `minHopPriceX36`) from the installed v4-periphery. That matches the NEWER
 *         UniversalRouter (v2.1.1, 0x4c82...), NOT the original v4-launch router (0x66a9...).
 *         Deploy against the router whose V4Router ABI matches the encoding, or swaps will revert.
 *
 *         TODO(dev) before running: set the vault pool key (USDC/USDT + your VaultHook), the primary
 *         swap pool key (a deep USDC/USDT pool, must differ from the vault pool), and the backup
 *         router adapter (or address(0) to disable). Then, post-deploy: approveAll(), seed a deposit,
 *         and initialize().
 */
contract DeployUSDaVault is Script {
    // ── verified mainnet (chain id 1) ──
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;
    address constant UNIVERSAL_ROUTER = 0x4C82D1fBFe28C977cBB58D8C7FF8FCF9F70a2cCA; // UR 2.1.1 (6-field swap struct)
    // original v4-launch UR (5-field struct, do NOT use with this vault): 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af

    function run() external returns (USDaVault vault) {
        // ── TODO(dev): vault pool — USDC/USDT with YOUR VaultHook. Sort currencies by address. ──
        address hookAddr = vm.envAddress("VAULT_HOOK"); // your deployed VaultHook
        uint24 vaultFee = uint24(vm.envOr("VAULT_FEE", uint256(100)));
        int24 vaultSpacing = int24(uint24(vm.envOr("VAULT_TICK_SPACING", uint256(1))));
        PoolKey memory vaultPoolKey = _sortedKey(USDC, USDT, vaultFee, vaultSpacing, hookAddr);

        // ── TODO(dev): primary swap pool — deepest USDC/USDT pool, MUST differ from the vault pool. ──
        uint24 swapFee = uint24(vm.envOr("SWAP_FEE", uint256(500)));
        int24 swapSpacing = int24(uint24(vm.envOr("SWAP_TICK_SPACING", uint256(10))));
        address swapHook = vm.envOr("SWAP_HOOK", address(0));
        PoolKey memory swapPoolKey = _sortedKey(USDC, USDT, swapFee, swapSpacing, swapHook);

        address backupRouter = vm.envOr("BACKUP_ROUTER", address(0));
        address owner = vm.envAddress("VAULT_OWNER");

        vm.startBroadcast();
        vault = new USDaVault(
            IERC20(USDC),
            IERC20(USDT),
            IPoolManager(POOL_MANAGER),
            IPositionManager(POSITION_MANAGER),
            IUniversalRouter(UNIVERSAL_ROUTER),
            vaultPoolKey,
            swapPoolKey,
            backupRouter,
            owner
        );
        vm.stopBroadcast();

        console2.log("USDaVault:", address(vault));
        console2.log("Next steps (as owner): approveAll(); deposit(seed); initialize();");
    }

    function _sortedKey(address a, address b, uint24 fee, int24 spacing, address hookAddr)
        internal
        pure
        returns (PoolKey memory)
    {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(hookAddr)
        });
    }
}
