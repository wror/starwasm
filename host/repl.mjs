// repl.mjs — an interactive Starlark session on top of the compiler.
//
//   node host/repl.mjs [--globalreassign] [--recursion] [compiler.wasm]
//                       (default: compiler/main.star, compiled when needed
//                        by host/wasmcache.mjs, as host/run.mjs does)
//
// The session is compiled in starlark-go's default dialect, as files are:
// no rebinding a top-level name in a later input (but `_`), no while
// loops, no if/for at top level, no recursion; the flags turn on the
// compiler's options of the same name.
//
// How it works: "replay". The session is the list of inputs accepted so far.
// Each new input is appended, the whole session is recompiled (by the
// self-compiled compiler, in this process) and run, and only the output past
// what earlier inputs printed is shown. Starlark is deterministic and
// hermetic, so replaying reproduces exactly the same state; the only
// exceptions are read_file/write_file, which are replayed too.
//
// - A bare expression prints its repr (unless it is None) and is saved in
//   `_`, as in Python.
// - An input that fails (compile or runtime error) is not added to the
//   session, so the state stays as it was before it.
// - load() paths are relative to the current directory.
// - Each input replays the whole session, so slow computations entered
//   earlier run again every time (:reset clears them).
// - Blocks (lines ending in ":"), open brackets, open triple-quoted strings
//   and trailing backslashes continue on "..." lines; a block ends with an
//   empty line.
// - Reactive variables (compiler/ext/reactive.star): an input that assigns
//   new values to them (`x = 5`, `x = f(2); y = 2`) is sent to the program
//   as a line of standard input, as host/run.mjs would. It joins the session as
//   an update, which replay delivers at the sync point right after the
//   inputs it followed, so later inputs see the new values.
//   No replay is needed for that, though: a session with reactive variables
//   runs in a worker (host/repl_worker.mjs) that stays alive at the end,
//   waiting for input, and an update is just sent to it, without
//   recompiling (a "live" program). If the update fails, the program is
//   dropped, and the next input replays the session. Whenever a reactive
//   variable computed from others is recomputed (to a new value), it is
//   printed as "name = value". An expression that reads reactive variables
//   is evaluated once, like any other.
// - Types (typecheck/, EXTENSIONS.md "Static types"): `:type expr` prints
//   the type of an expression or name without evaluating it, `:types` the
//   types of everything defined, and after `:check on` an input with type
//   errors is reported and not run. The checker (typecheck/main.star) is
//   compiled when first needed, and cached like any program.
// - Commands: :help :history :type :types :check :reset :quit (or end of
//   input).
//
// The session itself is host/repl_core.mjs, shared with the browser REPL
// (web/); this file is its terminal, files and worker threads.
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { MessageChannel, Worker } from "node:worker_threads";
import { loadModule } from "./wasmhost.mjs";
import { fileURLToPath } from "node:url";
import { compileStar, defaultCompiler } from "./wasmcache.mjs";
import { Session } from "./repl_core.mjs";

const DIALECT_FLAGS = new Set(["--globalreassign", "--recursion"]);
const dialectFlags = process.argv.slice(2).filter((a) => DIALECT_FLAGS.has(a));
const otherArgs = process.argv.slice(2).filter((a) => !DIALECT_FLAGS.has(a));
const compilerPath = otherArgs[0] ?? "compiler/main.star";
if (otherArgs[0] !== undefined && !existsSync(compilerPath)) {
  console.error(`repl: ${compilerPath} not found`);
  process.exit(2);
}
let compiler;
try {
  compiler = loadModule(otherArgs[0] !== undefined ? readFileSync(compilerPath) : defaultCompiler());
} catch (e) {
  console.error(`repl: ${e.message}`);
  process.exit(2);
}
// The session file lives in the current directory, so load("x.star", ...)
// resolves the way you'd expect; it is removed on exit.
const dir = mkdtempSync(join(tmpdir(), "starwasm-repl-"));
const sessionPath = `.starwasm-repl-${process.pid}.star`;
process.on("exit", () => {
  rmSync(dir, { recursive: true, force: true });
  rmSync(sessionPath, { force: true });
});

const interactive = process.stdin.isTTY && process.stdout.isTTY;
const say = (s) => process.stdout.write(s);

// Run compiled session bytes in a worker (host/repl_worker.mjs), giving it
// the session's updates. Returns {pending, send, terminate}: pending resolves
// when it is waiting for more input ({idle: true}) or has ended ({status}),
// with what it printed meanwhile (stdout, err); send(line) gives it the next
// line and returns the same kind of promise.
function startProgram(bytes, queue) {
  const { port1, port2 } = new MessageChannel();
  const sab = new SharedArrayBuffer(4);
  const worker = new Worker(new URL("./repl_worker.mjs", import.meta.url), {
    workerData: { bytes, queue, flag: sab, port: port2 },
    transferList: [port2],
    resourceLimits: { stackSizeMb: 256 }, // deep recursion, as host/run.mjs
  });
  let out = [], err = "", settle = null;
  const next = () => new Promise((resolve) => {
    settle = (r) => {
      const res = { ...r, stdout: Buffer.concat(out).toString(), err };
      out = [];
      err = "";
      resolve(res);
    };
  });
  worker.on("message", (m) => {
    if (m.out) out.push(Buffer.from(m.out));
    else if (m.err !== undefined) err += m.err;
    else settle(m.idle ? { idle: true } : { status: m.status });
  });
  worker.on("error", (e) => {
    err += `${e.stack || e}\n`;
    settle({ status: 3 });
  });
  const flag = new Int32Array(sab);
  return {
    pending: next(),
    send(line) {
      const p = next();
      port1.postMessage(line);
      Atomics.store(flag, 0, 1);
      Atomics.notify(flag, 0);
      return p;
    },
    terminate: () => worker.terminate(),
  };
}

const session = new Session({
  compiler,
  dialectFlags,
  sessionPath,
  wasmPath: join(dir, "session.wasm"),
  readFile: (p) => readFileSync(p),
  writeFile: (p, data) => writeFileSync(p, data),
  out: say,
  err: (t) => process.stderr.write(t),
  startProgram,
  // the type checker, compiled by the compiler the REPL uses
  checker: () => loadModule(compileStar(fileURLToPath(new URL("../typecheck/main.star", import.meta.url)), ["--recursion"],
    otherArgs[0] !== undefined ? readFileSync(compilerPath) : null)),
});

// ---- input loop

const rl = createInterface({ input: process.stdin, output: interactive ? process.stdout : undefined, terminal: interactive });
let more = false;
const prompt = () => {
  if (interactive) {
    rl.setPrompt(more ? "... " : ">>> ");
    rl.prompt();
  }
};

if (interactive) say(`starwasm REPL (${compilerPath}); :help for help\n`);
prompt();
// inputs are handled one at a time (running a program is asynchronous)
let busy = Promise.resolve();
rl.on("line", (line) => {
  busy = busy.then(async () => {
    const r = await session.feed(line);
    if (r === "quit") process.exit(0);
    more = r === "more";
    prompt();
  });
});
rl.on("close", () => {
  busy = busy.then(async () => {
    await session.finish();
    if (interactive) say("\n");
    process.exit(0);
  });
});
