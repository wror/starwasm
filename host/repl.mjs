// repl.mjs — an interactive Starlark session on top of the compiler.
//
//   node host/repl.mjs [compiler.wasm]      (default: out/stage2.wasm)
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
//   literals to them (`x = 5`, `x = 1; y = 2`) is sent to the program as a
//   line of standard input, as host/run.mjs would. It joins the session as
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
// - Commands: :help :history :reset :quit (or end of input).
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { MessageChannel, Worker } from "node:worker_threads";
import { loadModule, runModule } from "./wasmhost.mjs";

const compilerPath = process.argv[2] ?? "out/stage2.wasm";
if (!existsSync(compilerPath)) {
  console.error(`repl: ${compilerPath} not found. Build the self-compiled compiler first:
  bin/starhost compiler/main.star compiler/main.star out/stage1.wasm
  node host/run.mjs out/stage1.wasm -- compiler/main.star out/stage2.wasm
(or run ./test.sh, which builds it).`);
  process.exit(2);
}
const compiler = loadModule(readFileSync(compilerPath));
// The session file lives in the current directory, so load("x.star", ...)
// resolves the way you'd expect; it is removed on exit.
const dir = mkdtempSync(join(tmpdir(), "starwasm-repl-"));
const sessionPath = `.starwasm-repl-${process.pid}.star`;
const wasmPath = join(dir, "session.wasm");
process.on("exit", () => {
  rmSync(dir, { recursive: true, force: true });
  rmSync(sessionPath, { force: true });
});

const interactive = process.stdin.isTTY && process.stdout.isTTY;
const say = (s) => process.stdout.write(s);

// ---- the session

// Accepted inputs: code {src: as typed, code: as compiled, offset: line in
// `code` where the user's text starts}, or updates of reactive variables
// {src, update: true}, sent as standard input.
let history = [];
let printed = ""; // stdout of the session so far

const codeOf = (entries) => entries.filter((c) => !c.update);

function sessionCode(chunks) {
  return codeOf(chunks).map((c) => c.code).join("\n") + "\n";
}

// Standard input for a replay: each update is due at the first sync point
// past the code entered before it (read_line's `before` in wasmhost.mjs).
function updateQueue(entries) {
  const queue = [];
  let lines = 0; // lines of code so far
  for (const c of entries) {
    if (c.update) queue.push({ c, after: lines });
    else lines += c.code.split("\n").length;
  }
  return queue;
}

// Map a position in the session file back to "<input N>:line:col".
function mapPositions(text, entries) {
  const chunks = codeOf(entries);
  const updates = entries.filter((c) => c.update);
  text = text.replace(/<stdin>:(\d+):(\d+)/g, (all, n, col) =>
    updates[n - 1] ? `<input ${updates[n - 1].num}>:1:${col}` : all);
  const re = new RegExp(`${sessionPath.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}:(\\d+):(\\d+)`, "g");
  return text.replace(re, (_, ln, col) => {
    let line = Number(ln);
    for (let i = 0; i < chunks.length; i++) {
      const n = chunks[i].code.split("\n").length;
      if (line <= n) {
        const userLine = Math.max(1, line - chunks[i].offset);
        return `<input ${chunks[i].num}>:${userLine}:${col}`;
      }
      line -= n;
    }
    return `<repl>:${ln}:${col}`;
  });
}

// The program of the current session, alive and waiting for input (see
// startProgram), or null.
let live = null;

