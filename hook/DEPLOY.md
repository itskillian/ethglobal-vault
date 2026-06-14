# Deploying VaultHook

`VaultHook` is a Uniswap v4 hook. Its permissions (`afterInitialize` + `afterSwap`) are encoded in
the low bits of its address, so it must be deployed at a **mined CREATE2 address** — a plain
`forge create` would revert in the constructor. `script/DeployVaultHook.s.sol` handles the mining.

The hook is a **singleton**: deploy it **once per chain**; it then serves every pool that opts in.
Per-pool config is auto-seeded in `afterInitialize`, so **no post-deploy transaction is required**.

---

## 1. Prerequisites

```bash
foundryup                      # forge >= 1.5
forge install                  # ensure submodules are present
forge build --sizes           # must pass (EIP-170 gate)
forge test                     # sanity
```

## 2. One-time: create an encrypted keystore

Signing uses an encrypted keystore (no plaintext key on disk). Import your deployer key once:

```bash
cast wallet import deployer --interactive
# paste the private key, set a password. Prints the account address — note it.
```

This stores `~/.foundry/keystores/deployer`. You'll reference it with `--account deployer` and be
prompted for the password at deploy time. The printed address is your **deployer / owner** address.

**Fund that address with ETH** on each chain you deploy to (Sepolia faucet for testnet; real ETH for
mainnet — deployment is a normal contract creation plus the constructor's address validation).

## 3. Configure `.env`

```bash
cp .env.example .env
```

Fill in:
- `SEPOLIA_RPC_URL` / `MAINNET_RPC_URL` — your RPC endpoints.
- `ETHERSCAN_API_KEY` — Etherscan v2 multichain key (verifies both chains).

Owner defaults to the deployer (the `--sender` below). To use a different owner, set `INITIAL_OWNER`.

## 4. Dry run (simulation, no broadcast)

Replace `<DEPLOYER_ADDR>` with your keystore address from step 2.

```bash
forge script script/DeployVaultHook.s.sol:DeployVaultHook \
  --rpc-url sepolia \
  --account deployer --sender <DEPLOYER_ADDR> \
  -vvvv
```

Check the logged `Predicted hook`, `PoolManager`, and `Initial owner` look right. Nothing is sent.

> `--sender` is required so the script knows the owner/deployer address before mining (the owner is
> baked into the mined address). It must match the keystore's address.

## 5. Deploy + verify — Sepolia

```bash
forge script script/DeployVaultHook.s.sol:DeployVaultHook \
  --rpc-url sepolia \
  --account deployer --sender <DEPLOYER_ADDR> \
  --broadcast --verify -vvvv
```

The deployed address is printed (`Deployed hook:`) and saved under
`broadcast/DeployVaultHook.s.sol/11155111/run-latest.json`.

## 6. Deploy + verify — Mainnet

Same command with `--rpc-url mainnet` (and `--slow` for safer nonce handling). Double-check the
deployer is funded and the logged owner/PoolManager are correct before confirming.

```bash
forge script script/DeployVaultHook.s.sol:DeployVaultHook \
  --rpc-url mainnet \
  --account deployer --sender <DEPLOYER_ADDR> \
  --broadcast --verify --slow -vvvv
```

---

## Baked-in addresses

| Chain | chainid | PoolManager |
|---|---|---|
| Ethereum mainnet | 1 | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Ethereum Sepolia | 11155111 | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |

Source: <https://developers.uniswap.org/contracts/v4/deployments>. For any other chain, set
`POOL_MANAGER` in `.env`.

## After deploying

- Record the hook address; the vault and any pool that uses this hook reference it in their `PoolKey`.
- A pool starts using the hook by being **initialized with this hook address** in its `PoolKey` — at
  that point `afterInitialize` seeds defaults (30-day half-life, ±5% capture window, count weighting).
- Owner-only tuning (`setConfig`, `setCaptureWindow`, `setRebaseInterval`, `setPruneFraction`,
  `rebase`) is optional and **per-pool**, done later from the owner account.

## Troubleshooting

- **`HookMiner: could not find salt`** — extremely unlikely (2 flags → ~16k tries vs. 160k cap).
  Re-run; if it persists, the flags constant has drifted from `getHookPermissions()`.
- **Constructor revert / `HookAddressNotValid`** — the deployed bits don't match permissions; means
  the salt/flags or constructor args changed between mining and deploy. The script asserts against
  this, so you'd see the mismatch in simulation first.
- **`no PoolManager mapped for this chain`** — you're on a chain other than 1/11155111; set
  `POOL_MANAGER` in `.env`.
- **Verification failed** — re-run verification standalone with
  `forge verify-contract <addr> src/vaultHook.sol:VaultHook --chain <id> --watch --constructor-args $(cast abi-encode "constructor(address,address)" <poolManager> <owner>)`.
