---
type: index
---

# Primitives catalog

The deterministic building blocks: one page per user-facing script, grouped by area. Each page has the
primitive's description, modes, safety flags, and inputs. Agents can consume the full structured index
at [`catalog.json`](catalog.json). These pages are generated from the scripts and cannot drift; run
`npm run docs:catalog` to regenerate.

## allowlist

- [DeployAdvancedPoolHooks](allowlist/DeployAdvancedPoolHooks.md) - Optional script to deploy AdvancedPoolHooks for enhanced token pool security _(write)_
- [GetAdvancedPoolHooks](allowlist/GetAdvancedPoolHooks.md) - Reads and displays the AdvancedPoolHooks contract address currently attached to a token pool. _(read-only)_
- [GetAllowList](allowlist/GetAllowList.md) - Script to fetch and print the allowlist from an AdvancedPoolHooks contract Usage: POOL_HOOKS=0x... forge script script/configure/allowlist/GetAllowList.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME / _(read-only)_
- [IsAllowListed](allowlist/IsAllowListed.md) - Script to check if an address is allowlisted in an AdvancedPoolHooks contract Usage: POOL_HOOKS=0x... _(read-only)_
- [UpdateAdvancedPoolHooks](allowlist/UpdateAdvancedPoolHooks.md) - Script to update the AdvancedPoolHooks address for a deployed TokenPool _(write)_
- [UpdateAllowList](allowlist/UpdateAllowList.md) - Script to update the allowlist for a TokenPool or AdvancedPoolHooks _(write)_

## authorized-callers

- [GetAuthorizedCallers](authorized-callers/GetAuthorizedCallers.md) - Script to fetch and print the authorized callers from an AdvancedPoolHooks or ERC20LockBox contract Usage: POOL_HOOKS=0x... forge script script/configure/authorized-callers/GetAuthorizedCallers.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME LOCK_BOX=0x... forge script script/configure/authorized-callers/GetAuthorizedCallers.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME Environment variables: POOL_HOOKS -- address of an AdvancedPoolHooks contract (one of POOL_HOOKS or LOCK_BOX required) LOCK_BOX -- address of an ERC20LockBox contract (one of POOL_HOOKS or LOCK_BOX required) / _(read-only)_
- [UpdateAuthorizedCallers](authorized-callers/UpdateAuthorizedCallers.md) - Script to add or remove authorized callers on an AdvancedPoolHooks or ERC20LockBox contract _(write)_

## ccv

- [GetCCVConfig](ccv/GetCCVConfig.md) - Reads and displays the CCV (Cross-Chain Verifier) configuration for a token pool: every configured remote lane's four verifier arrays plus the pool-global additional-CCV threshold. _(read-only)_
- [UpdateCCVConfig](ccv/UpdateCCVConfig.md) - Applies CCV (Cross-Chain Verifier) configuration to a token pool's AdvancedPoolHooks: the four per-lane verifier arrays and/or the pool-global additional-CCV threshold. _(write)_

## config-plane

- [AdoptToken](config-plane/AdoptToken.md) - Adopts an externally deployed token (and optionally its pool) into the address registry, so contracts this repo did NOT deploy resolve exactly like the ones it did (the zero-export `active.<role>` ladder). _(write)_
- [RolesCheck](config-plane/RolesCheck.md) - **`make roles-check CHAIN=<name>` - READ-ONLY reconcile of the declared `roles{}` against the live chain.** It never writes a file and never broadcasts; the only outputs are the aligned [PASS]/[FAIL]/[WARN]/[SKIP] lines from `RolesAuditor` and the exit status. _(write)_
- [SnapshotChain](config-plane/SnapshotChain.md) - **`make snapshot-chain CHAIN=<name>` - backfill the DECLARED authority state FROM chain.** Reads the live role surface (owner/defaultAdmin/getCCIPAdmin/hasRole/TAR getTokenConfig/ dual-generation pool admins/getAllAuthorizedCallers/getAllowList/...) through `RolesSnapshot` and writes the `roles{}` subtree of `project/<selectorName>.json` (preserve-and-replace, the same single-subtree pattern as the `ccip{}` sync). _(write)_
- [SyncCcipConfig](config-plane/SyncCcipConfig.md) - The config-sync entrypoints: everything that generates, refreshes, or drift-checks a `config/chains/<name>.json` file from the live CCIP REST API v2. _(write)_
- [VerifyChain](config-plane/VerifyChain.md) - The layered chain-config doctor. _(write)_

