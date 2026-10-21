// run.mjs — run an export of a compiled module from the command line.
//
//   node host/run.mjs <file.wasm> [export [int args...]] [-- program args...]
//
// The export defaults to "main". Int args are passed to the export (as
// Number, or BigInt for i64 params). Arguments after "--" are what the
// program sees as `argv`. Exit status: 0 ok, 1 Starlark error, 3 internal
// error (Wasm trap). See wasmhost.mjs for the host side.
//
// The module runs in a worker thread with a 256 MB stack: starlark-go
// allows 100,000 nested calls (then "Starlark stack overflow", which the
// compiled code checks itself), far more than the main thread's stack holds.
import { readFileSync, writeSync } from "node:fs";
import { Worker, isMainThread, parentPort } from "node:worker_threads";
import { loadModule, runModule } from "./wasmhost.mjs";

function main() {
  const cli = process.argv.slice(2);
  const dash = cli.indexOf("--");
  const progArgs = dash >= 0 ? cli.slice(dash + 1) : [];
  const [file, exportName = "main", ...rawArgs] = dash >= 0 ? cli.slice(0, dash) : cli;
  if (!file) {
    writeSync(2, "usage: node host/run.mjs <file.wasm> [export [args...]] [-- program args...]\n");
    return 2;
  }
  let module;
  try {
    module = loadModule(readFileSync(file));
  } catch (e) {
    writeSync(2, e.message + "\n");
    return 1;
  }
  return runModule(module, {
    exportName,
    rawArgs,
    progArgs,
    stdout: (bytes) => writeSync(1, bytes),
    stderr: (text) => writeSync(2, text),
  });
}

if (isMainThread) {
  const w = new Worker(new URL(import.meta.url), { argv: process.argv.slice(2), resourceLimits: { stackSizeMb: 256 } });
  w.on("message", (code) => (process.exitCode = code));
  w.on("error", (e) => {
    writeSync(2, `${e.stack || e}\n`);
    process.exitCode = 3;
  });
} else {
  parentPort.postMessage(main());
}
