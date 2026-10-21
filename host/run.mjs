// run.mjs — run an export of a compiled module from the command line.
//
//   node host/run.mjs <file.wasm> [export [int args...]] [-- program args...]
//
// The export defaults to "main". Int args are passed to the export (as
// Number, or BigInt for i64 params). Arguments after "--" are what the
// program sees as `argv`. Exit status: 0 ok, 1 Starlark error, 3 internal
// error (Wasm trap). See wasmhost.mjs for the host side.
import { readFileSync, writeSync } from "node:fs";
import { loadModule, runModule } from "./wasmhost.mjs";

const cli = process.argv.slice(2);
const dash = cli.indexOf("--");
const progArgs = dash >= 0 ? cli.slice(dash + 1) : [];
const [file, exportName = "main", ...rawArgs] = dash >= 0 ? cli.slice(0, dash) : cli;
if (!file) {
  console.error("usage: node host/run.mjs <file.wasm> [export [args...]] [-- program args...]");
  process.exit(2);
}

let module;
try {
  module = loadModule(readFileSync(file));
} catch (e) {
  console.error(e.message);
  process.exit(1);
}

process.exitCode = runModule(module, {
  exportName,
  rawArgs,
  progArgs,
  stdout: (bytes) => writeSync(1, bytes),
  stderr: (text) => writeSync(2, text),
});
