#!/usr/bin/env node
// gen-primitives.mjs - generate the primitives catalog from the script/ tree.
//
// The catalog is the machine-readable index of the repo's deterministic building blocks. It is
// GENERATED from the scripts and the Makefile so it cannot drift from the code: every user-facing
// forge script and every `## `-documented make target gets exactly one entry, derived from the source
// (description from the @notice NatSpec, inputs from the vm.env* reads, modes and safety flags from the
// base contract and naming). Rich human context that cannot be derived (when-to-use, pre/postconditions,
// worked example, known failure modes, and flag overrides) is authored in docs/primitives/_meta.json and
// merged in; a page still generates from derived facts alone when no authored supplement exists.
//
// Outputs:
//   docs/primitives/catalog.json          - the structured machine index (scripts + make targets)
//   docs/primitives/<group>/<Name>.md      - one human page per forge-script primitive
//
// Usage:
//   node script/docs/gen-primitives.mjs           # write the catalog and pages
//   node script/docs/gen-primitives.mjs --check    # regenerate to memory and fail on any drift (CI gate)
//
// The --check mode is the CI freshness + coverage gate: it fails if a new script has no entry, if an
// entry names a deleted script, or if the committed catalog/pages differ from a fresh generation.

import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { join, relative, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SCRIPT_DIR = join(REPO, "script");
const OUT_DIR = join(REPO, "docs", "primitives");
const META_FILE = join(OUT_DIR, "_meta.json");
const CATALOG_FILE = join(OUT_DIR, "catalog.json");

// Internal support files: library / abstract / helper code documented at the architecture and concepts
// level, NOT as primitive catalog entries. Everything else under script/ that defines a runnable
// contract is a user-facing primitive.
const INTERNAL = new Set([
  "script/HelperConfig.s.sol",
  "script/configure/liquidity/LiquidityBase.s.sol",
  "script/setup/token-roles/TokenRoleScript.s.sol",
  "script/setup/ClaimPathDetector.sol",
  "script/utils/ChainHandlers.s.sol",
  "script/utils/DeploymentRecorder.s.sol",
  "script/utils/DeploymentUtils.s.sol",
  "script/utils/FeeTokenLogger.s.sol",
  "script/utils/FinalityConfigUtils.s.sol",
  "script/utils/HelperUtils.s.sol",
  "script/utils/LanePolicySource.s.sol",
  "script/utils/PoolVersion.s.sol",
  "script/utils/RateLimiterUtils.s.sol",
]);

// Folder -> catalog group. Mirrors the verb folders under script/.
const GROUPS = [
  ["script/deploy", "deploy"],
  ["script/setup/token-roles", "token-roles"],
  ["script/setup/transfer-ownership", "ownership"],
  ["script/setup", "token-admin-registry"],
  ["script/configure/allowlist", "allowlist"],
  ["script/configure/authorized-callers", "authorized-callers"],
  ["script/configure/ccv", "ccv"],
  ["script/configure/dynamic-config", "dynamic-config"],
  ["script/configure/fee-config", "fee-config"],
  ["script/configure/finality-config", "finality-config"],
  ["script/configure/liquidity", "liquidity"],
  ["script/configure/rate-limiter", "rate-limiter"],
  ["script/configure/remote-chains", "remote-chains"],
  ["script/configure/remote-pools", "remote-pools"],
  ["script/configure", "configure"],
  ["script/operations", "operations"],
  ["script/governance", "governance"],
  ["script/config", "config-plane"],
  ["script/diagnostics", "diagnostics"],
];

function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(p));
    else if (entry.name.endsWith(".sol")) out.push(p);
  }
  return out;
}

function groupFor(rel) {
  for (const [prefix, group] of GROUPS) if (rel.startsWith(prefix + "/")) return group;
  return "other";
}

