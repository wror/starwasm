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
import { copyFileSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defaultCompiler } from "../host/wasmcache.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const out = resolve(process.argv[2] ?? join(ROOT, "out/site"));
mkdirSync(join(out, "host"), { recursive: true });
for (const f of ["index.html", "repl.js", "repl_worker.js"]) copyFileSync(join(ROOT, "web", f), join(out, f));
for (const f of ["wasmhost.mjs", "repl_core.mjs"]) copyFileSync(join(ROOT, "host", f), join(out, "host", f));
writeFileSync(join(out, "compiler.wasm"), defaultCompiler());
writeFileSync(join(out, ".nojekyll"), "");
console.log(`web/build.mjs: ${out}`);
