// repl_core.mjs — the REPL's session (see host/repl.mjs for how it works),
// independent of where it runs: host/repl.mjs drives it from a terminal in
// Node, web/repl_worker.js from a web page. It uses no Node-only API: the
// host gives it file access and, optionally, a way to keep a program alive.
import { loadModule, runModule } from "./wasmhost.mjs";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const concatText = (chunks) => {
  const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.length;
  }
  return decoder.decode(out);
};

export const HELP = `Starlark REPL on the starwasm compiler. Each input recompiles and replays the
session (Starlark is deterministic, so the state is exactly reproduced).
  expression      prints its repr and sets _
  :history        show the inputs so far
  :reset          start over
  :quit           exit (or end of input)
  x = 5           with x reactive (x : ...): sent to the program as input
Blocks, open brackets and triple-quoted strings continue on "..." lines;
end a block with an empty line. A failing input is not kept.
`;

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

/** Whether text (the lines typed so far) needs more lines. */
export function needsMore(text) {
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

// Reactive definitions in Starlark text: `name : ...` (or `a name :` /
// `an name :` / `a name when cond :`, a relation) starting a top-level statement (a line at column
// 0, outside brackets and strings). Returns [{name, rest, relation}], rest
// being the text of the definition after its name.
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
    // (`a name when cond:`: the ":" ending the first line)
    const m = /^(an?[ \t]+)?([A-Za-z_]\w*)[ \t]*:/.exec(stmt) ??
      /^(an?[ \t]+)([A-Za-z_]\w*)(?=[ \t]+when\b)[^\n]*:[ \t]*(?:#[^\n]*)?(?=\n|$)/.exec(stmt);
    if (m && !NOT_NAMES.has(m[2])) defs.push({ name: m[2], rest: stmt.slice((m[1] ?? "").length + m[2].length), relation: m[1] !== undefined });
  });
  return defs;
}

const codeOf = (entries) => entries.filter((c) => !c.update);

function reactiveNames(entries) {
  return new Set(codeOf(entries).flatMap((c) => reactiveDefs(c.code).map((d) => d.name)));
}

// The code for a statement input. After each definition of a reactive
// variable computed from others (b : a + 10), a hidden observer prints
// "b = <value>" whenever b is recomputed (to a new value), but not when
// it is first defined. (Variables defined by literals change only when
// assigned, and an assignment isn't echoed.) For a relation (an x: ...),
// the observer reads the list of members, and prints the one just added,
// which is last. The observer may first run after the definition (for a
// variable computed from a relation, once the relation has a member), so
// `seen` is set by a plain statement, which runs once, at the definition.
function statementCode(src, num, names) {
  let code = src.replace(/\s+$/, "");
  const known = new Set(names);
  for (const { name, rest, relation } of reactiveDefs(code)) {
    const derived = (rest.match(/[A-Za-z_]\w*/g) ?? []).some((w) => w !== name && known.has(w));
    known.add(name);
    if (!derived) continue;
    const seen = `_shown${num}_${name}`;
    const shown = JSON.stringify(name + " = ");
    code += `\n${seen} = []\n` + (relation
      ? `(lambda v, seen: print(${shown} + repr(v[-1])) if seen and v else None)(${name}, ${seen})`
      : `(lambda v, seen: print(${shown} + repr(v)) if seen else None)(${name}, ${seen})`) +
      `\n${seen}.append(True)`;
  }
  return { code, offset: 0 };
}

// `x = expression...` (or `x : ...`) on one line, x a reactive variable: an
// update, for the program's standard input.
function isUpdate(src, names) {
  const t = src.trim();
  const m = /^([A-Za-z_]\w*)\s*(=(?!=)|:)/.exec(t);
  return !t.includes("\n") && m !== null && names.has(m[1]);
}

// The code for an expression input: evaluate into `_`, print its repr.
function echoCode(src) {
  // (a conditional expression: no `if` at top level in the default dialect)
  return { code: `_ = (\n${src}\n)\nprint(repr(_)) if _ != None else None`, offset: 1 };
}