// First sentence of the @notice NatSpec, flattened to one line. Handles both `/** ... */` block and
// `/// ...` line NatSpec: captures the @notice text plus its continuation doc-lines, stopping at the
// next tag, the end of the comment, or the first non-doc line.
function extractNotice(src) {
  const lines = src.split("\n");
  let capturing = false;
  const buf = [];
  for (const raw of lines) {
    const line = raw.trim();
    const isDoc = line.startsWith("///") || line.startsWith("*") || line.startsWith("/*");
    const strip = (l) => l.replace(/^\/\*\*?/, "").replace(/^\/\/\//, "").replace(/^\*+/, "").replace(/\*\/\s*$/, "").trim();
    if (!capturing) {
      const idx = line.indexOf("@notice");
      if (idx !== -1) {
        capturing = true;
        buf.push(line.slice(idx + 7).trim());
        if (line.includes("*/")) break;
      }
      continue;
    }
    const stripped = strip(line);
    if (!isDoc || stripped.startsWith("@")) break;
    buf.push(stripped);
    if (line.includes("*/")) break;
  }
  const text = buf
    .join(" ")
    .replace(/\*\/\s*$/, "") // a same-line `/** @notice X */` leaves a trailing */
    .replace(/\s+/g, " ")
    .trim();
  // First sentence: a period followed by whitespace + a capital, or end of string. Avoids cutting on
  // an abbreviation ("e.g.", "i.e.") or a version ("v1.5.x") mid-word.
  const sentence = text.match(/^(.*?\.)(\s+[A-Z]|\s*$)/);
  return (sentence ? sentence[1] : text).trim();
}

// The runnable primitive is a concrete (non-abstract, non-interface) contract. A file may also define
// helper contracts/interfaces (e.g. VerifyChain.s.sol also defines ChainProbe + ITypeAndVersionReader);
// prefer the contract whose name matches the file basename, else the last concrete contract (the main
// contract conventionally sits last, after its helpers).
function contractName(src, absPath) {
  const stem = basename(absPath).replace(/\.(s\.)?sol$/, "");
  const concrete = [...src.matchAll(/^\s*contract\s+(\w+)/gm)].map((m) => m[1]);
  if (concrete.includes(stem)) return stem;
  if (concrete.length) return concrete[concrete.length - 1];
  return null; // pure-library / interface-only file: not a primitive
}

// Bases of the SPECIFIC contract we picked as the primitive (a file may define helper contracts with
// their own `is` clause; anchor on the name so modes/flags derive from the right contract).
function baseClass(src, name) {
  const m = src.match(new RegExp(`\\bcontract\\s+${name}\\s+is\\s+([^{]+)\\{`));
  return m ? m[1].split(",").map((s) => s.trim()) : [];
}

// Literal uppercase env vars read directly in the file (vm.env* / vm.envOr). Best-effort: a var read
// indirectly (through a helper/base or a constant) is not captured here; add it via _meta.json inputs.
function envVars(src) {
  const names = new Set();
  const re = /vm\.env(?:Or|Address|String|Uint|Int|Bool|Bytes32|Bytes)?\(\s*"([A-Z][A-Z0-9_]*)"/g;
  let m;
  while ((m = re.exec(src))) names.add(m[1]);
  return [...names].sort();
}

const DESTRUCTIVE_HINTS = [/^Remove/, /^Revoke/, /^Withdraw/];

function deriveScripts() {
  const files = walk(SCRIPT_DIR).sort();
  const primitives = [];
  for (const abs of files) {
    const rel = relative(REPO, abs).replaceAll("\\", "/");
    if (INTERNAL.has(rel)) continue;
    const src = readFileSync(abs, "utf8");
    const name = contractName(src, abs);
    if (!name) continue;
    const bases = baseClass(src, name);
    // Write scripts broadcast on-chain: the executor/base families, plus the Deploy* scripts.
    const isWrite =
      bases.some((b) => ["EoaExecutor", "LiquidityBase", "TokenRoleScript"].includes(b)) ||
      /^Deploy/.test(name);
    const isDeploy = /^Deploy/.test(name);
    // Config-plane scripts write to the project store (json), not on-chain.
    const isConfigPlane = rel.startsWith("script/config/");
    const readOnly = !isWrite && !isConfigPlane;
    // Modes: read-only scripts have no signing mode; deploys sign with a keystore (EOA only); the
    // EoaExecutor-based write scripts additionally support Safe batching (MODE=safe).
    let modes;
    if (readOnly) modes = ["read"];
    else if (isDeploy) modes = ["eoa"];
    else if (bases.includes("EoaExecutor") || bases.includes("LiquidityBase") || bases.includes("TokenRoleScript"))
      modes = ["eoa", "safe"];
    else modes = ["eoa"];
    primitives.push({
      name,
      script: rel,
      group: groupFor(rel),
      description: extractNotice(src),
      modes,
      read_only: readOnly,
      writes_onchain: isWrite,
      destructive: DESTRUCTIVE_HINTS.some((re) => re.test(name)),
      inputs: envVars(src),
    });
  }
  return primitives.sort((a, b) => a.script.localeCompare(b.script));
}

// Make targets carrying a `## ` help comment (same contract the Makefile help awk uses).
function deriveMakeTargets() {
  const mk = readFileSync(join(REPO, "Makefile"), "utf8");
  const out = [];
  for (const line of mk.split("\n")) {
    const m = line.match(/^([a-z][a-z-]*):.*?##\s+(.*)$/);
    if (m) out.push({ target: m[1], help: m[2].trim() });
  }
  return out;
}

function loadMeta() {
  if (!existsSync(META_FILE)) return {};
  return JSON.parse(readFileSync(META_FILE, "utf8"));
}

function merge(primitive, meta) {
  const m = meta[primitive.name] || {};
  // Authored supplements override or extend derived facts. Flags may be overridden explicitly.
  return {
    ...primitive,
    destructive: m.destructive ?? primitive.destructive,
    when_to_use: m.when_to_use ?? null,
    inputs_doc: m.inputs ?? null,
    outputs: m.outputs ?? null,
    example: m.example ?? null,
    preconditions: m.preconditions ?? null,
    postconditions: m.postconditions ?? null,
    failure_modes: m.failure_modes ?? null,
  };
}

function pagePath(p) {
  return join(OUT_DIR, p.group, `${p.name}.md`);
}

function renderPage(p) {
  const fm = [
    "---",
    `name: ${p.name}`,
    `script: ${p.script}`,
    `group: ${p.group}`,
    "type: reference",
    `modes: [${p.modes.join(", ")}]`,
    `read_only: ${p.read_only}`,
    `writes_onchain: ${p.writes_onchain}`,
    `destructive: ${p.destructive}`,
    "---",
  ].join("\n");

  const lines = [fm, "", `# ${p.name}`, ""];
  if (p.description) lines.push(p.description, "");
  if (p.when_to_use) lines.push(`**When to use.** ${p.when_to_use}`, "");

  lines.push("## Inputs", "");
  const inputDocs = p.inputs_doc || {};
  if (p.inputs.length || Object.keys(inputDocs).length) {
    lines.push("| Env var | Description |", "| --- | --- |");
    const all = [...new Set([...p.inputs, ...Object.keys(inputDocs)])].sort();
    for (const k of all) lines.push(`| \`${k}\` | ${inputDocs[k] || "See the script header."} |`);
  } else {
    lines.push("No environment inputs; resolves everything from the chain config and address registry.");
  }
  lines.push("");

  if (p.outputs) {
    lines.push("## Outputs", "", p.outputs, "");
  }
  if (p.example) {
    lines.push("## Example", "", "```bash", p.example.trim(), "```", "");
  }
  if (p.preconditions) lines.push("## Preconditions", "", p.preconditions, "");
  if (p.postconditions) lines.push("## Postconditions", "", p.postconditions, "");
  if (p.failure_modes) lines.push("## Known failure modes", "", p.failure_modes, "");

  lines.push(
    "## Reference",
    "",
    `- Script: [\`${p.script}\`](../../../${p.script})`,
    `- Modes: ${p.modes.join(", ")}`,
    `- Read-only: ${p.read_only} | Writes on-chain: ${p.writes_onchain} | Destructive: ${p.destructive}`,
    "",
    "_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's",
    "`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit",
    "this file by hand._",
    "",
  );
  return lines.join("\n");
}

// A human landing page for the catalog, grouped by verb folder, linking each primitive page.
function renderIndex(scripts) {
  const byGroup = new Map();
  for (const s of scripts) {
    if (!byGroup.has(s.group)) byGroup.set(s.group, []);
    byGroup.get(s.group).push(s);
  }
  const lines = [
    "---",
    "type: index",
    "---",
    "",
    "# Primitives catalog",
    "",
    "The deterministic building blocks: one page per user-facing script, grouped by area. Each page has the",
    "primitive's description, modes, safety flags, and inputs. Agents can consume the full structured index",
    "at [`catalog.json`](catalog.json). These pages are generated from the scripts and cannot drift; run",
    "`npm run docs:catalog` to regenerate.",
    "",
  ];
  for (const group of [...byGroup.keys()].sort()) {
    lines.push(`## ${group}`, "");
    for (const s of byGroup.get(group).sort((a, b) => a.name.localeCompare(b.name))) {
      const flags = s.read_only ? "read-only" : s.destructive ? "write, destructive" : "write";
      lines.push(`- [${s.name}](${group}/${s.name}.md) - ${s.description || "(see page)"} _(${flags})_`);
    }
    lines.push("");
  }
  return lines.join("\n");
}

function renderCatalog(scripts, makeTargets) {
  return (
    JSON.stringify(
      {
        generatedBy: "script/docs/gen-primitives.mjs",
        note: "Generated from the script/ tree and the Makefile. Do not edit by hand; run `npm run docs:catalog`.",
        counts: { primitives: scripts.length, makeTargets: makeTargets.length },
        primitives: scripts,
        makeTargets,
      },
      null,
      2,
    ) + "\n"
  );
}

function collectPages(scripts, meta) {
  const pages = new Map();
  for (const s of scripts) {
    const merged = merge(s, meta);
    pages.set(relative(REPO, pagePath(merged)).replaceAll("\\", "/"), renderPage(merged));
  }
  pages.set("docs/primitives/index.md", renderIndex(scripts));
  return pages;
}

function main() {
  const check = process.argv.includes("--check");
  const scripts = deriveScripts();
  const meta = loadMeta();

  // Coverage: no authored meta entry may name a script that no longer exists.
  const names = new Set(scripts.map((s) => s.name));
  const orphans = Object.keys(meta).filter((k) => !names.has(k));
  if (orphans.length) {
    console.error(`[catalog] _meta.json names unknown primitives (deleted or renamed): ${orphans.join(", ")}`);
    process.exit(1);
  }

  // Every primitive must carry a description. Solhint (chainlink-ccip config) does not enforce NatSpec,
  // so this gate owns the one NatSpec fact the catalog depends on: an @notice on each primitive contract.
  const undocumented = scripts.filter((s) => !s.description);
  if (undocumented.length) {
    console.error(
      `[catalog] ${undocumented.length} primitive(s) have no @notice - add one above the contract:\n` +
        undocumented.map((s) => `  - ${s.script}`).join("\n"),
    );
    process.exit(1);
  }

  const catalog = renderCatalog(scripts, deriveMakeTargets());
  const pages = collectPages(scripts, meta);

  if (check) {
    let drift = false;
    const committed = existsSync(CATALOG_FILE) ? readFileSync(CATALOG_FILE, "utf8") : "";
    if (committed !== catalog) {
      drift = true;
      console.error("[catalog] docs/primitives/catalog.json is stale - run `npm run docs:catalog`.");
    }
    // Any committed page that no longer corresponds to a primitive is an orphan.
    const wantPaths = new Set(pages.keys());
    for (const [rel, body] of pages) {
      const abs = join(REPO, rel);
      const have = existsSync(abs) ? readFileSync(abs, "utf8") : "";
      if (have !== body) {
        drift = true;
        console.error(`[catalog] ${rel} is stale or missing - run \`npm run docs:catalog\`.`);
      }
    }
    // Scan EVERY generated group directory (not only groups that still have a script), so a stale page
    // left behind in a group whose last script was deleted is still caught.
    for (const entry of readdirSync(OUT_DIR, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const gdir = join(OUT_DIR, entry.name);
      for (const f of readdirSync(gdir)) {
        if (!f.endsWith(".md")) continue;
        const rel = relative(REPO, join(gdir, f)).replaceAll("\\", "/");
        if (!wantPaths.has(rel)) {
          drift = true;
          console.error(`[catalog] ${rel} has no matching primitive (deleted script?) - run \`npm run docs:catalog\`.`);
        }
      }
    }
    if (drift) process.exit(1);
    console.log(`[catalog] OK - ${scripts.length} primitives, ${wantPaths.size} pages in sync.`);
    return;
  }

  // Write mode. Clear generated group dirs of stale pages, then write fresh.
  const groups = new Set(scripts.map((s) => s.group));
  for (const group of groups) {
    const gdir = join(OUT_DIR, group);
    if (existsSync(gdir)) {
      for (const f of readdirSync(gdir)) if (f.endsWith(".md")) rmSync(join(gdir, f));
    } else mkdirSync(gdir, { recursive: true });
  }
  for (const [rel, body] of pages) {
    const abs = join(REPO, rel);
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, body);
  }
  writeFileSync(CATALOG_FILE, catalog);
  console.log(`[catalog] wrote ${scripts.length} primitives and ${pages.size} pages under docs/primitives/.`);
}

main();
