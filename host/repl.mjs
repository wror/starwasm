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
// - Commands: :help :history :reset :quit (or end of input).
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
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

// Accepted inputs: {src: as typed, code: as compiled, offset: line in `code`
// where the user's text starts}.
let history = [];
let printed = ""; // stdout of the session so far

function sessionCode(chunks) {
  return chunks.map((c) => c.code).join("\n") + "\n";
}

// Map a position in the session file back to "<input N>:line:col".
function mapPositions(text, chunks) {
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

// Compile and run chunks; returns {ok, stdout, error}.
function run(chunks) {
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
  const out = [];
  let err = "";
  const rs = runModule(loadModule(readFileSync(wasmPath)), {
    stdout: (b) => out.push(Buffer.from(b)),
    stderr: (t) => (err += t),
  });
  return { ok: rs === 0, compile: false, stdout: Buffer.concat(out).toString(), error: mapPositions(err, chunks) };
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

// The code for an expression input: evaluate into `_`, print its repr.
function echoCode(src) {
  return { code: `_ = (\n${src}\n)\nif _ != None: print(repr(_))`, offset: 1 };
}

// ---- one input

let inputNum = 0;

function submit(src) {
  if (src.trim() === "") return;
  const num = ++inputNum;
  const candidates = [];
  if (!looksLikeStatement(src)) candidates.push({ src, num, ...echoCode(src) });
  candidates.push({ src, num, code: src.replace(/\s+$/, ""), offset: 0 });

  let result;
  for (const c of candidates) {
    result = run([...history, c]);
    // An expression wrapper that doesn't compile: try it as a statement.
    if (!result.ok && result.compile && c !== candidates[candidates.length - 1]) continue;
    if (result.ok) {
      history.push(c);
    }
    break;
  }
  const out = result.stdout.startsWith(printed) ? result.stdout.slice(printed.length) : result.stdout;
  say(out);
  if (result.ok) printed = result.stdout;
  else process.stderr.write(result.error);
}

function command(line) {
  const cmd = line.trim();
  if (cmd === ":quit" || cmd === ":q") process.exit(0);
  if (cmd === ":reset") {
    history = [];
    printed = "";
    say("session cleared\n");
  } else if (cmd === ":history") {
    for (const c of history) say(`# <input ${c.num}>\n${c.src.replace(/\s+$/, "")}\n`);
  } else {
    say(`Starlark REPL on the starwasm compiler. Each input recompiles and replays the
session (Starlark is deterministic, so the state is exactly reproduced).
  expression      prints its repr and sets _
  :history        show the inputs so far
  :reset          start over
  :quit           exit (or end of input)
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
rl.on("line", (line) => {
  if (buffer.length === 0 && line.trim().startsWith(":")) {
    command(line);
  } else {
    buffer.push(line);
    const text = buffer.join("\n");
    if (!needsMore(text)) {
      buffer = [];
      submit(text);
    }
  }
  prompt();
});
rl.on("close", () => {
  if (buffer.length) submit(buffer.join("\n"));
  if (interactive) say("\n");
  process.exit(0);
});
