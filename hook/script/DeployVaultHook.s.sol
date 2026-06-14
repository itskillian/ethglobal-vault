// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {VaultHook} from "../src/vaultHook.sol";

/**
 * @title DeployVaultHook
 * @notice Deploys the {VaultHook} singleton to a chain via CREATE2 with a mined salt.
 *
 * @dev Why mining is required: a v4 hook's permissions are encoded in the low 14 bits of its
 *      address, and {BaseHook}'s constructor reverts unless those bits match getHookPermissions().
 *      So we mine a salt with {HookMiner} (off-chain, gas-free) such that the CREATE2 address has
 *      exactly the AFTER_INITIALIZE | AFTER_SWAP bits set, then deploy through the canonical
 *      deterministic CREATE2 deployer (Foundry routes `new X{salt:...}` through it on broadcast).
 *
 *      The hook is a SINGLETON: deploy once per chain. Per-pool config is auto-seeded in
 *      afterInitialize, so there is no required post-deploy transaction.
 *
 *      Run with an encrypted keystore (see DEPLOY.md):
 *        forge script script/DeployVaultHook.s.sol:DeployVaultHook \
 *          --rpc-url sepolia --account deployer --sender <DEPLOYER_ADDR> --broadcast --verify -vvvv
 */
contract DeployVaultHook is Script {
    /// @dev Canonical CREATE2 deployer; Foundry routes salted `new` through this on broadcast.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Must mirror VaultHook.getHookPermissions(): afterInitialize + afterSwap only.
    uint160 internal constant FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);

    // --- Canonical v4 PoolManager addresses (source: developers.uniswap.org/contracts/v4/deployments) ---
    address internal constant POOL_MANAGER_MAINNET = 0x000000000004444c5dc75cB358380D2e3dE08A90; // chainid 1
    address internal constant POOL_MANAGER_SEPOLIA = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543; // chainid 11155111

    function run() external returns (VaultHook hook) {
        IPoolManager poolManager = IPoolManager(_poolManager());
        address owner = _owner();
        require(owner != address(0), "DeployVaultHook: owner is zero (set INITIAL_OWNER or pass --sender)");

        // 1. Mine the salt. The constructor args are part of the init code, so the mined address
        //    is bound to (poolManager, owner) — both must be final before mining.
        bytes memory args = abi.encode(poolManager, owner);
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(VaultHook).creationCode, args);

        console2.log("Chain id:      ", block.chainid);
        console2.log("PoolManager:   ", address(poolManager));
        console2.log("Initial owner: ", owner);
        console2.log("Predicted hook:", predicted);
        console2.log("Salt:");
        console2.logBytes32(salt);

        // 2. Deploy via CREATE2 and assert the address landed where we mined it.
        vm.startBroadcast();
        hook = new VaultHook{salt: salt}(poolManager, owner);
        vm.stopBroadcast();

        require(address(hook) == predicted, "DeployVaultHook: deployed address != mined address");
        console2.log("Deployed hook: ", address(hook));
    }

    /// @dev PoolManager for the active chain; override with the POOL_MANAGER env var for any other chain.
    function _poolManager() internal view returns (address pm) {
        pm = vm.envOr("POOL_MANAGER", address(0));
        if (pm != address(0)) return pm;
        if (block.chainid == 1) return POOL_MANAGER_MAINNET;
        if (block.chainid == 11155111) return POOL_MANAGER_SEPOLIA;
        revert("DeployVaultHook: no PoolManager mapped for this chain; set POOL_MANAGER");
    }

    /// @dev Hook owner. Defaults to the broadcasting account (so pass --sender), or set INITIAL_OWNER.
    function _owner() internal view returns (address) {
        return vm.envOr("INITIAL_OWNER", msg.sender);
    }
}
