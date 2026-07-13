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

.DEFAULT_GOAL := help
.PHONY: adopt-token help tools discover add-chain add-lane remove-lane sync sync-preview sync-all sync-check doctor fmt-config

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

add-lane: tools ## Append a lanes{} policy entry LOCAL -> REMOTE (LOCAL= REMOTE= CAPACITY= RATE= required; INBOUND_CAPACITY= + INBOUND_RATE= add the inbound block; BOTH=1 adds the reciprocal)
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
	FOUNDRY_PROFILE=sync forge script $(SYNC_SCRIPT) --sig "addLane(string,string,uint256,uint256,uint256,uint256)" "$(LOCAL)" "$(REMOTE)" "$(CAPACITY)" "$(RATE)" "$(INBOUND_CAPACITY)" "$(INBOUND_RATE)"
else
	FOUNDRY_PROFILE=sync forge script $(SYNC_SCRIPT) --sig "addLane(string,string,uint256,uint256)" "$(LOCAL)" "$(REMOTE)" "$(CAPACITY)" "$(RATE)"
endif
ifdef BOTH
ifdef INBOUND_CAPACITY
	FOUNDRY_PROFILE=sync forge script $(SYNC_SCRIPT) --sig "addLane(string,string,uint256,uint256,uint256,uint256)" "$(REMOTE)" "$(LOCAL)" "$(CAPACITY)" "$(RATE)" "$(INBOUND_CAPACITY)" "$(INBOUND_RATE)"
else
	FOUNDRY_PROFILE=sync forge script $(SYNC_SCRIPT) --sig "addLane(string,string,uint256,uint256)" "$(REMOTE)" "$(LOCAL)" "$(CAPACITY)" "$(RATE)"
endif
endif
	@for c in "$(LOCAL)" "$(REMOTE)"; do \
		tmp="$$(mktemp)" && jq --indent 2 -S . "$(CONFIG_DIR)/$$c.json" > "$$tmp" && mv "$$tmp" "$(CONFIG_DIR)/$$c.json"; \
	done
	@echo "review the lane policy diff (lanes{} = owner policy), then: make doctor CHAIN=$(LOCAL)"

remove-lane: tools ## Remove a lanes{} policy entry LOCAL -> REMOTE from the declaration (LOCAL= REMOTE= required; BOTH=1 removes the reciprocal; on-chain removal via ApplyChainUpdates is a separate step)
	$(if $(LOCAL),,$(error LOCAL is required: make remove-lane LOCAL=<name> REMOTE=<name> [BOTH=1]))
	$(if $(REMOTE),,$(error REMOTE is required: make remove-lane LOCAL=<name> REMOTE=<name> [BOTH=1]))
	FOUNDRY_PROFILE=sync forge script $(SYNC_SCRIPT) --sig "removeLane(string,string)" "$(LOCAL)" "$(REMOTE)"
ifdef BOTH
	FOUNDRY_PROFILE=sync forge script $(SYNC_SCRIPT) --sig "removeLane(string,string)" "$(REMOTE)" "$(LOCAL)"
endif
	@for c in "$(LOCAL)" "$(REMOTE)"; do \
		test -f "$(CONFIG_DIR)/$$c.json" || continue; \
		tmp="$$(mktemp)" && jq --indent 2 -S . "$(CONFIG_DIR)/$$c.json" > "$$tmp" && mv "$$tmp" "$(CONFIG_DIR)/$$c.json"; \
	done
	@echo "review the lane policy diff (lanes{} = owner policy), then: make doctor CHAIN=$(LOCAL)"

adopt-token: tools ## Adopt an externally deployed token into the registry (CHAIN= TOKEN= required; TOKEN_POOL= optional)
	$(if $(CHAIN),,$(error CHAIN is required: make adopt-token CHAIN=<name> TOKEN=<addr> [TOKEN_POOL=<addr>]))
	$(if $(TOKEN),,$(error TOKEN is required - the externally deployed token address to adopt))
	$(require-chain-config)
	FOUNDRY_PROFILE=sync forge script script/config/AdoptToken.s.sol --sig "run(string,address,address)" "$(CHAIN)" "$(TOKEN)" "$(or $(TOKEN_POOL),0x0000000000000000000000000000000000000000)"

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

fmt-config: tools ## Rewrite config/chains/*.json in the canonical style (jq --indent 2 -S, trailing newline)
	@for f in $(CONFIG_DIR)/*.json; do \
		case "$$f" in *zz-scratch-*) continue ;; esac; \
		tmp="$$(mktemp)" && jq --indent 2 -S . "$$f" > "$$tmp" && mv "$$tmp" "$$f"; \
	done; \
	echo "fmt-config: canonicalized $(CONFIG_DIR)/*.json"

sync-check: tools ## Read-only drift check (CHAIN= optional; pass/fail only - CI uses the script for 0/1/2)
	@bash script/config/sync-check.sh $(CHAIN)

doctor: tools ## Layered verification of one chain's config (CHAIN= required)
	$(if $(CHAIN),,$(error CHAIN is required: make doctor CHAIN=<name>))
	$(require-chain-config)
	FOUNDRY_PROFILE=sync forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" "$(CHAIN)"
