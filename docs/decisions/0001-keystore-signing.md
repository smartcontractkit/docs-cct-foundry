---
type: decision
---

# 1. Sign with a Foundry keystore, never a private key in `.env`

## Context

Every broadcasting script needs a signer. Two options are common in Foundry projects: an encrypted
keystore account (`--account <name>`, unlocked at run time) or a raw `PRIVATE_KEY` read from `.env`. The
choice is a security decision, so it is recorded here rather than re-litigated each time.

## Decision

The template signs with a Foundry keystore only (`--account`), and the docs recommend the keystore as
the signing method. It deliberately does not read or document a private key from `.env`. `.env` holds
configuration (RPC URLs, API keys, the keystore name), never key material. Any forge wallet flag works,
since the executor uses forge's native broadcaster resolution: `--account` (keystore), `--ledger`, or
`--trezor`.

The recommended baseline is an encrypted keystore (`cast wallet import <name>`, then `--account <name>`),
with a hardware wallet (`--ledger` / `--trezor`) as the stronger option for high-value signers. The
toolkit already supports both.

## Rationale

A July 2026 survey of the Foundry docs and roughly 15 reference repositories (templates, protocols, and
governance and security references) found that major projects never keep a production `PRIVATE_KEY` in
`.env`:

- Aave signs with a Ledger hardware wallet (`--ledger --sender`).
- Optimism delegates key custody to an external `op-deployer` tool.
- Uniswap v4-core and Morpho Blue ship no key at all.
- Community templates that embed key material keep only a test mnemonic.

## Consequences

- A future "put `PRIVATE_KEY` in `.env` for convenience" proposal is answered by this record.
- Companion fact: the Foundry keystore protects the **signing key only**. It is an ERC-2335-style
  encrypted key file; there is no Foundry mechanism to store an RPC URL or an explorer API key in it, and
  no surveyed repo does. RPC URLs and API keys are a separate, lower-sensitivity concern kept in `.env`
  (and referenced from `foundry.toml` via `${VAR}` where a toml block is used), or injected as CI
  secrets, never the keystore.
