#!/usr/bin/env node
// check-docs.mjs - the docs CI gate. Keeps the documentation base strong as it grows:
//
//   1. Link and anchor check: every relative Markdown link resolves to a file that exists, and every
//      "#anchor" resolves to a heading or an explicit <a id> in the target. A renamed heading or moved
//      file fails the build instead of leaving a broken deep link.
//   2. Prose check: no doc carries an em-dash (workspace style: spaced hyphens only).
//
// Usage: node script/docs/check-docs.mjs   (exit 1 on any problem)

import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { join, dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

function walk(dir) {
  const out = [];
  if (!existsSync(dir)) return out;
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(p));
    else if (e.name.endsWith(".md")) out.push(p);
  }
  return out;
}

// Files to check: every Markdown doc plus the root router files.
function docFiles() {
  const files = walk(join(REPO, "docs"));
  for (const root of ["README.md", "AGENTS.md", "CLAUDE.md"]) {
    const p = join(REPO, root);
    if (existsSync(p)) files.push(p);
  }
  return files;
}

// GitHub-style heading slug.
function slug(text) {
  return text
    .trim()
    .toLowerCase()
    .replace(/[`*~]/g, "") // strip emphasis markers, but NOT underscores (github-slugger keeps them: word chars)
    .replace(/[^\w\s-]/g, "")
    .replace(/\s/g, "-"); // each whitespace char becomes a hyphen (matches github-slugger; runs are NOT collapsed)
}

// Anchors a file defines: heading slugs plus explicit <a id="..."> / {#...} anchors.
function anchorsOf(src) {
  const anchors = new Set();
  for (const line of src.split("\n")) {
    const h = line.match(/^#{1,6}\s+(.*?)\s*$/);
    if (h) anchors.add(slug(h[1]));
    for (const m of line.matchAll(/<a\s+id=["']([^"']+)["']/g)) anchors.add(m[1]);
    for (const m of line.matchAll(/\{#([\w-]+)\}/g)) anchors.add(m[1]);
  }
  return anchors;
}

// Resolve a link target (a directory resolves to its index.md).
function resolveTarget(fromFile, target) {
  let p = resolve(dirname(fromFile), target);
  if (existsSync(p) && statSync(p).isDirectory()) p = join(p, "index.md");
  return p;
}

// Front-matter schema: every page under docs/ declares a valid Diataxis type. This is the one piece of
// metadata the repo keeps, so the gate enforces it (lean metadata: only what is used).
const VALID_TYPES = new Set(["tutorial", "guide", "reference", "concept", "index", "decision", "workflow"]);

// Workflow manifests reference primitive names; validate they exist in the generated catalog so a
// manifest cannot drift from the code (the IA's cannot-drift guarantee for composed workflows).
function checkWorkflowManifests(push) {
  const wfDir = join(REPO, "docs", "workflows");
  const catalogPath = join(REPO, "docs", "primitives", "catalog.json");
  if (!existsSync(wfDir) || !existsSync(catalogPath)) return;
  const names = new Set(JSON.parse(readFileSync(catalogPath, "utf8")).primitives.map((p) => p.name));
  for (const f of readdirSync(wfDir)) {
    if (!f.endsWith(".arazzo.json")) continue;
    const rel = `docs/workflows/${f}`;
    let manifest;
    try {
      manifest = JSON.parse(readFileSync(join(wfDir, f), "utf8"));
    } catch (e) {
      push(`${rel}: invalid JSON (${e.message})`);
      continue;
    }
    for (const step of manifest.steps || []) {
      if (step.primitive && !names.has(step.primitive))
        push(`${rel}: step '${step.stepId}' names unknown primitive '${step.primitive}'`);
    }
  }
}

const errors = [];
const files = docFiles();
const anchorCache = new Map();
const anchorsFor = (p) => {
  if (!anchorCache.has(p)) anchorCache.set(p, existsSync(p) ? anchorsOf(readFileSync(p, "utf8")) : null);
  return anchorCache.get(p);
};

for (const file of files) {
  const rel = relative(REPO, file).replaceAll("\\", "/");
  const src = readFileSync(file, "utf8");

  // Front-matter type check (docs/ pages only; the root routers README/AGENTS/CLAUDE carry no matter).
  if (rel.startsWith("docs/")) {
    const fm = src.match(/^---\n([\s\S]*?)\n---/);
    const typeM = fm && fm[1].match(/^type:\s*(\S+)/m);
    if (!typeM) errors.push(`${rel}: missing front-matter 'type:'`);
    else if (!VALID_TYPES.has(typeM[1])) errors.push(`${rel}: invalid type '${typeM[1]}' (use one of ${[...VALID_TYPES].join(", ")})`);
  }

  // Em-dash rule (skip fenced code): no doc carries an em-dash.
  {
    let inFence = false;
    src.split("\n").forEach((line, i) => {
      if (/^\s*```/.test(line)) inFence = !inFence;
      if (!inFence && line.includes("\u2014")) errors.push(`${rel}:${i + 1}: em-dash (use a spaced hyphen)`);
    });
  }

  // Link and anchor check. Strip fenced code first so a link shown inside a ``` example is not validated.
  const noFence = src.replace(/```[\s\S]*?```/g, "");
  for (const m of noFence.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
    let link = m[1].trim();
    if (/^(https?:|mailto:|#)/.test(link) || link.startsWith("<")) {
      // Same-page anchor.
      if (link.startsWith("#")) {
        const a = anchorsFor(file);
        if (a && !a.has(link.slice(1))) errors.push(`${rel}: missing anchor ${link}`);
      }
      continue;
    }
    const [path, anchor] = link.split("#");
    const target = resolveTarget(file, path);
    if (!existsSync(target)) {
      errors.push(`${rel}: broken link -> ${link} (no ${relative(REPO, target)})`);
      continue;
    }
    // Validate anchors only for in-repo Markdown targets (a #L10 line-anchor on a source file, or a
    // target outside the repo, is not a heading-slug and must not be resolved).
    if (anchor && target.endsWith(".md") && !relative(REPO, target).startsWith("..")) {
      const a = anchorsFor(target);
      if (a && !a.has(anchor)) errors.push(`${rel}: missing anchor #${anchor} in ${relative(REPO, target)}`);
    }
  }
}

checkWorkflowManifests((e) => errors.push(e));

if (errors.length) {
  console.error(`[docs] ${errors.length} problem(s):`);
  for (const e of errors) console.error("  " + e);
  process.exit(1);
}
console.log(`[docs] OK - ${files.length} files, links and anchors resolve, no em-dashes in authored docs.`);