// An expression reading reactive variables can't be saved in `_` (a plain
// variable would go stale), and it is evaluated only once: as a top-level
// expression statement it is an observer, so _once<N>, set by the plain
// statement after it, makes its later runs skip it. (If it reads a variable
// not set yet, computed from a relation with no member, it is skipped at
// first too, so it prints nothing.)
function onceCode(src, num) {
  const once = `_once${num}`;
  return {
    code: `${once} = []\n` +
      `None if ${once} else (lambda v: None if v == None else print(repr(v)))(\n${src}\n)\n${once}.append(True)`,
    offset: 2,
  };
}

// ---- the session

/**
 * A REPL session.
 *   compiler      the compiler (a WebAssembly.Module)
 *   dialectFlags  compiler options (--globalreassign, --recursion)
 *   sessionPath   the file the session is compiled from (load() paths are
 *                 relative to it); wasmPath: where the compiler writes
 *   readFile(path) -> Uint8Array, writeFile(path, bytes): file access, for
 *                 the compiler and the session's program
 *   out(text), err(text): the session's standard output and error
 *   startProgram(bytes, queue) (optional): run a program with reactive
 *                 variables so that it stays alive at its end, waiting for
 *                 input (host/repl.mjs). Without it, such a program runs to
 *                 its end like any other, and each update replays the
 *                 session.
 */
export class Session {
  constructor(opts) {
    Object.assign(this, opts);
    this.dialectFlags ??= [];
    this.history = []; // accepted inputs (see below)
    this.printed = ""; // stdout of the session so far
    this.live = null; // the program of the session, alive (see startProgram)
    this.inputNum = 0;
    this.buffer = []; // lines of an unfinished input
  }

  // Accepted inputs: code {src: as typed, code: as compiled, offset: line in
  // `code` where the user's text starts}, or updates of reactive variables
  // {src, update: true}, sent as standard input.

