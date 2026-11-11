// typecheck.mjs — check the types of Starlark programs (EXTENSIONS.md,
// "Static types").
//
//   node host/typecheck.mjs [--print] <file.star>...
//
// For each program: infers its types, checking them against the
// annotations in <file>.start if that file exists, and writes the
// inferred types to <file>.starit (--print: to standard output instead).
// Type errors go to standard error, as "file:line:col: error: message"
// with the source line; nothing is written then. Exit status: 0 no
// errors, 1 type errors (or a syntax error), 2 usage, 3 internal error.
//
// The checker itself is a Starlark program, typecheck/main.star: this
// runs it compiled to Wasm (cached, as host/run.mjs does for any .star
// program; see wasmcache.mjs). All this file adds is what Starlark can't
// do: a missing .start file reads as an empty one, and the checker's
// final fail() becomes the exit status.
import { existsSync, readFileSync, writeSync } from "node:fs";
import { Worker, isMainThread, parentPort } from "node:worker_threads";
import { fileURLToPath } from "node:url";
import { loadModule, runModule } from "./wasmhost.mjs";
import { CompileError, compileStar } from "./wasmcache.mjs";

// Write all of data to fd: a pipe that is full makes writeSync fail with
// EAGAIN (many diagnostics, a slow reader), so wait and go on.
function write(fd, data) {
  const buf = Buffer.from(data);
  const pause = new Int32Array(new SharedArrayBuffer(4));
  for (let off = 0; off < buf.length; ) {
    try {
      off += writeSync(fd, buf, off);
    } catch (e) {
      if (e.code !== "EAGAIN") throw e;
      Atomics.wait(pause, 0, 0, 10);
    }
  }
}

const CHECKER = fileURLToPath(new URL("../typecheck/main.star", import.meta.url));
const USAGE = "usage: node host/typecheck.mjs [--print] <file.star>...\n";

function main() {
  const args = process.argv.slice(2);
  const options = args.filter((a) => a.startsWith("--"));
  const files = args.filter((a) => !a.startsWith("--"));
  if (files.length === 0 || options.some((a) => a !== "--print")) {
    write(2, USAGE);
    return 2;
  }
  let module;
  try {
    module = loadModule(compileStar(CHECKER, ["--recursion"]));
  } catch (e) {
    write(2, (e instanceof CompileError ? e.message : `typecheck.mjs: ${e.message}`) + "\n");
    return 3;
  }
  let status = 0;
  for (const file of files) {
    if (!existsSync(file)) {
      write(2, `typecheck.mjs: no such file: ${file}\n`);
      status = Math.max(status, 2);
      continue;
    }
    let out = [];
    let err = "";
    const code = runModule(module, {
      progArgs: [...options, "--start=*", file],
      stdout: (bytes) => out.push(Buffer.from(bytes)),
      stderr: (text) => (err += text),
      readFile: (path) => {
        try {
          return readFileSync(path);
        } catch (e) {
          if (e.code === "ENOENT" && path.endsWith(".start")) return new Uint8Array(0);
          throw e;
        }
      },
    });
    const text = Buffer.concat(out);
    if (code === 0) {
      write(1, text);
      continue;
    }
    // The checker ends with fail("typecheck: N type errors in file") after
    // printing them; a syntax error is a fail("file:line:col: message").
    // Anything else is the checker's own failure: show all of it.
    const last = err.trimEnd().split("\n").pop() ?? "";
    const m = /^Error(?: in fail)?: (?:fail: )?(.*)$/.exec(last);
    if (code === 1 && m && /^typecheck: \d+ type error/.test(m[1])) {
      write(2, text);
      write(2, m[1].replace(/^typecheck: /, "") + "\n");
      status = Math.max(status, 1);
    } else if (code === 1 && m && /^[^ ]+:\d+:\d+: /.test(m[1])) {
      write(2, text);
      write(2, m[1] + "\n");
      status = Math.max(status, 1);
    } else {
      write(2, text);
      write(2, err);
      status = 3;
    }
  }
  return status;
}

if (isMainThread) {
  const w = new Worker(new URL(import.meta.url), { argv: process.argv.slice(2), resourceLimits: { stackSizeMb: 256 } });
  w.on("message", (code) => (process.exitCode = code));
  w.on("error", (e) => {
    write(2, `${e.stack || e}\n`);
    process.exitCode = 3;
  });
} else {
  parentPort.postMessage(main());
}