// Run compiled session bytes in a worker (host/repl_worker.mjs), giving it
// the session's updates. Returns {worker, pending, send}: pending resolves
// when it is waiting for more input ({idle: true}) or has ended ({status}),
// with what it printed meanwhile (stdout, err); send(line) gives it the next
// line and returns the same kind of promise.
function startProgram(bytes, queue) {
  const { port1, port2 } = new MessageChannel();
  const sab = new SharedArrayBuffer(4);
  const worker = new Worker(new URL("./repl_worker.mjs", import.meta.url), {
    workerData: { bytes, queue: queue.map((q) => ({ src: q.c.src, after: q.after })), flag: sab, port: port2 },
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
  const prog = {
    worker,
    pending: next(),
    send(line) {
      const p = next();
      port1.postMessage(line);
      Atomics.store(flag, 0, 1);
      Atomics.notify(flag, 0);
      return p;
    },
  };
  return prog;
}

// Compile and run chunks; returns {ok, stdout, error}, and prog: the live
// program if the session has reactive variables (else the program has run
// to its end in this thread).
async function run(chunks) {
  writeFileSync(sessionPath, sessionCode(chunks));
  let cerr = "";
  const status = runModule(compiler, {
    progArgs: [sessionPath, wasmPath],
    stderr: (t) => (cerr += t),
  });
  if (status !== 0) {
    // The compiler reports "Error in fail: fail: <file>:L:C: msg" after a
    // traceback through its own source; show just the message.
    const m = /Error in fail: fail: (.*)/.exec(cerr);
    return { ok: false, compile: true, stdout: "", error: mapPositions(m ? m[1] : cerr.trim(), chunks) + "\n" };
  }
  const queue = updateQueue(chunks);
  if (reactiveNames(chunks).size > 0) {
    const prog = startProgram(readFileSync(wasmPath), queue);
    const r = await prog.pending;
    const ok = (r.idle || r.status === 0) && r.err === "";
    if (!ok || !r.idle) prog.worker.terminate();
    return { ok, compile: false, stdout: r.stdout, error: mapPositions(r.err, chunks), prog: ok && r.idle ? prog : null };
  }
  const out = [];
  let err = "";
  const rs = runModule(loadModule(readFileSync(wasmPath)), {
    stdout: (b) => out.push(Buffer.from(b)),
    stderr: (t) => (err += t),
    readLine: (before) =>
      queue.length && (before === 0 || queue[0].after < before) ? Buffer.from(queue.shift().c.src) : null,
  });
  // an update that fails is reported on stderr while the program goes on;
  // an accepted session writes nothing there
  return { ok: rs === 0 && err === "", compile: false, stdout: Buffer.concat(out).toString(), error: mapPositions(err, chunks) };
}

// ---- classifying input

const STATEMENT_KEYWORDS = new Set(["def", "if", "for", "while", "load", "return", "pass", "break", "continue", "elif", "else"]);

// Scan Starlark text: bracket depth, open triple quote, top-level "=".
function scan(text) {
  let depth = 0, quote = null, assign = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote) {
      if (c === "\\") { i++; continue; }
      if (text.startsWith(quote, i)) { i += quote.length - 1; quote = null; }
      else if (quote.length === 1 && c === "\n") quote = null; // unterminated; let the compiler say so
      continue;
    }
    if (c === "#") { while (i < text.length && text[i] !== "\n") i++; continue; }
    if (c === '"' || c === "'") { quote = text.startsWith(c.repeat(3), i) ? c.repeat(3) : c; i += quote.length - 1; continue; }
    if ("([{".includes(c)) depth++;
    else if (")]}".includes(c)) depth--;
    else if (c === "=" && depth === 0) {
      const prev = text[i - 1], next = text[i + 1];
      if (next !== "=" && !"=!<>".includes(prev ?? "")) assign = true; // =, +=, -=, ...
      if (next === "=") i++;
    }
  }
  return { depth, tripleOpen: quote !== null && quote.length === 3, assign };
}