## configure

- [GetLockBox](configure/GetLockBox.md) - Reads and displays the ERC20LockBox contract address currently attached to a LockReleaseTokenPool. _(read-only)_

## deploy

- [DeployBurnMintTokenPool](deploy/DeployBurnMintTokenPool.md) - Deploys a BurnMint token pool for a token and records it in the address registry. _(write)_
- [DeployERC20LockBox](deploy/DeployERC20LockBox.md) - Script to deploy an ERC20LockBox for use with a LockReleaseTokenPool _(write)_
- [DeployLockReleaseTokenPool](deploy/DeployLockReleaseTokenPool.md) - Deploys a LockRelease token pool (paired with an ERC20 LockBox) and records it in the registry. _(write)_
- [DeployToken](deploy/DeployToken.md) - Deploys a cross-chain ERC20 token (CrossChainToken) and records it in the address registry. _(write)_

## diagnostics

- [PreflightTransfer](diagnostics/PreflightTransfer.md) - Preflights a token transfer before any real send by simulating both pool legs against live chain state: the source pool's `lockOrBurn`, then the destination pool's `releaseOrMint` fed the exact `destPoolData` the source leg produced. _(read-only)_

## dynamic-config

- [GetDynamicConfig](dynamic-config/GetDynamicConfig.md) - Reads and displays the dynamic configuration of a TokenPool. _(read-only)_
- [SetDynamicConfig](dynamic-config/SetDynamicConfig.md) - Updates the dynamic configuration of a TokenPool (router, rateLimitAdmin, feeAdmin). _(write)_

## fee-config

- [GetTokenTransferFeeConfig](fee-config/GetTokenTransferFeeConfig.md) - Reads and displays the token transfer fee configuration for a token pool on a given destination lane. _(read-only)_
- [UpdateTokenTransferFeeConfig](fee-config/UpdateTokenTransferFeeConfig.md) - Applies token transfer fee configuration updates to a token pool on a given destination lane. _(write)_

## finality-config

- [GetFinalityConfig](finality-config/GetFinalityConfig.md) - Reads and displays the allowed finality configuration on a TokenPool. _(read-only)_
- [SetFinalityConfig](finality-config/SetFinalityConfig.md) - Sets the allowed finality configuration on a TokenPool, and optionally updates rate limits for the fast finality bucket on a specific remote chain lane. _(write)_

## governance

- [DeploySafe](governance/DeploySafe.md) - Deploys a Safe from the canonical Safe v1.4.1 stack: `SafeProxyFactory.createProxyWithNonce(SafeL2, setup(...), saltNonce)`. _(write)_
- [ExecuteBatch](governance/ExecuteBatch.md) - Composes several independently emitted Safe batches into ONE Safe meta-transaction. _(read-only)_
- [VerifyRoles](governance/VerifyRoles.md) - **The privileged-role audit reader (read-only)** - prints the CURRENT holder of every authority slot for a token / pool / lockbox / hooks set. _(read-only)_

## liquidity

- [GetRebalancer](liquidity/GetRebalancer.md) - Reads and displays the rebalancer of a v1.x LockRelease token pool (`getRebalancer`). _(read-only)_
- [ProvideLiquidity](liquidity/ProvideLiquidity.md) - Provides lock/release liquidity to a v1.x LockRelease token pool (`provideLiquidity`). _(write)_
- [SetRebalancer](liquidity/SetRebalancer.md) - Sets the rebalancer on a v1.x LockRelease token pool (`setRebalancer`, onlyOwner). _(write)_
- [WithdrawLiquidity](liquidity/WithdrawLiquidity.md) - Withdraws lock/release liquidity from a v1.x LockRelease token pool (`withdrawLiquidity`). _(write, destructive)_

## operations