  // Map a position in the session file back to "<input N>:line:col".
  mapPositions(text, entries) {
    const chunks = codeOf(entries);
    const updates = entries.filter((c) => c.update);
    text = text.replace(/<stdin>:(\d+):(\d+)/g, (all, n, col) =>
      updates[n - 1] ? `<input ${updates[n - 1].num}>:1:${col}` : all);
    const re = new RegExp(`${this.sessionPath.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}:(\\d+):(\\d+)`, "g");
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

  // Compile and run chunks; returns {ok, stdout, error}, and prog: the live
  // program if the session has reactive variables (and the host can keep it
  // alive; else the program has run to its end).
  async run(chunks) {
    const code = codeOf(chunks).map((c) => c.code).join("\n") + "\n";
    this.writeFile(this.sessionPath, encoder.encode(code));
    let cerr = "";
    const status = runModule(this.compiler, {
      progArgs: ["--repl", ...this.dialectFlags, this.sessionPath, this.wasmPath], // --repl: `_` may be rebound
      stderr: (t) => (cerr += t),
      readFile: this.readFile,
      writeFile: this.writeFile,
    });
    if (status !== 0) {
      // The compiler reports "Error in fail: fail: <file>:L:C: msg" after a
      // traceback through its own source; show just the message.
      const m = /Error in fail: fail: (.*)/.exec(cerr);
      return { ok: false, compile: true, stdout: "", error: this.mapPositions(m ? m[1] : cerr.trim(), chunks) + "\n" };
    }
    // Standard input for a replay: each update is due at the first sync
    // point past the code entered before it (read_line's `before` in
    // wasmhost.mjs).
    const queue = [];
    let lines = 0; // lines of code so far
    for (const c of chunks) {
      if (c.update) queue.push({ src: c.src, after: lines });
      else lines += c.code.split("\n").length;
    }
    const bytes = this.readFile(this.wasmPath);
    if (this.startProgram && reactiveNames(chunks).size > 0) {
      const prog = this.startProgram(bytes, queue);
      const r = await prog.pending;
      const ok = (r.idle || r.status === 0) && r.err === "";
      if (!ok || !r.idle) prog.terminate();
      return { ok, compile: false, stdout: r.stdout, error: this.mapPositions(r.err, chunks), prog: ok && r.idle ? prog : null };
    }
    const out = [];
    let err = "";
    const rs = runModule(loadModule(bytes), {
      stdout: (b) => out.push(b.slice()),
      stderr: (t) => (err += t),
      readFile: this.readFile,
      writeFile: this.writeFile,
      readLine: (before) =>
        queue.length && (before === 0 || queue[0].after < before) ? encoder.encode(queue.shift().src) : null,
    });
    // an update that fails is reported on stderr while the program goes on;
    // an accepted session writes nothing there
    return { ok: rs === 0 && err === "", compile: false, stdout: concatText(out), error: this.mapPositions(err, chunks) };
  }

  dropLive() {
    if (this.live) this.live.terminate();
    this.live = null;
  }

  /** Run one complete input (src: its lines joined by "\n"). */
  async submit(src) {
    if (src.trim() === "") return;
    const num = ++this.inputNum;
    const history = this.history;
    const candidates = [];
    if (isUpdate(src, reactiveNames(history))) {
      const c = { src: src.trim(), num, update: true };
      if (this.live) {
        // the program is waiting for input: just send it the line
        const r = await this.live.send(c.src);
        this.out(r.stdout);
        if (r.idle && r.err === "") {
          history.push(c);
          this.printed += r.stdout;
        } else {
          this.err(this.mapPositions(r.err, [...history, c]));
          this.dropLive(); // its state may differ from the session's now
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
      result = await this.run([...history, c]);
      // `x = 5` with x reactive: send it to the program as standard input
      // (only when that error is in this input: one about an earlier input
      // means this input is wrong some other way, e.g. `a : 2` after `a = 1`)
      if (!result.ok && result.compile && i === candidates.length - 1 && !src.trim().includes("\n") &&
          result.error.includes(`<input ${num}>:`) && result.error.includes("cannot assign to reactive variable")) {
        candidates.push({ src: src.trim(), num, update: true });
        continue;
      }
      // An expression wrapper that doesn't compile: try the next form.
      if (!result.ok && result.compile && i < candidates.length - 1) continue;
      if (result.ok) history.push(c);
      break;
    }
    const printed = this.printed;
    this.out(result.stdout.startsWith(printed) ? result.stdout.slice(printed.length) : result.stdout);
    if (result.ok) {
      this.printed = result.stdout;
      this.dropLive(); // it ran the session without this input
      this.live = result.prog ?? null;
    } else this.err(result.error);
  }

  /** A command (":help" ...); returns "quit" for :quit. */
  command(line) {
    const cmd = line.trim();
    if (cmd === ":quit" || cmd === ":q") return "quit";
    if (cmd === ":reset") {
      this.dropLive();
      this.history = [];
      this.printed = "";
      this.out("session cleared\n");
    } else if (cmd === ":history") {
      for (const c of this.history) this.out(`# <input ${c.num}>${c.update ? " (update)" : ""}\n${c.src.replace(/\s+$/, "")}\n`);
    } else {
      this.out(HELP);
    }
    return null;
  }

  /**
   * One line typed. Returns "more" if the input continues on the next line
   * (prompt "..."), "quit" for :quit, else null (prompt ">>>").
   */
  async feed(line) {
    if (this.buffer.length === 0 && line.trim().startsWith(":")) return this.command(line);
    this.buffer.push(line);
    const text = this.buffer.join("\n");
    if (needsMore(text)) return "more";
    this.buffer = [];
    await this.submit(text);
    return null;
  }

  /** The end of input: run what is left of an unfinished input. */
  async finish() {
    if (this.buffer.length) await this.submit(this.buffer.join("\n"));
    this.buffer = [];
  }
}