function needsMore(text) {
  const { depth, tripleOpen } = scan(text);
  if (depth > 0 || tripleOpen || /\\\s*$/.test(text)) return true;
  const lines = text.split("\n");
  const first = lines[0].replace(/#.*$/, "").trimEnd();
  if (first.endsWith(":")) return lines[lines.length - 1].trim() !== ""; // block: ends with an empty line
  return false;
}

function looksLikeStatement(src) {
  const word = /^\s*([A-Za-z_]\w*)/.exec(src);
  if (word && STATEMENT_KEYWORDS.has(word[1])) return true;
  if (src.split("\n")[0].replace(/#.*$/, "").trimEnd().endsWith(":")) return true; // a block
  return scan(src).assign;
}

// Reactive definitions in Starlark text: `name : ...` starting a top-level
// statement (a line at column 0, outside brackets and strings). Returns
// [{name, rest}], rest being the text of the definition after the ":".
const NOT_NAMES = new Set([...STATEMENT_KEYWORDS, "lambda", "not"]);
function reactiveDefs(text) {
  const starts = []; // where top-level statements start
  let depth = 0, quote = null;
  for (let i = 0; i < text.length; i++) {
    if ((i === 0 || text[i - 1] === "\n") && depth === 0 && !quote && /[^\s#]/.test(text[i] ?? "")) starts.push(i);
    const ch = text[i];
    if (quote) {
      if (ch === "\\") { i++; continue; }
      if (text.startsWith(quote, i)) { i += quote.length - 1; quote = null; }
      else if (quote.length === 1 && ch === "\n") quote = null;
      continue;
    }
    if (ch === "#") { while (i + 1 < text.length && text[i + 1] !== "\n") i++; continue; }
    if (ch === '"' || ch === "'") { quote = text.startsWith(ch.repeat(3), i) ? ch.repeat(3) : ch; i += quote.length - 1; continue; }
    if ("([{".includes(ch)) depth++;
    else if (")]}".includes(ch)) depth--;
  }
  const defs = [];
  starts.forEach((at, k) => {
    const stmt = text.slice(at, k + 1 < starts.length ? starts[k + 1] : text.length);
    const m = /^([A-Za-z_]\w*)[ \t]*:/.exec(stmt);
    if (m && !NOT_NAMES.has(m[1])) defs.push({ name: m[1], rest: stmt.slice(m[0].length) });
  });
  return defs;
}

function reactiveNames(entries) {
  return new Set(codeOf(entries).flatMap((c) => reactiveDefs(c.code).map((d) => d.name)));
}

// The code for a statement input. After each definition of a reactive
// variable computed from others (b : a + 10), a hidden observer prints
// "b = <value>" whenever b is recomputed (to a new value), but not when
// it is first defined. (Variables defined by literals change only when
// assigned, and an assignment isn't echoed.)
function statementCode(src, num, names) {
  let code = src.replace(/\s+$/, "");
  const known = new Set(names);
  for (const { name, rest } of reactiveDefs(code)) {
    const derived = (rest.match(/[A-Za-z_]\w*/g) ?? []).some((w) => w !== name && known.has(w));
    known.add(name);
    if (!derived) continue;
    const seen = `_shown${num}_${name}`;
    code += `\n${seen} = []\n` +
      `(lambda v, seen: (print(${JSON.stringify(name + " = ")} + repr(v)) if seen else None, seen.append(True)))(${name}, ${seen})`;
  }
  return { code, offset: 0 };
}

// `x = literal...` (or `x : ...`) on one line, x a reactive variable: an
// update, for the program's standard input.
function isUpdate(src, names) {
  const t = src.trim();
  const m = /^([A-Za-z_]\w*)\s*(=(?!=)|:)/.exec(t);
  return !t.includes("\n") && m !== null && names.has(m[1]);
}

// The code for an expression input: evaluate into `_`, print its repr.
function echoCode(src) {
  return { code: `_ = (\n${src}\n)\nif _ != None: print(repr(_))`, offset: 1 };
}

// An expression reading reactive variables can't be saved in `_` (a plain
// variable would go stale), and it is evaluated only once: as a top-level
// expression statement it is an observer, so _once<N> makes its later
// runs skip it.
function onceCode(src, num) {
  const once = `_once${num}`;
  return {
    code: `${once} = []\n` +
      `None if ${once} else (lambda v: (${once}.append(True), None if v == None else print(repr(v))))(\n${src}\n)`,
    offset: 2,
  };
}

// ---- one input

let inputNum = 0;

async function submit(src) {
  if (src.trim() === "") return;
  const num = ++inputNum;
  const candidates = [];
  if (isUpdate(src, reactiveNames(history))) {
    const c = { src: src.trim(), num, update: true };
    if (live) {
      // the program is waiting for input: just send it the line
      const r = await live.send(c.src);
      say(r.stdout);
      if (r.idle && r.err === "") {
        history.push(c);
        printed += r.stdout;
      } else {
        process.stderr.write(mapPositions(r.err, [...history, c]));
        live.worker.terminate(); // its state may differ from the session's now
        live = null;
      }
      return;
    }
    candidates.push(c); // replay, which starts a live program
  } else if (!looksLikeStatement(src)) {
    candidates.push({ src, num, ...echoCode(src) });
    candidates.push({ src, num, ...onceCode(src, num) });
  }
  if (!candidates.length || !candidates[0].update) candidates.push({ src, num, ...statementCode(src, num, reactiveNames(history)) });

  let result;
  for (let i = 0; i < candidates.length; i++) {
    const c = candidates[i];
    result = await run([...history, c]);
    // `x = 5` with x reactive: send it to the program as standard input
    if (!result.ok && result.compile && i === candidates.length - 1 && !src.trim().includes("\n") &&
        result.error.includes("cannot assign to reactive variable")) {
      candidates.push({ src: src.trim(), num, update: true });
      continue;
    }
    // An expression wrapper that doesn't compile: try the next form.
    if (!result.ok && result.compile && i < candidates.length - 1) continue;
    if (result.ok) {
      history.push(c);
    }
    break;
  }
  const out = result.stdout.startsWith(printed) ? result.stdout.slice(printed.length) : result.stdout;
  say(out);
  if (result.ok) {
    printed = result.stdout;
    if (live) live.worker.terminate(); // it ran the session without this input
    live = result.prog;
  } else process.stderr.write(result.error);
}

function command(line) {
  const cmd = line.trim();
  if (cmd === ":quit" || cmd === ":q") process.exit(0);
  if (cmd === ":reset") {
    if (live) live.worker.terminate();
    live = null;
    history = [];
    printed = "";
    say("session cleared\n");
  } else if (cmd === ":history") {
    for (const c of history) say(`# <input ${c.num}>${c.update ? " (update)" : ""}\n${c.src.replace(/\s+$/, "")}\n`);
  } else {
    say(`Starlark REPL on the starwasm compiler. Each input recompiles and replays the
session (Starlark is deterministic, so the state is exactly reproduced).
  expression      prints its repr and sets _
  :history        show the inputs so far
  :reset          start over
  :quit           exit (or end of input)
  x = 5           with x reactive (x : ...): sent to the program as input
Blocks, open brackets and triple-quoted strings continue on "..." lines;
end a block with an empty line. A failing input is not kept.
`);
  }
}

// ---- input loop

const rl = createInterface({ input: process.stdin, output: interactive ? process.stdout : undefined, terminal: interactive });
let buffer = [];
const prompt = () => {
  if (interactive) {
    rl.setPrompt(buffer.length ? "... " : ">>> ");
    rl.prompt();
  }
};

if (interactive) say(`starwasm REPL (${compilerPath}); :help for help\n`);
prompt();
// inputs are handled one at a time (running a program is asynchronous)
let busy = Promise.resolve();
rl.on("line", (line) => {
  busy = busy.then(async () => {
    if (buffer.length === 0 && line.trim().startsWith(":")) {
      command(line);
    } else {
      buffer.push(line);
      const text = buffer.join("\n");
      if (!needsMore(text)) {
        buffer = [];
        await submit(text);
      }
    }
    prompt();
  });
});
rl.on("close", () => {
  busy = busy.then(async () => {
    if (buffer.length) await submit(buffer.join("\n"));
    if (interactive) say("\n");
    process.exit(0);
  });
});
