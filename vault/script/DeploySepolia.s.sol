// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {USDaVault} from "../src/USDaVault.sol";
import {MockStable} from "./mocks/MockStable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/**
 * @title Deploy USDaVault to Ethereum Sepolia (PRE-INIT smoke deploy)
 * @notice The mainnet {DeployUSDaVault} cannot run on Sepolia: real USDC/USDT do not exist at the
 *         canonical addresses, and — critically — Sepolia's canonical UniversalRouter
 *         (0x3A9D48AB...) is the OLD 5-field V4Router. The vault encodes the 6-field
 *         `ExactInputSingleParams` (with `minHopPriceX36`), so any swap through that UR mis-decodes
 *         and reverts. Therefore the full lifecycle (initialize -> 4 positions -> rebalance, all of
 *         which swap) is NOT reachable on Sepolia via the canonical UR.
 *
 *         This script deploys the SWAP-FREE surface only: mock stables -> initialize the vault pool
 *         at peg (which fires VaultHook.afterInitialize) -> deploy the vault -> one seed deposit.
 *         Pre-initialize, the vault holds value purely as idleUSDC and touches no positions and no
 *         swaps (`_bestEffortRebalance` early-returns while `!initialized`), so deposit / NAV /
 *         withdraw-fast-path are exercisable against real Sepolia v4 state. `backupRouter` is left
 *         unset (0) because no swap path is taken.
 *
 *         Run (from vault/, with vault/.env carrying SEPOLIA_RPC_URL + ETHERSCAN_API_KEY):
 *           VAULT_HOOK=<deployed hook> forge script script/DeploySepolia.s.sol:DeploySepolia \
 *             --rpc-url sepolia --account deployer-global --sender <ADDR> --broadcast --verify -vvvv
 */
contract DeploySepolia is Script {
    // ── canonical Sepolia (chain id 11155111) v4 addresses (developers.uniswap.org/contracts/v4/deployments) ──
    address internal constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address internal constant POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    // OLD 5-field UR — stored for completeness but never reached pre-init (its swap struct mismatches).
    address internal constant UNIVERSAL_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;

    // sqrtPriceX96 for price 1.0 — both stables are 6-dp, so 1:1 nominal == price 1.0.
    uint160 internal constant SQRTP_ONE = 79228162514264337593543950336;

    function run() external returns (USDaVault vault, address usdc, address usdt) {
        require(block.chainid == 11155111, "DeploySepolia: not Sepolia");
        address hookAddr = vm.envAddress("VAULT_HOOK"); // the VaultHook you deployed
        address owner = vm.envOr("VAULT_OWNER", msg.sender);
        uint256 seed = vm.envOr("SEED_USDC", uint256(1_000e6)); // 1,000 mUSDC (6dp) seed deposit
        address depositor = msg.sender; // shares go to the broadcaster

        vm.startBroadcast();

        // 1. Mock 6-dp stables (real USDC/USDT are absent on Sepolia).
        MockStable mUSDC = new MockStable("Mock USD Coin", "mUSDC", 6);
        MockStable mUSDT = new MockStable("Mock Tether USD", "mUSDT", 6);

        // 2. Pool keys. Vault pool carries YOUR hook (fee 100 / spacing 1). The swap pool is a DISTINCT
        //    pool id (fee 500 / spacing 10, no hook) only to satisfy the constructor's "swap != vault"
        //    invariant — it is never initialized or swapped pre-init.
        PoolKey memory vaultKey = _sortedKey(address(mUSDC), address(mUSDT), 100, 1, hookAddr);
        PoolKey memory swapKey = _sortedKey(address(mUSDC), address(mUSDT), 500, 10, address(0));

        // 3. Initialize the vault pool at peg so the deposit peg-guard + NAV read a valid spot price.
        //    This is the call that fires VaultHook.afterInitialize (seeds per-pool hook config).
        IPoolManager(POOL_MANAGER).initialize(vaultKey, SQRTP_ONE);

        // 4. Deploy the vault. backupRouter = 0: no swap venue, and none is needed pre-init.
        vault = new USDaVault(
            IERC20(address(mUSDC)),
            IERC20(address(mUSDT)),
            IPoolManager(POOL_MANAGER),
            IPositionManager(POSITION_MANAGER),
            IUniversalRouter(UNIVERSAL_ROUTER),
            vaultKey,
            swapKey,
            address(0),
            owner
        );

        // 5. Seed deposit — proves the pre-init deposit/share-mint path against real Sepolia v4 state.
        mUSDC.mint(depositor, seed);
        IERC20(address(mUSDC)).approve(address(vault), seed);
        uint256 shares = vault.deposit(seed, 0, block.timestamp + 1 days);
        // A USDT stash for manual withdraw-fast-path / dual-token poking later.
        mUSDT.mint(depositor, seed);

        vm.stopBroadcast();

        usdc = address(mUSDC);
        usdt = address(mUSDT);

        console2.log("Chain id:        ", block.chainid);
        console2.log("Hook (vault pool):", hookAddr);
        console2.log("mUSDC:           ", usdc);
        console2.log("mUSDT:           ", usdt);
        console2.log("USDaVault:       ", address(vault));
        console2.log("Vault owner:     ", owner);
        console2.log("Seed deposited:  ", seed);
        console2.log("Shares minted:   ", shares);
        console2.log("NAV (totalAssets):", vault.totalAssets());
        console2.log("NOTE: vault NOT initialize()'d - swaps unreachable on Sepolia (old UR). Pre-init surface only.");
    }

    /// @dev Build a PoolKey with currencies sorted ascending (v4 invariant: currency0 < currency1).
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
