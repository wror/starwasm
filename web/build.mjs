// build.mjs — assemble the browser REPL as a static site:
//
//   node web/build.mjs [outdir]        (default out/site)
//
// outdir gets web/'s page, the host code it shares with the Node REPL
// (host/wasmhost.mjs, host/repl_core.mjs), compiler.wasm, the compiler
// compiled to Wasm (host/wasmcache.mjs's default compiler; building it
// needs bin/starhost), and typecheck.wasm, the type checker
// (typecheck/main.star) compiled by it. Serve outdir with any static file server, e.g.
//   python3 -m http.server -d out/site
// .github/workflows/pages.yml publishes it with GitHub Pages.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { compileStar, defaultCompiler } from "../host/wasmcache.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const out = resolve(process.argv[2] ?? join(ROOT, "out/site"));
// The site's files: published path -> contents.
const files = new Map();
for (const f of ["index.html", "repl.js", "repl_worker.js"]) files.set(f, readFileSync(join(ROOT, "web", f), "utf8"));
for (const f of ["wasmhost.mjs", "repl_core.mjs"]) files.set(`host/${f}`, readFileSync(join(ROOT, "host", f), "utf8"));

// The page's footer names the commit the site was built from: its
// "<!--sha-->" becomes the seven digit sha, linked to the commit ("+"
// after it if tracked files differ from the commit). Without git (a
// source tarball), it stays a comment.
const SHA_MARK = "<!--sha-->";
if (files.get("index.html").split(SHA_MARK).length !== 2) throw new Error(`web/build.mjs: index.html should contain ${SHA_MARK} once`);
const git = (...args) => execFileSync("git", ["-C", ROOT, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
let sha = "";
try {
  const full = git("rev-parse", "HEAD");
  sha = full.slice(0, 7) + (git("status", "--porcelain", "--untracked-files=no") ? "+" : "");
  files.set("index.html", files.get("index.html").replace(SHA_MARK,
    ` at <a href="https://github.com/wror/starwasm/commit/${full}"><code>${sha}</code></a>`));
} catch { /* not a git checkout */ }
files.set("compiler.wasm", defaultCompiler());
// the type checker (.type, .types, .check), fetched when first used
files.set("typecheck.wasm", compileStar(join(ROOT, "typecheck/main.star"), ["--recursion"]));

// Browsers cache GitHub Pages' files for 10 minutes, so after a deploy a
// reload could run the new page with the old scripts. Each reference
// between the files gets "?v=<hash of the site>": a new version of the
// site loads only new files.
const hash = createHash("sha256");
for (const [f, data] of [...files].sort()) hash.update(f).update(data);
const v = hash.digest("hex").slice(0, 12);
const refs = [ // [file, the reference in it, exactly]
  ["index.html", '<script type="module" src="repl.js">'],
  ["repl.js", 'new Worker("repl_worker.js"'],
  ["repl.js", 'from "./host/repl_core.mjs"'],
  ["repl_worker.js", 'from "./host/repl_core.mjs"'],
  ["repl_worker.js", 'fetch("compiler.wasm")'],
  ["repl_worker.js", 'fetch("typecheck.wasm")'],
  ["host/repl_core.mjs", 'from "./wasmhost.mjs"'],
];
for (const [f, ref] of refs) {
  const text = files.get(f);
  if (text.split(ref).length !== 2) throw new Error(`web/build.mjs: ${f} should contain ${ref} once`);
  files.set(f, text.replace(ref, ref.replace(/(\.(?:js|mjs|wasm))"/, `$1?v=${v}"`)));
}

mkdirSync(join(out, "host"), { recursive: true });
for (const [f, data] of files) writeFileSync(join(out, f), data);
writeFileSync(join(out, ".nojekyll"), "");
console.log(`web/build.mjs: ${out} (version ${v}${sha && `, commit ${sha}`})`);
