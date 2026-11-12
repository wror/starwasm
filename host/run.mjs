// run.mjs — run an export of a compiled module from the command line.
//
//   node host/run.mjs <file.wasm> [export [int args...]] [-- program args...]
//   node host/run.mjs [options] <file.star> [export [int args...]] [-- program args...]
//
// A .star program is compiled first, but only if needed, the way Python
// reuses __pycache__/*.pyc: see wasmcache.mjs (the Wasm is cached in
// __wasmcache__/ next to the source). A compile error is printed as
// "file:line:col: msg", with exit status 1. Options, before the file:
//   --globalreassign, --recursion, --test, --descriptor_set=FILE,
//   --contagiousnone, --nocontagiousnone
//                   the compiler's (compiler/main.star)
//   --compiler=FILE.wasm
//                   compile with this compiler (e.g. out/stage2.wasm);
//                   default: compiler/main.star, itself compiled when needed
//   --compile       only compile (if needed), don't run: as python -m py_compile
//   --journal=FILE  (also for .wasm files) a program with reactive variables
//                   appends each line of standard input to FILE before
//                   applying it, and on start replays FILE's lines first,
//                   so a restarted program gets back its state (see
//                   journaled() below)
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
import {
  closeSync, fstatSync, fsyncSync, ftruncateSync, openSync, readFileSync, readSync, writeSync,
} from "node:fs";
import { dirname } from "node:path";
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

// readLine (as from stdinLines) with a journal in the file at path:
// opened (created if needed) at the first line asked for, which happens
// only in programs with reactive variables. First come the journal's
// valid lines, then readLine's, each appended to the journal (with "\n")
// and synced to disk before it's returned, i.e. before it's applied.
// A line is valid only if it ends with "\n": a write is atomic only up
// to a prefix, so a line cut short by a crash (or a failed write) lacks
// its "\n". Such a tail is dropped from the file before anything is
// appended, so it can't join a later line. If a line can't be journaled,
// the journal is cut back to its last valid line and the program stops
// (an internal error) without applying it: an update applied but not
// journaled would be lost on restart.
function journaled(path, readLine) {
  let fd = -1;
  let size = 0; // bytes of valid lines in the journal
  let replay = [];
  const sync = (what) => {
    try {
      fsyncSync(what);
    } catch (e) {
      if (e.code !== "EINVAL" && e.code !== "EISDIR" && e.code !== "EBADF") throw e;
    }
  };
  const open = () => {
    let created = false;
    try {
      fd = openSync(path, "r+");
    } catch (e) {
      if (e.code !== "ENOENT") throw e;
      fd = openSync(path, "wx+");
      created = true;
    }
    const data = Buffer.alloc(fstatSync(fd).size);
    for (let off = 0; off < data.length; ) {
      const n = readSync(fd, data, off, data.length - off, off);
      if (n === 0) break;
      off += n;
    }
    size = data.lastIndexOf(10) + 1;
    if (size < data.length) {
      ftruncateSync(fd, size);
      sync(fd);
    }
    if (created) { // make the new file's directory entry durable too
      let dir = -1;
      try {
        dir = openSync(dirname(path), "r");
        sync(dir);
      } catch (e) {
        if (e.code !== "EISDIR" && e.code !== "EPERM" && e.code !== "EACCES") throw e;
      } finally {
        if (dir >= 0) closeSync(dir);
      }
    }
    const text = data.subarray(0, size);
    for (let at = 0; at < text.length; ) {
      const nl = text.indexOf(10, at);
      replay.push(Buffer.from(text.subarray(at, nl)));
      at = nl + 1;
    }
    replay.reverse(); // pop() takes the first
  };
  const append = (line) => {
    const rec = Buffer.concat([line, Buffer.from("\n")]);
    try {
      for (let off = 0; off < rec.length; ) off += writeSync(fd, rec, off, rec.length - off, size + off);
      fsyncSync(fd);
    } catch (e) {
      try {
        ftruncateSync(fd, size);
        fsyncSync(fd);
      } catch {} // the restart drops the tail anyway, unless it's complete
      throw new Error(`journal ${path}: ${e.message} (the line was not applied)`);
    }
    size += rec.length;
  };
  return (before) => {
    if (before !== 0) return null; // nothing due at sync points
    if (fd < 0) open();
    if (replay.length > 0) return replay.pop();
    const line = readLine(before);
    if (line !== null) {
      if (line.includes(10)) throw new Error(`journal ${path}: a line can't contain "\\n"`);
      append(line);
    }
    return line;
  };
}

const USAGE = `usage: node host/run.mjs [--journal=FILE] <file.wasm> [export [args...]] [-- program args...]
       node host/run.mjs [--journal=FILE] [--globalreassign] [--recursion] [--test] [--descriptor_set=FILE]
                         [--contagiousnone | --nocontagiousnone] [--compiler=FILE.wasm] [--compile] <file.star> [export [args...]] [-- program args...]
`;

function main() {
  const cli = process.argv.slice(2);
  const dash = cli.indexOf("--");
  const progArgs = dash >= 0 ? cli.slice(dash + 1) : [];
  const before = dash >= 0 ? cli.slice(0, dash) : cli;
  const flags = []; // the compiler's options
  let compiler = null;
  let compileOnly = false;
  let journal = null;
  let i = 0;
  for (; i < before.length && before[i].startsWith("--"); i++) {
    const a = before[i];
    if (a === "--globalreassign" || a === "--recursion" || a === "--test" || a === "--contagiousnone" || a === "--nocontagiousnone" || a.startsWith("--descriptor_set=")) {
      if (!flags.includes(a)) flags.push(a);
    }
    else if (a.startsWith("--compiler=")) compiler = a.slice("--compiler=".length);
    else if (a === "--compile") compileOnly = true;
    else if (a.startsWith("--journal=") && a.length > "--journal=".length) journal = a.slice("--journal=".length);
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
    readLine: journal ? journaled(journal, stdinLines()) : stdinLines(),
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
