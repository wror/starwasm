// run.mjs — run an export of a compiled module from the command line.
//
//   node host/run.mjs <file.wasm> [export [int args...]] [-- program args...]
//   node host/run.mjs [options] <file.star> [export [int args...]] [-- program args...]
//
// A .star program is compiled first, but only if needed, the way Python
// reuses __pycache__/*.pyc: see wasmcache.mjs (the Wasm is cached in
// __wasmcache__/ next to the source). A compile error is printed as
// "file:line:col: msg", with exit status 1. Options, before the file:
//   --globalreassign, --recursion, --test, --descriptor_set=FILE
//                   the compiler's (compiler/main.star)
//   --compiler=FILE.wasm
//                   compile with this compiler (e.g. out/stage2.wasm);
//                   default: compiler/main.star, itself compiled when needed
//   --compile       only compile (if needed), don't run: as python -m py_compile
//
// The export defaults to "main". Int args are passed to the export (as
// Number, or BigInt for i64 params). Arguments after "--" are what the
// program sees as `argv`. Exit status: 0 ok, 1 Starlark error, 3 internal
// error (Wasm trap). See wasmhost.mjs for the host side.
//
// The module runs in a worker thread with a 256 MB stack: starlark-go
// allows 100,000 nested calls (then "Starlark stack overflow", which the
// compiled code checks itself), far more than the main thread's stack holds.
//
// Programs with reactive variables read standard input line by line
// (synchronously, from the worker: the module runs to completion in one call).
import { readFileSync, readSync, writeSync } from "node:fs";
import { Worker, isMainThread, parentPort } from "node:worker_threads";
import { loadModule, runModule } from "./wasmhost.mjs";
import { CompileError, compileStar } from "./wasmcache.mjs";

// A reader of standard input's lines (without "\n" or "\r\n"); null at the
// end. Input applies after the program's top level: none at sync points
// (before != 0; see compiler/ext/reactive.star).
function stdinLines() {
  const buf = Buffer.alloc(65536);
  let pending = Buffer.alloc(0);
  let eof = false;
  const pause = new Int32Array(new SharedArrayBuffer(4));
  return (before) => {
    if (before !== 0) return null;
    for (;;) {
      const nl = pending.indexOf(10);
      if (nl >= 0 || (eof && pending.length > 0)) {
        let line = pending.subarray(0, nl >= 0 ? nl : pending.length);
        pending = pending.subarray(nl >= 0 ? nl + 1 : pending.length);
        if (line.length > 0 && line[line.length - 1] === 13) line = line.subarray(0, line.length - 1);
        return Buffer.from(line);
      }
      if (eof) return null;
      let n;
      try {
        n = readSync(0, buf, 0, buf.length, null);
      } catch (e) {
        if (e.code === "EAGAIN") { // non-blocking stdin with nothing yet
          Atomics.wait(pause, 0, 0, 20);
          continue;
        }
        if (e.code === "EOF") n = 0;
        else throw e;
      }
      if (n === 0) eof = true;
      else pending = Buffer.concat([pending, buf.subarray(0, n)]);
    }
  };
}

const USAGE = `usage: node host/run.mjs <file.wasm> [export [args...]] [-- program args...]
       node host/run.mjs [--globalreassign] [--recursion] [--test] [--descriptor_set=FILE]
                         [--compiler=FILE.wasm] [--compile] <file.star> [export [args...]] [-- program args...]
`;

function main() {
  const cli = process.argv.slice(2);
  const dash = cli.indexOf("--");
  const progArgs = dash >= 0 ? cli.slice(dash + 1) : [];
  const before = dash >= 0 ? cli.slice(0, dash) : cli;
  const flags = []; // the compiler's options
  let compiler = null;
  let compileOnly = false;
  let i = 0;
  for (; i < before.length && before[i].startsWith("--"); i++) {
    const a = before[i];
    if (a === "--globalreassign" || a === "--recursion" || a === "--test" || a.startsWith("--descriptor_set=")) {
      if (!flags.includes(a)) flags.push(a);
    }
    else if (a.startsWith("--compiler=")) compiler = a.slice("--compiler=".length);
    else if (a === "--compile") compileOnly = true;
    else {
      writeSync(2, `run.mjs: unknown option ${a}\n${USAGE}`);
      return 2;
    }
  }
  const [file, exportName = "main", ...rawArgs] = before.slice(i);
  const star = file?.endsWith(".star");
  if (!file || (!star && (flags.length || compiler || compileOnly))) {
    writeSync(2, file ? `run.mjs: options are for .star files\n${USAGE}` : USAGE);
    return 2;
  }
  let module;
  try {
    const bytes = star ? compileStar(file, flags, compiler && readFileSync(compiler)) : readFileSync(file);
    if (compileOnly) return 0;
    module = loadModule(bytes);
  } catch (e) {
    writeSync(2, (e instanceof CompileError ? e.message : `run.mjs: ${e.message}`) + "\n");
    return 1;
  }
  return runModule(module, {
    exportName,
    rawArgs,
    progArgs,
    stdout: (bytes) => writeSync(1, bytes),
    stderr: (text) => writeSync(2, text),
    readLine: stdinLines(),
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
