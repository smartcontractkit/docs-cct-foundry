# Makefile — golden path over the chain-config tooling (script/config/*).
#
# Every target is a thin wrapper: the raw `forge script` / `bash` commands it runs are documented
# in README.md ("Chain config tooling") and remain the escape hatch. `FOUNDRY_PROFILE=sync` is set
# inside each recipe (the sync profile enables `ffi` for the curl+jq API fetch), never exported.
#
# NOTE on exit codes: the canonical drift-check exit contract (0 clean / 1 drift / 2 API
# unreachable) belongs to `bash script/config/sync-check.sh` — GNU make remaps ANY failing recipe
# to its own exit code 2, so `make sync-check` is pass/fail only. CI calls the script directly.

CONFIG_DIR := config/chains
# Real chain configs only: exclude the gitignored `zz-scratch-*` files the test suites write into
# config/chains/ (they carry fake selectors and would break the sync/discover tooling that scans the
# directory). This matches the `.gitignore` pattern; a leftover scratch file from a test run is ignored.
KNOWN_CHAINS := $(filter-out zz-scratch-%,$(basename $(notdir $(wildcard $(CONFIG_DIR)/*.json))))
SYNC_SCRIPT := script/config/SyncCcipConfig.s.sol

# Optional token group. GROUP=<name> selects one of N token groups
# (project/<group>/<selectorName>.json); unset is the flat default (project/<selectorName>.json). It
# threads to the scripts as PROJECT_GROUP; GROUP_DIR locates the same file for the jq repair steps here.
# Honored by the project targets (add-lane, remove-lane, adopt-token, snapshot-chain, doctor,
# roles-check) and the deploy targets (deploy-token/pool/lockbox/lockrelease-pool, deploy-new-chain); the
# chain-facts targets (add-chain, sync*) ignore it (config/chains is group-independent).
GROUP_DIR := $(if $(GROUP),$(GROUP)/,)

.DEFAULT_GOAL := help
.PHONY: adopt-token help tools discover add-chain add-lane remove-lane sync sync-preview sync-all sync-check doctor fmt-config clean-scratch snapshot-chain roles-check roles-check-all deploy-token deploy-pool deploy-lockbox deploy-lockrelease-pool deploy-new-chain preflight verify verify-args

# Deploy-time parameters are read by the forge scripts from the environment (vm.env*). Forward a value
# passed on the make command line (make deploy-token TOKEN_NAME=...) to the forge subprocess; a value
# already exported in the shell is inherited either way. The deploy targets resolve only --rpc-url and
# --account for you; these carry the token/pool parameters through unchanged.
#
# Export ONLY vars that actually have a value. A blanket `export FOO` for an unset FOO exports it as an
# EMPTY STRING on GNU Make, which the scripts would then read as "present" and use instead of their
# vm.envOr(KEY, default) fallback - reverting on an empty address/uint or deploying an empty name. The
# conditional export keeps unset vars unset so the script defaults (JSON config / registry / address(0))
# still apply.
DEPLOY_VARS := TOKEN_NAME TOKEN_SYMBOL TOKEN_DECIMALS TOKEN_MAX_SUPPLY TOKEN_PRE_MINT \
	TOKEN_PRE_MINT_RECIPIENT CCIP_ADMIN_ADDRESS ROLES_RECIPIENT TOKEN TOKEN_POOL LOCK_BOX DECIMALS \
	POOL_HOOKS AUTHORIZED_CALLERS FORCE_REDEPLOY
$(foreach v,$(DEPLOY_VARS),$(if $(strip $($(v))),$(eval export $(v))))

# Preflight per-call inputs, forwarded to the forge script the same conditional way as DEPLOY_VARS
# (SOURCE_CHAIN / DEST_CHAIN and the two resolved RPC URLs are passed inline by the preflight recipe).
PREFLIGHT_VARS := AMOUNT RECEIVER ORIGINAL_SENDER SOURCE_POOL DEST_POOL REQUESTED_FINALITY TOKEN_ARGS
$(foreach v,$(PREFLIGHT_VARS),$(if $(strip $($(v))),$(eval export $(v))))

# Recipe-time guard: the CHAIN's config file must exist (helpful list + add-chain hint on a miss).
define require-chain-config
	@test -f "$(CONFIG_DIR)/$(CHAIN).json" || { \
		echo "unknown chain '$(CHAIN)' - known chains: $(KNOWN_CHAINS)"; \
		echo "New chain? make add-chain CHAIN=<selectorName> SELECTOR=<selector> (both from the 'make discover' API NAME + SELECTOR columns)"; \
		exit 1; }
endef

# Canonical JSON format for config/chains/*.json: `jq --indent 2 -S .` (2-space indent, sorted keys,
# trailing newline — jq always emits one). The committed files use this exact style, and every target
# that writes a config re-canonicalizes it as its last step, so a no-drift `make sync` produces ZERO
# git diff (Foundry's `vm.writeJson` has its own style; raw `forge script` runs bypass the reformat —
# `make fmt-config` restores canon).
define canon-chain-config
@tmp="$$(mktemp)" && jq --indent 2 -S . "$(CONFIG_DIR)/$(CHAIN).json" > "$$tmp" && mv "$$tmp" "$(CONFIG_DIR)/$(CHAIN).json"
endef

# Canonical JSON for project/*.json: sorted keys, 2-space indent, and NO trailing newline (forge's
# `vm.writeJson` — the ONLY writer of project files — omits the trailing newline, and project state is
# never round-tripped through jq in the normal flow, so its canonical form is the writer's exact output;
# see docs/deployed-addresses.md). This REPAIR target strips jq's trailing newline to match. Repair
# tool only — the writers already emit this form on the direct forge path.
define canon-project
@test -f "project/$(GROUP_DIR)$(CHAIN).json" && { tmp="$$(mktemp)" && jq --indent 2 -S . "project/$(GROUP_DIR)$(CHAIN).json" > "$$tmp" && printf '%s' "$$(cat "$$tmp")" > "project/$(GROUP_DIR)$(CHAIN).json" && rm -f "$$tmp"; } || true
endef

help: ## List the available targets
	@echo "Chain-config tooling golden path (raw commands: README.md > Chain config tooling):"
	@awk 'BEGIN {FS = ":.*## "} /^[a-z][a-z-]*:.*## / {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

tools: ## Check the required tools are installed (forge, curl, jq)
	@command -v forge > /dev/null || { echo "missing: forge - install Foundry: https://book.getfoundry.sh/getting-started/installation"; exit 2; }
	@command -v curl > /dev/null || { echo "missing: curl - install it (usually preinstalled; else brew install curl / apt install curl)"; exit 2; }
	@command -v jq > /dev/null || { echo "missing: jq - install it (e.g. brew install jq / apt install jq)"; exit 2; }
	@echo "tools: forge, curl and jq are all present"

discover: tools ## List the CCIP API testnet catalog vs local configs (FILTER=<term> narrows)
	@FILTER="$(FILTER)" bash script/config/sync-discover.sh

add-chain: tools ## Generate config/chains/<CHAIN>.json from the live API (CHAIN= and SELECTOR= required)
	$(if $(CHAIN),,$(error CHAIN is required: make add-chain CHAIN=<selectorName> SELECTOR=<selector> - both from the make discover API NAME + SELECTOR columns))
	$(if $(SELECTOR),,$(error SELECTOR is required - find it with: make discover FILTER=<term>))
	FOUNDRY_PROFILE=sync forge script $(SYNC_SCRIPT) --sig "init(string,uint256)" "$(CHAIN)" "$(SELECTOR)"
	$(canon-chain-config)

add-lane: tools ## Append a lanes{} policy entry LOCAL -> REMOTE (LOCAL= REMOTE= CAPACITY= RATE= required; INBOUND_CAPACITY= + INBOUND_RATE= add the inbound block; BOTH=1 adds the reciprocal; GROUP= scopes to a token group)
	$(if $(LOCAL),,$(error LOCAL is required: make add-lane LOCAL=<name> REMOTE=<name> CAPACITY=<wei> RATE=<wei> [INBOUND_CAPACITY=<wei> INBOUND_RATE=<wei>] [BOTH=1]))
	$(if $(REMOTE),,$(error REMOTE is required: make add-lane LOCAL=<name> REMOTE=<name> CAPACITY=<wei> RATE=<wei> [INBOUND_CAPACITY=<wei> INBOUND_RATE=<wei>] [BOTH=1]))
	$(if $(CAPACITY),,$(error CAPACITY is required - the outbound rate-limit bucket capacity in wei))
	$(if $(RATE),,$(error RATE is required - the outbound rate-limit refill rate in wei per second))
ifdef INBOUND_CAPACITY
	$(if $(INBOUND_RATE),,$(error INBOUND_RATE is required when INBOUND_CAPACITY is set - a declared inbound block carries both fields))
endif
ifdef INBOUND_RATE
	$(if $(INBOUND_CAPACITY),,$(error INBOUND_CAPACITY is required when INBOUND_RATE is set - a declared inbound block carries both fields))
endif
	@for c in "$(LOCAL)" "$(REMOTE)"; do \
		test -f "$(CONFIG_DIR)/$$c.json" || { \
			echo "unknown chain '$$c' - known chains: $(KNOWN_CHAINS)"; \
			echo "New chain? make add-chain CHAIN=<selectorName> SELECTOR=<selector> (both from the 'make discover' API NAME + SELECTOR columns)"; \
			exit 1; }; \
	done
ifdef INBOUND_CAPACITY
	FOUNDRY_PROFILE=sync PROJECT_GROUP="$(GROUP)" forge script $(SYNC_SCRIPT) --sig "addLane(string,string,uint256,uint256,uint256,uint256)" "$(LOCAL)" "$(REMOTE)" "$(CAPACITY)" "$(RATE)" "$(INBOUND_CAPACITY)" "$(INBOUND_RATE)"
else
	FOUNDRY_PROFILE=sync PROJECT_GROUP="$(GROUP)" forge script $(SYNC_SCRIPT) --sig "addLane(string,string,uint256,uint256)" "$(LOCAL)" "$(REMOTE)" "$(CAPACITY)" "$(RATE)"
endif
ifdef BOTH
ifdef INBOUND_CAPACITY
	FOUNDRY_PROFILE=sync PROJECT_GROUP="$(GROUP)" forge script $(SYNC_SCRIPT) --sig "addLane(string,string,uint256,uint256,uint256,uint256)" "$(REMOTE)" "$(LOCAL)" "$(CAPACITY)" "$(RATE)" "$(INBOUND_CAPACITY)" "$(INBOUND_RATE)"
else
	FOUNDRY_PROFILE=sync PROJECT_GROUP="$(GROUP)" forge script $(SYNC_SCRIPT) --sig "addLane(string,string,uint256,uint256)" "$(REMOTE)" "$(LOCAL)" "$(CAPACITY)" "$(RATE)"
endif
endif
	@for c in "$(LOCAL)" "$(REMOTE)"; do \
		tmp="$$(mktemp)" && jq --indent 2 -S . "$(CONFIG_DIR)/$$c.json" > "$$tmp" && mv "$$tmp" "$(CONFIG_DIR)/$$c.json"; \
	done
	@echo "review the lane policy diff (lanes{} = owner policy), then: make doctor CHAIN=$(LOCAL)$(if $(GROUP), GROUP=$(GROUP),)"

remove-lane: tools ## Remove a lanes{} policy entry LOCAL -> REMOTE from the declaration (LOCAL= REMOTE= required; BOTH=1 removes the reciprocal; GROUP= scopes to a token group; on-chain removal via RemoveChain, or RemoveRemotePool for a single pool, is a separate step)
	$(if $(LOCAL),,$(error LOCAL is required: make remove-lane LOCAL=<name> REMOTE=<name> [BOTH=1]))
	$(if $(REMOTE),,$(error REMOTE is required: make remove-lane LOCAL=<name> REMOTE=<name> [BOTH=1]))
	FOUNDRY_PROFILE=sync PROJECT_GROUP="$(GROUP)" forge script $(SYNC_SCRIPT) --sig "removeLane(string,string)" "$(LOCAL)" "$(REMOTE)"
ifdef BOTH
	FOUNDRY_PROFILE=sync PROJECT_GROUP="$(GROUP)" forge script $(SYNC_SCRIPT) --sig "removeLane(string,string)" "$(REMOTE)" "$(LOCAL)"
endif
	@for c in "$(LOCAL)" "$(REMOTE)"; do \
		test -f "$(CONFIG_DIR)/$$c.json" || continue; \
		tmp="$$(mktemp)" && jq --indent 2 -S . "$(CONFIG_DIR)/$$c.json" > "$$tmp" && mv "$$tmp" "$(CONFIG_DIR)/$$c.json"; \
	done
	@echo "review the lane policy diff (lanes{} = owner policy), then: make doctor CHAIN=$(LOCAL)$(if $(GROUP), GROUP=$(GROUP),)"

adopt-token: tools ## Adopt an externally deployed token into project/[<GROUP>/]<CHAIN>.json (EVM: CHAIN= TOKEN= [TOKEN_POOL=]; non-EVM: CHAIN= TOKEN_B58= [POOL_B58=]; GROUP= for a second token)
	$(if $(CHAIN),,$(error CHAIN is required: make adopt-token CHAIN=<name> TOKEN=<addr> [TOKEN_POOL=<addr>], or non-EVM: TOKEN_B58=<base58> [POOL_B58=<base58>]))
	$(require-chain-config)
ifdef TOKEN_B58
	FOUNDRY_PROFILE=sync PROJECT_GROUP="$(GROUP)" forge script script/config/AdoptToken.s.sol --sig "runNonEvm(string,string,string)" "$(CHAIN)" "$(TOKEN_B58)" "$(POOL_B58)"
else
	$(if $(TOKEN),,$(error TOKEN is required - the externally deployed token address to adopt (or TOKEN_B58 for a non-EVM chain)))
	FOUNDRY_PROFILE=sync PROJECT_GROUP="$(GROUP)" forge script script/config/AdoptToken.s.sol --sig "run(string,address,address)" "$(CHAIN)" "$(TOKEN)" "$(or $(TOKEN_POOL),0x0000000000000000000000000000000000000000)"
endif

sync: tools ## Refresh <CHAIN>'s ccip{} block from the live API (CHAIN= required)
	$(if $(CHAIN),,$(error CHAIN is required: make sync CHAIN=<name>))
	$(require-chain-config)
	FOUNDRY_PROFILE=sync forge script $(SYNC_SCRIPT) --sig "run(string)" "$(CHAIN)"
	$(canon-chain-config)

sync-preview: tools ## Fetch + log <CHAIN>'s ccip{} from the API without writing (CHAIN= required)
	$(if $(CHAIN),,$(error CHAIN is required: make sync-preview CHAIN=<name>))
	$(require-chain-config)
	FOUNDRY_PROFILE=sync forge script $(SYNC_SCRIPT) --sig "preview(string)" "$(CHAIN)"

sync-all: tools ## Refresh every configured chain (non-EVM chains SKIP; failures are collected)
	@failed=""; for f in $(CONFIG_DIR)/*.json; do \
		name="$$(basename "$$f" .json)"; \
		case "$$name" in zz-scratch-*) continue ;; esac; \
		echo ">> sync $$name"; \
		FOUNDRY_PROFILE=sync forge script $(SYNC_SCRIPT) --sig "run(string)" "$$name" || failed="$$failed $$name"; \
		tmp="$$(mktemp)" && jq --indent 2 -S . "$$f" > "$$tmp" && mv "$$tmp" "$$f"; \
	done; \
	if [ -n "$$failed" ]; then echo "sync-all: FAILED for:$$failed"; exit 1; fi; \
	echo "sync-all: OK - every configured chain synced (or SKIPped)"

fmt-config: tools ## Repair canonical JSON: config/chains/*.json (jq -S + trailing newline) AND project files, all groups (jq -S, NO trailing newline)
	@for f in $(CONFIG_DIR)/*.json; do \
		case "$$f" in *zz-scratch-*) continue ;; esac; \
		tmp="$$(mktemp)" && jq --indent 2 -S . "$$f" > "$$tmp" && mv "$$tmp" "$$f"; \
	done; \
	for f in project/*.json project/*/*.json; do \
		[ -e "$$f" ] || continue; \
		case "$$f" in *zz-scratch-*|*.example.json) continue ;; esac; \
		tmp="$$(mktemp)" && jq --indent 2 -S . "$$f" > "$$tmp" && printf '%s' "$$(cat "$$tmp")" > "$$f" && rm -f "$$tmp"; \
	done; \
	echo "fmt-config: canonicalized $(CONFIG_DIR)/*.json and project files (all groups)"

# Explicit patterns only - NEVER `git clean -X` here: the user's REAL project/history state is
# gitignored by design, so an ignore-based sweep would delete live project files along with scratch.
clean-scratch: ## Remove gitignored test-scratch fixtures (zz-scratch-*, zz-tt-*, local-*) from config/chains/, project/ and history/
	@rm -f $(CONFIG_DIR)/zz-scratch-*.json project/zz-scratch-*.json project/local-*.json
	@rm -rf project/zz-scratch-*/ project/zz-tt-*/ history/*/zz-scratch-*
	@echo "clean-scratch: removed test-scratch fixtures from $(CONFIG_DIR)/, project/ and history/"

sync-check: tools ## Read-only drift check (CHAIN= optional; pass/fail only - CI uses the script for 0/1/2)
	@bash script/config/sync-check.sh $(CHAIN)

# Convenience sugar over the documented direct commands (README "Verifying deployed contracts"):
# `verify-args` prints the composed verifier flags for a chain; `verify` backfills one contract.
# The direct `forge verify-contract` / `forge script ... --verify` commands work without make.
verify-args: tools ## Print the forge verifier flags composed from config/chains/<CHAIN>.json (CHAIN= required)
	$(if $(CHAIN),,$(error CHAIN is required: make verify-args CHAIN=<name>))
	@bash script/config/verify-args.sh "$(CHAIN)"

verify: tools ## Source-verify an already-deployed contract on <CHAIN>'s explorer backend (CHAIN= ADDRESS= CONTRACT= required; CONSTRUCTOR_ARGS= optional, else guessed via the RPC)
	$(if $(CHAIN),,$(error CHAIN is required: make verify CHAIN=<name> ADDRESS=<addr> CONTRACT=<path:Name>))
	$(if $(ADDRESS),,$(error ADDRESS is required - the deployed contract address))
	$(if $(CONTRACT),,$(error CONTRACT is required - e.g. CONTRACT=src/CrossChainToken.sol:CrossChainToken))
	@bash script/config/verify-contract.sh "$(CHAIN)" "$(ADDRESS)" "$(CONTRACT)" $(if $(CONSTRUCTOR_ARGS),"$(CONSTRUCTOR_ARGS)",)

doctor: tools ## Layered verification of one chain's config (CHAIN= required; GROUP= scopes to one token group)
	$(if $(CHAIN),,$(error CHAIN is required: make doctor CHAIN=<name>))
	$(require-chain-config)
	FOUNDRY_PROFILE=sync PROJECT_GROUP="$(GROUP)" forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" "$(CHAIN)"

preflight: tools ## Preflight a token transfer before sending: simulate source lockOrBurn + dest releaseOrMint against live state, GO/NO-GO (SOURCE_CHAIN= DEST_CHAIN= AMOUNT= RECEIVER= required; opt SOURCE_POOL= DEST_POOL= ORIGINAL_SENDER= REQUESTED_FINALITY=; read-only, no keystore)
	$(if $(SOURCE_CHAIN),,$(error SOURCE_CHAIN is required: make preflight SOURCE_CHAIN=<name> DEST_CHAIN=<name> AMOUNT=<wei> RECEIVER=<addr>))
	$(if $(DEST_CHAIN),,$(error DEST_CHAIN is required: make preflight SOURCE_CHAIN=<name> DEST_CHAIN=<name> AMOUNT=<wei> RECEIVER=<addr>))
	$(if $(AMOUNT),,$(error AMOUNT is required in wei: make preflight SOURCE_CHAIN=<name> DEST_CHAIN=<name> AMOUNT=<wei> RECEIVER=<addr>))
	$(if $(RECEIVER),,$(error RECEIVER is required: make preflight SOURCE_CHAIN=<name> DEST_CHAIN=<name> AMOUNT=<wei> RECEIVER=<addr>))
	@test -f "$(CONFIG_DIR)/$(SOURCE_CHAIN).json" || { echo "unknown SOURCE_CHAIN '$(SOURCE_CHAIN)' - known chains: $(KNOWN_CHAINS)"; exit 1; }; \
	test -f "$(CONFIG_DIR)/$(DEST_CHAIN).json" || { echo "unknown DEST_CHAIN '$(DEST_CHAIN)' - known chains: $(KNOWN_CHAINS)"; exit 1; }; \
	src_rpc_env="$$(jq -r '.rpcEnv // empty' "$(CONFIG_DIR)/$(SOURCE_CHAIN).json")"; \
	dst_rpc_env="$$(jq -r '.rpcEnv // empty' "$(CONFIG_DIR)/$(DEST_CHAIN).json")"; \
	src_rpc="$$(printenv "$$src_rpc_env" || true)"; dst_rpc="$$(printenv "$$dst_rpc_env" || true)"; \
	test -n "$$src_rpc" || { echo "source RPC not set - export $$src_rpc_env=<url> (the rpcEnv field in $(CONFIG_DIR)/$(SOURCE_CHAIN).json)"; exit 1; }; \
	test -n "$$dst_rpc" || { echo "dest RPC not set - export $$dst_rpc_env=<url> (the rpcEnv field in $(CONFIG_DIR)/$(DEST_CHAIN).json)"; exit 1; }; \
	SOURCE_CHAIN="$(SOURCE_CHAIN)" DEST_CHAIN="$(DEST_CHAIN)" SOURCE_RPC_URL="$$src_rpc" DEST_RPC_URL="$$dst_rpc" \
	  forge script script/diagnostics/PreflightTransfer.s.sol --tc PreflightTransfer

# ------------------------------------------------------------------------- deploy lifecycle golden path
# The deploy targets close the DX gap the config golden path (add-chain/doctor) left: they resolve
# --rpc-url from the chain file's `rpcEnv` field and --account from KEYSTORE_NAME, so no per-chain RPC
# is hand-exported before each `forge script`. The raw `forge script` command each wraps stays
# documented in README.md ("What this runs") as the escape hatch. Address persistence and the redeploy
# guard are the scripts' own RegistryWriter behavior, reused unchanged.
#
# $(call run-deploy,<script-path>): resolve the chain's RPC + keystore, then broadcast. VERIFY=1 appends
# --verify plus the config-driven verifier flags (script/config/verify-args.sh) so deploy and explorer
# verification are one step; ETHERSCAN_API_KEY is read from the environment and never echoed.
define run-deploy
	@case "$(CHAIN)" in ""|*[!a-z0-9-]*) echo "invalid CHAIN '$(CHAIN)' - use lowercase letters, digits, and hyphens only"; exit 1;; esac; \
	rpc_env="$$(jq -r '.rpcEnv // empty' "$(CONFIG_DIR)/$(CHAIN).json")"; \
	test -n "$$rpc_env" || { echo "chain '$(CHAIN)' declares no rpcEnv - run: make sync CHAIN=$(CHAIN)"; exit 1; }; \
	rpc_url="$$(printenv "$$rpc_env" || true)"; \
	test -n "$$rpc_url" || { echo "RPC URL not set - export $$rpc_env=<url> (the rpcEnv field named in $(CONFIG_DIR)/$(CHAIN).json)"; exit 1; }; \
	test -n "$(KEYSTORE_NAME)" || { echo "KEYSTORE_NAME is required - export KEYSTORE_NAME=<forge keystore account> (create one with: cast wallet import)"; exit 1; }; \
	verify=""; \
	if [ -n "$(VERIFY)" ]; then verify="--verify $$(bash script/config/verify-args.sh "$(CHAIN)")" || { echo "could not compose verifier flags for $(CHAIN)"; exit 1; }; fi; \
	echo ">> deploy $(1) on $(CHAIN) (rpc: $$rpc_env, account: $(KEYSTORE_NAME))"; \
	PROJECT_GROUP="$(GROUP)" forge script $(1) --rpc-url "$$rpc_url" --account "$(KEYSTORE_NAME)" --broadcast $$verify
endef

deploy-token: tools ## Deploy a cross-chain token on <CHAIN> (CHAIN= + KEYSTORE_NAME= required; token params via env TOKEN_NAME= TOKEN_SYMBOL= ...; VERIFY=1 source-verifies; FORCE_REDEPLOY=1 overrides the redeploy guard; GROUP= scopes to a token group)
	$(if $(CHAIN),,$(error CHAIN is required: make deploy-token CHAIN=<name> (token params via env: TOKEN_NAME= TOKEN_SYMBOL= TOKEN_DECIMALS= ...)))
	$(require-chain-config)
	$(call run-deploy,script/deploy/DeployToken.s.sol)

deploy-pool: tools ## Deploy a BurnMint token pool on <CHAIN> (CHAIN= + KEYSTORE_NAME= required; token resolved from the registry, else TOKEN=; opt POOL_HOOKS=; VERIFY=1; FORCE_REDEPLOY=1; GROUP= scopes to a token group)
	$(if $(CHAIN),,$(error CHAIN is required: make deploy-pool CHAIN=<name>))
	$(require-chain-config)
	$(call run-deploy,script/deploy/DeployBurnMintTokenPool.s.sol)

deploy-lockbox: tools ## Deploy an ERC20 LockBox on <CHAIN> for the LockRelease liquidity model (CHAIN= + KEYSTORE_NAME= required; token from the registry, else TOKEN=; opt AUTHORIZED_CALLERS=; VERIFY=1; GROUP= scopes to a token group)
	$(if $(CHAIN),,$(error CHAIN is required: make deploy-lockbox CHAIN=<name>))
	$(require-chain-config)
	$(call run-deploy,script/deploy/DeployERC20LockBox.s.sol)

deploy-lockrelease-pool: tools ## Deploy a LockRelease token pool on <CHAIN> (CHAIN= + KEYSTORE_NAME= required; token + lock box from the registry, else TOKEN= LOCK_BOX=; opt POOL_HOOKS=; VERIFY=1; FORCE_REDEPLOY=1; GROUP= scopes to a token group)
	$(if $(CHAIN),,$(error CHAIN is required: make deploy-lockrelease-pool CHAIN=<name>))
	$(require-chain-config)
	$(call run-deploy,script/deploy/DeployLockReleaseTokenPool.s.sol)

deploy-new-chain: tools ## Guided deploy: add-chain -> deploy-token -> deploy-pool -> doctor (CHAIN= SELECTOR= + KEYSTORE_NAME= required; token params + VERIFY= via env). Register, set-pool, and wire-lane come next - see docs/workflows/greenfield-deploy.md; a green run means deployed, not yet cross-chain-live
	$(if $(CHAIN),,$(error CHAIN is required: make deploy-new-chain CHAIN=<selectorName> SELECTOR=<selector> (token params via env)))
	$(if $(SELECTOR),,$(error SELECTOR is required - find it with: make discover FILTER=<term>))
	@$(MAKE) --no-print-directory add-chain CHAIN=$(CHAIN) SELECTOR=$(SELECTOR)
	@$(MAKE) --no-print-directory deploy-token CHAIN=$(CHAIN) $(if $(GROUP),GROUP=$(GROUP),)
	@$(MAKE) --no-print-directory deploy-pool CHAIN=$(CHAIN) $(if $(GROUP),GROUP=$(GROUP),)
	@$(MAKE) --no-print-directory doctor CHAIN=$(CHAIN) $(if $(GROUP),GROUP=$(GROUP),)

# ---------------------------------------------------------------- authority durable store (roles{})
# The `roles{}` subtree is the DECLARED authority surface, versioned in git. `snapshot-chain` is the
# ONLY writer (backfill FROM chain); `roles-check` is READ-ONLY (reconcile declared vs live). Same
# exit-remap note as sync-check: the 0/1/2 contract lives in `script/config/roles-check.sh`; CI calls
# the script directly, `make roles-check` is pass/fail only.

snapshot-chain: tools ## Backfill the declared roles{} authority block FROM chain (CHAIN= required; GROUP= scopes to one token group; opt: TOKEN= TOKEN_POOL= TAR= SCAN_FROM_BLOCK=)
	$(if $(CHAIN),,$(error CHAIN is required: make snapshot-chain CHAIN=<name>))
	$(require-chain-config)
	FOUNDRY_PROFILE=sync PROJECT_GROUP="$(GROUP)" forge script script/config/SnapshotChain.s.sol --sig "run(string)" "$(CHAIN)"
	$(canon-project)
	@echo "review the roles{} diff in project/$(GROUP_DIR)$(CHAIN).json (roles{} = declared authority), then reconcile: make roles-check CHAIN=$(CHAIN)$(if $(GROUP), GROUP=$(GROUP),)"

roles-check: tools ## READ-ONLY reconcile of a chain's declared roles{} vs the live chain (CHAIN= optional; GROUP= scopes to one token group; pass/fail only - CI uses the script for 0/1/2)
	@PROJECT_GROUP="$(GROUP)" bash script/config/roles-check.sh $(CHAIN)

roles-check-all: tools ## READ-ONLY reconcile of every chain that declares roles{}, across all token groups (exit contract = script/config/roles-check.sh)
	@bash script/config/roles-check.sh
