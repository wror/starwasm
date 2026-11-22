// repl.mjs — an interactive Starlark session on top of the compiler.
//
//   node host/repl.mjs [--check | --nocheck] [--contagiousnone | --nocontagiousnone]
//                       [--globalreassign] [--globalredefine] [--recursion] [--rollback]
//                       [--descriptor_set=FILE] [compiler.wasm]
//                       (default: compiler/main.star, compiled when needed
//                        by host/wasmcache.mjs, as host/run.mjs does)
//
// --check (the default): each input is type checked before it runs, and
// one with type errors is reported and not run (as after `.check on`);
// --nocheck: inputs are not checked until `.check on`.
// --contagiousnone (the default) and --nocontagiousnone: the "contagious
// None" extension (EXTENSIONS.md), on or off in the whole session, with
// reactive variables or without.
// Otherwise the session is compiled in starlark-go's default dialect, as
// files are: no rebinding a top-level name in a later input (but `_`), no
// while loops, no if/for at top level, no recursion; the other flags turn
// on the compiler's options of the same name (--globalredefine:
// --globalreassign, and a function may be defined again too; --rollback:
// an update in which an error was caught is undone). --descriptor_set=FILE:
// the binary FileDescriptorSet whose .proto files proto.file() opens, as
// for host/run.mjs; the type checker then types the proto module's values
// from it too. Any other option prints this text.
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
//   earlier run again every time (.reset clears them).
// - Blocks (lines ending in ":"), open brackets, open triple-quoted strings
//   and trailing backslashes continue on "..." lines; a block ends with an
//   empty line. In a terminal a "..." line starts with the indentation of
//   the line before it, and one more tab after a line ending in ":"
//   (Session.indent()); backspace removes it.
// - Text pasted from a REPL session (lines starting with the ">>> " prompt;
//   in a terminal with bracketed paste) enters the lines typed there,
//   without their ">>> " and "... " prompts, and not what the REPL printed.
// - Reactive variables (compiler/ext/reactive.star): an input that assigns
//   new values to them (`x : 5`, `x : f(2); y : 2`) is sent to the program
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
// - Types (typecheck/, EXTENSIONS.md "Static types"): `.type expr` prints
//   the type of an expression or name without evaluating it, `.types` the
//   types of everything defined, and while checking is on (--check, the
//   default, or `.check on`) an input with type errors is reported and not
//   run. The checker (typecheck/main.star) is compiled when first needed,
//   and cached like any program.
// - Commands: .help .history .type .types .check .reset .quit (or end of
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
import { pastedInput, Session } from "./repl_core.mjs";

const args = process.argv.slice(2);
const DIALECT_FLAGS = new Set(["--globalreassign", "--globalredefine", "--recursion", "--contagiousnone", "--nocontagiousnone", "--rollback"]);
const CHECK_FLAGS = new Set(["--check", "--nocheck"]);
const isOption = (a) => a.startsWith("-") && a !== "-";
const known = (a) => DIALECT_FLAGS.has(a) || CHECK_FLAGS.has(a) || a.startsWith("--descriptor_set=");
// an unknown option: the usage, which is the comment at the top of this file
if (args.some((a) => isOption(a) && !known(a))) {
  const src = readFileSync(fileURLToPath(import.meta.url), "utf8");
  const usage = src.match(/^(\/\/.*\n)+/)[0].replace(/^\/\/ ?/gm, "");
  const help = args.some((a) => a === "--help" || a === "-h");
  (help ? process.stdout : process.stderr).write(usage);
  process.exit(help ? 0 : 2);
}
const dialectFlags = args.filter((a) => DIALECT_FLAGS.has(a));
// contagious None by default
if (!dialectFlags.includes("--nocontagiousnone") && !dialectFlags.includes("--contagiousnone")) dialectFlags.push("--contagiousnone");
const checking = args.filter((a) => CHECK_FLAGS.has(a)).pop() !== "--nocheck";
const descriptorSet = args.filter((a) => a.startsWith("--descriptor_set=")).map((a) => a.slice("--descriptor_set=".length)).pop();
const otherArgs = args.filter((a) => !known(a));
if (descriptorSet !== undefined && !existsSync(descriptorSet)) {
  console.error(`repl: ${descriptorSet} not found`);
  process.exit(2);
}
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
  descriptorSet,
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
session.checking = checking; // --check (the default) or --nocheck

// ---- input loop

const rl = createInterface({ input: process.stdin, output: interactive ? process.stdout : undefined, terminal: interactive });
let more = false;
let waiting = 0; // lines entered, not yet run
let paste = null; // during a paste: {before: the line it was pasted into, lines: those entered}
const prompt = () => {
  // (after the last of several lines, as pasted: what they print isn't
  // mixed with prompts)
  if (interactive && waiting === 0 && !paste) {
    rl.setPrompt(more ? "... " : ">>> ");
    rl.prompt(true); // (keeping the cursor, in a line typed or pasted meanwhile)
    // a "..." line starts at the block's indent: typed in, so that
    // backspace removes it (unless something was typed or pasted meanwhile)
    if (more && rl.line === "") rl.write(session.indent());
  }
};

if (interactive) say(`starwasm REPL (${compilerPath}); .help for help\n`);
prompt();
// inputs are handled one at a time (running a program is asynchronous)
let busy = Promise.resolve();
function enter(line) {
  waiting++;
  busy = busy.then(async () => {
    const r = await session.feed(line);
    if (r === "quit") process.exit(0);
    more = r === "more";
    waiting--;
    prompt();
  });
}
rl.on("line", (line) => (paste ? paste.lines.push(line) : enter(line)));

// Pasted text is taken as a whole (pastedInput in host/repl_core.mjs: of
// text copied from a REPL session, the lines typed there, without their
// prompts). The terminal marks it, in "bracketed paste" mode, which
// readline reports as the keys paste-start and paste-end; meanwhile the
// lines entered are held back.
if (interactive) {
  say("\x1b[?2004h");
  process.on("exit", () => say("\x1b[?2004l"));
  process.stdin.on("keypress", (_, key) => {
    if (key?.name === "paste-start") {
      // (pasted in the middle of a line: left as it is)
      if (rl.cursor === rl.line.length) paste = { before: rl.line, lines: [] };
    } else if (key?.name === "paste-end" && paste) {
      const { before, lines } = paste;
      paste = null;
      const shown = rl.line;
      const text = [...lines, shown].join("\n").slice(before.length);
      // (lines pasted have their own indentation: not after the block's)
      const typed = ((lines.length && before.trim() === "" ? "" : before) + pastedInput(text)).split("\n");
      const open = typed.pop();
      if (open !== shown) {
        rl.write(null, { ctrl: true, name: "u" });
        rl.write(open);
      }
      if (typed.length && shown !== "") say("\n"); // what they print: below the text pasted
      for (const line of typed) enter(line);
    }
  });
}
rl.on("close", () => {
  busy = busy.then(async () => {
    await session.finish();
    if (interactive) say("\n");
    process.exit(0);
  });
});