- [DepositToLockBox](operations/DepositToLockBox.md) - Script to deposit tokens into an ERC20LockBox _(write)_
- [GetFeeTokenBalances](operations/GetFeeTokenBalances.md) - Displays the fee token balances currently held by a token pool. _(read-only)_
- [MintTokens](operations/MintTokens.md) - Mints tokens to a receiver (requires the signer to hold the token's minter role). _(write)_
- [WithdrawFeeTokens](operations/WithdrawFeeTokens.md) - Withdraws accrued fee token balances from a token pool to a specified recipient. _(write, destructive)_
- [WithdrawFromLockBox](operations/WithdrawFromLockBox.md) - Script to withdraw tokens from an ERC20LockBox _(write, destructive)_

## ownership

- [AcceptOwnership](ownership/AcceptOwnership.md) - Completes a two-step ownership transfer initiated by TransferOwnership for any Ownable contract (a token pool, pool hooks, or a lockbox). _(write)_
- [TransferOwnership](ownership/TransferOwnership.md) - Initiates a two-step ownership transfer for any Ownable contract (a token pool, pool hooks, or a lockbox). _(write)_

## rate-limiter

- [GetCurrentRateLimits](rate-limiter/GetCurrentRateLimits.md) - Reads and displays the current rate limiter state for a TokenPool, compatible with v1 and v2 pools. _(read-only)_
- [UpdateRateLimiters](rate-limiter/UpdateRateLimiters.md) - Updates rate limiter configuration on a TokenPool, compatible with both v1 and v2 pools. _(write)_

## remote-chains

- [RemoveChain](remote-chains/RemoveChain.md) - Fully unsupports a remote chain on the source TokenPool: removes the chain selector and deletes its remote-chain config (pools, remote token, rate limits). _(write, destructive)_

## remote-pools

- [AddRemotePool](remote-pools/AddRemotePool.md) - Adds a remote pool address to a TokenPool for a given remote chain. _(write)_
- [GetRemotePools](remote-pools/GetRemotePools.md) - Reads and displays the remote pool addresses configured on a TokenPool for a given remote chain. _(read-only)_
- [RemoveRemotePool](remote-pools/RemoveRemotePool.md) - Removes a remote pool address from a TokenPool for a given remote chain. _(write, destructive)_

## token-admin-registry

- [AcceptAdminRole](token-admin-registry/AcceptAdminRole.md) - Accepts the pending administrator role for a token in the TokenAdminRegistry (step 2 of the two-step claim; the signer must be the pending administrator set by ClaimAdmin). _(write)_
- [ApplyChainUpdates](token-admin-registry/ApplyChainUpdates.md) - Configures cross-chain lanes on the source TokenPool by calling applyChainUpdates. _(write)_
- [ClaimAdmin](token-admin-registry/ClaimAdmin.md) - Registers the token administrator in the TokenAdminRegistry, auto-detecting the claim path (getCCIPAdmin, then owner, then AccessControl DEFAULT_ADMIN_ROLE) in that precedence. _(write)_
- [ClaimAndAcceptAdmin](token-admin-registry/ClaimAndAcceptAdmin.md) - Claims AND accepts the CCIP token admin as ONE atomic registration pair - the claim sets the executing account as the registry's pending administrator, so the accept in the same batch succeeds. _(write)_
- [GetSupportedChains](token-admin-registry/GetSupportedChains.md) - Reads and displays all remote chains supported by a TokenPool. _(read-only)_
- [GetTokenConfig](token-admin-registry/GetTokenConfig.md) - Reads and displays TokenAdminRegistry.getTokenConfig(tokenAddress) for a token. _(read-only)_
- [GetTypeAndVersion](token-admin-registry/GetTypeAndVersion.md) - Reads and displays the typeAndVersion string from any contract implementing ITypeAndVersion. _(read-only)_
- [SetPool](token-admin-registry/SetPool.md) - Points the TokenAdminRegistry at the token's pool, activating the token for cross-chain transfers. _(write)_
- [TransferTokenAdminRole](token-admin-registry/TransferTokenAdminRole.md) - Initiates a transfer of the token admin role to a new address. _(write)_

## token-roles

- [GrantTokenRole](token-roles/GrantTokenRole.md) - Grants a token role (minter / burner / burnMintAdmin) to a holder, template-dispatched: AccessControl templates (`crosschain`, `burnmint`) get `grantRole` with the token's resolved role id; the Ownable `factory` template gets `grantMintRole`/`grantBurnRole`. _(write)_
- [RevokeTokenRole](token-roles/RevokeTokenRole.md) - Revokes a token role (minter / burner / burnMintAdmin) from a holder, template-dispatched exactly like `GrantTokenRole`: `revokeRole` on AccessControl templates, `revokeMintRole`/`revokeBurnRole` on the Ownable `factory` template. _(write, destructive)_
- [SetCCIPAdmin](token-roles/SetCCIPAdmin.md) - Sets the token's CCIP admin (`setCCIPAdmin`, one-step, no accept). _(write)_
- [TransferTokenAdmin](token-roles/TransferTokenAdmin.md) - Moves the token's TOP-LEVEL admin (its template's own mechanism). _(write)_
