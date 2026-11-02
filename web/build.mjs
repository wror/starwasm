// build.mjs — assemble the browser REPL as a static site:
//
//   node web/build.mjs [outdir]        (default out/site)
//
// outdir gets web/'s page, the host code it shares with the Node REPL
// (host/wasmhost.mjs, host/repl_core.mjs) and compiler.wasm, the compiler
// compiled to Wasm (host/wasmcache.mjs's default compiler; building it
// needs bin/starhost). Serve outdir with any static file server, e.g.
//   python3 -m http.server -d out/site
// .github/workflows/pages.yml publishes it with GitHub Pages.
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defaultCompiler } from "../host/wasmcache.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const out = resolve(process.argv[2] ?? join(ROOT, "out/site"));
// The site's files: published path -> contents.
const files = new Map();
for (const f of ["index.html", "repl.js", "repl_worker.js"]) files.set(f, readFileSync(join(ROOT, "web", f), "utf8"));
for (const f of ["wasmhost.mjs", "repl_core.mjs"]) files.set(`host/${f}`, readFileSync(join(ROOT, "host", f), "utf8"));
files.set("compiler.wasm", defaultCompiler());

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
  ["repl_worker.js", 'from "./host/repl_core.mjs"'],
  ["repl_worker.js", 'fetch("compiler.wasm")'],
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
console.log(`web/build.mjs: ${out} (version ${v})`);
