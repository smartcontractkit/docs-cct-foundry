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
# roles-check); the chain-facts targets (add-chain, sync*) ignore it (config/chains is group-independent).
GROUP_DIR := $(if $(GROUP),$(GROUP)/,)

.DEFAULT_GOAL := help
.PHONY: adopt-token help tools discover add-chain add-lane remove-lane sync sync-preview sync-all sync-check doctor fmt-config snapshot-chain roles-check roles-check-all

# Recipe-time guard: the CHAIN's config file must exist (helpful list + add-chain hint on a miss).
define require-chain-config
	@test -f "$(CONFIG_DIR)/$(CHAIN).json" || { \
		echo "unknown chain '$(CHAIN)' - known chains: $(KNOWN_CHAINS)"; \
		echo "New chain? make add-chain CHAIN=<local-short-name> SELECTOR=<from 'make discover'>"; \
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
	@awk 'BEGIN {FS = ":.*## "} /^[a-z][a-z-]*:.*## / {printf "  %-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

tools: ## Check the required tools are installed (forge, curl, jq)
	@command -v forge > /dev/null || { echo "missing: forge - install Foundry: https://book.getfoundry.sh/getting-started/installation"; exit 2; }
	@command -v curl > /dev/null || { echo "missing: curl - install it (usually preinstalled; else brew install curl / apt install curl)"; exit 2; }
	@command -v jq > /dev/null || { echo "missing: jq - install it (e.g. brew install jq / apt install jq)"; exit 2; }
	@echo "tools: forge, curl and jq are all present"

discover: tools ## List the CCIP API testnet catalog vs local configs (FILTER=<term> narrows)
	@FILTER="$(FILTER)" bash script/config/sync-discover.sh

add-chain: tools ## Generate config/chains/<CHAIN>.json from the live API (CHAIN= and SELECTOR= required)
	$(if $(CHAIN),,$(error CHAIN is required: make add-chain CHAIN=<local-short-name> SELECTOR=<selector>))
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
			echo "New chain? make add-chain CHAIN=<local-short-name> SELECTOR=<from 'make discover'>"; \
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

sync-check: tools ## Read-only drift check (CHAIN= optional; pass/fail only - CI uses the script for 0/1/2)
	@bash script/config/sync-check.sh $(CHAIN)

doctor: tools ## Layered verification of one chain's config (CHAIN= required; GROUP= scopes to one token group)
	$(if $(CHAIN),,$(error CHAIN is required: make doctor CHAIN=<name>))
	$(require-chain-config)
	FOUNDRY_PROFILE=sync PROJECT_GROUP="$(GROUP)" forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" "$(CHAIN)"

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
