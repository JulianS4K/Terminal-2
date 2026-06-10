#!/usr/bin/env node
// graph-drift.mjs — report how stale the committed code knowledge graph is
// against the working tree. Lists files ADDED since the snapshot (tracked but
// not in .understand-anything/knowledge-graph.json) and files REMOVED (graph
// nodes whose file no longer exists). Report-only by default; pass --check to
// exit non-zero when drift exists (e.g. to gate or warn in CI).
//
// Usage:
//   node bin/graph-drift.mjs            # print the drift report
//   node bin/graph-drift.mjs --check    # same, but exit 1 if any drift
//
// When it reports additions, fold them into the graph (new nodes + grounded
// edges) and refresh project.gitCommitHash — see PROJECT_BIBLE.md §8.
import { readFileSync, existsSync } from "node:fs";
import { execSync } from "node:child_process";
import { dirname, resolve, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const graphPath = join(root, ".understand-anything", "knowledge-graph.json");
if (!existsSync(graphPath)) {
  console.error("No knowledge graph at .understand-anything/knowledge-graph.json — run /understand first.");
  process.exit(2);
}
const graph = JSON.parse(readFileSync(graphPath, "utf8"));
const nodeFiles = new Set(graph.nodes.filter(n => n.filePath).map(n => n.filePath));

// Mirror the scanner's default exclusions (generated artifacts, binaries, locks).
const IGNORE = p =>
  /^(node_modules|\.git|dist|build|out|coverage|\.understand-anything)\//.test(p) ||
  /\.(png|jpe?g|gif|svg|ico|woff2?|ttf|eot|mp3|mp4|pdf|zip|map|min\.js|min\.css)$/.test(p) ||
  /(^|\/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock)$/.test(p);

const tracked = execSync("git ls-files", { cwd: root }).toString().trim().split("\n").filter(Boolean);
const added = tracked.filter(f => !IGNORE(f) && !nodeFiles.has(f));
const removed = [...nodeFiles].filter(f => !existsSync(join(root, f)));

const group = files => {
  const g = {};
  for (const f of files) {
    const d = f.includes("/") ? f.split("/").slice(0, -1).join("/") : "(root)";
    (g[d] ??= []).push(f.split("/").pop());
  }
  return g;
};
const printGroup = (label, files) => {
  if (!files.length) { console.log(`  ${label}: none`); return; }
  console.log(`  ${label}: ${files.length}`);
  const g = group(files);
  for (const d of Object.keys(g).sort()) {
    console.log(`    ${d} (${g[d].length}): ${g[d].slice(0, 8).join(", ")}${g[d].length > 8 ? " …" : ""}`);
  }
};

console.log(`Graph snapshot commit: ${(graph.project?.gitCommitHash || "?").slice(0, 10)}`);
try { console.log(`Working tree HEAD:     ${execSync("git rev-parse --short HEAD", { cwd: root }).toString().trim()}`); } catch {}
console.log(`Graph: ${graph.nodes.length} nodes, ${graph.edges.length} edges`);
console.log("");
printGroup("ADDED (in repo, not in graph)", added);
printGroup("REMOVED (in graph, file gone)", removed);

const drift = added.length + removed.length;
console.log(`\n${drift ? `⚠ ${drift} file(s) drifted` : "✅ graph is in sync with the working tree"}`);
if (process.argv.includes("--check") && drift) process.exit(1);
