// tests/upstream/run.mjs — run starlark-go's own test files against
// starwasm. See tests/upstream/README.md.
//
//   node tests/upstream/run.mjs [-j N] [-v] [file.star ...]
//
// Each test file is split into chunks at "---" lines, as starlark-go's
// internal/chunkedfile does; a "### regexp" comment on a line means that
// line must fail with an error matching regexp. Every chunk runs three ways:
//
//   upstream   bin/upstreamhost -options=file: starlark-go with only the
//              dialect options the chunk names, as starlark-go's tests run
//              it. Checks the harness (assert.star etc.) itself.
//   reference  bin/upstreamhost -options=starwasm: starlark-go with every
//              option on and starwasm's predeclared names, i.e. what
//              starwasm should do.
//   starwasm   compiled with `$COMPILER --test` and run by Node
//              (syntax/testdata chunks: parsed by tests/upstream/parse_only.star)
//
// Verdict per chunk:
//   pass       starwasm meets every expectation (assertions and ### errors)
//   first      static chunk: starwasm reported the first expected error and
//              stopped there (starlark-go's resolver reports them all)
//   wording    static chunk: starwasm's first error is on the expected line
//              but worded differently (only run-time errors are meant to
//              match starlark-go's text)
//   static     the expected run-time error, reported by starwasm's compiler
//              (e.g. a load() of a missing name); the chunk didn't run
//   dialect    the reference fails too: the chunk depends on an option being
//              off, or on a predeclared name starwasm doesn't have
//   n/a        the upstream run fails: the chunk needs Go-only test values
//              (hasfields, fibonacci, gensym, ...)
//   known      a FAIL listed in tests/upstream/known_failures.txt
//   FAIL       anything else: a starwasm bug or difference
//
// Exit status 1 if any chunk is FAIL (not known), or a known failure now
// passes (so the list stays current). Results: out/upstream/report.txt and
// out/upstream/results.json.

import { spawn, execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync, readFileSync, copyFileSync, existsSync, rmSync } from "node:fs";
import { cpus } from "node:os";
import { join, resolve, basename } from "node:path";

const ROOT = resolve(new URL("../..", import.meta.url).pathname);
const OUT = join(ROOT, "out/upstream");
const COMPILER = (process.env.COMPILER || "bin/starhost compiler/main.star").split(/\s+/);

// The test files, as in starlark-go's TestExecFile / TestResolve /
// TestParseErrors. lines: run only the first N lines (the rest needs a Go
// builtin). blank: [first, last] line ranges replaced by empty lines (line
// numbers stay put): code that needs a Go-only test value. Files not run
// say why in SKIPPED.
const EXEC = (f, more = {}) => ({ path: `starlark/testdata/${f}.star`, mode: "exec", ...more });
const FILES = [
  EXEC("assign"),
  EXEC("bool"),
  EXEC("builtins", { blank: [[185, 196], [211, 224]] }),  // hasfields
  EXEC("bytes"),
  EXEC("control", { blank: [[56, 64]] }),  // fibonacci
  EXEC("dict"),
  EXEC("float"),
  EXEC("function", { blank: [[84, 86]] }),  // hasfields
  EXEC("int"),
  EXEC("list", { blank: [[163, 169]] }),  // hasfields
  EXEC("misc", { blank: [[105, 105]] }),  // str(freeze): the shim's freeze is a def
  EXEC("set"),
  EXEC("string"),
  EXEC("tuple"),
  EXEC("recursion"),
  EXEC("while"),
  { path: "starlarkstruct/testdata/struct.star", mode: "exec", lines: 19 },  // line 20 on needs gensym
  { path: "resolve/testdata/resolve.star", mode: "resolve" },
  { path: "syntax/testdata/errors.star", mode: "parse" },
  { path: "syntax/testdata/scan.star", mode: "parse" },
];
export const SKIPPED = {
  "starlark/testdata/json.star": "json module (Go library)",
  "starlark/testdata/math.star": "math module (Go library)",
  "starlark/testdata/time.star": "time module (Go library)",
  "starlark/testdata/proto.star": "proto module (Go library)",
  "starlark/testdata/module.star": "tests starlarkstruct's module type, which the assert shim replaces with struct",
  "starlark/testdata/function_param.star": "not a test script (used by a Go test of parameter names)",
  "starlark/testdata/benchmark.star": "benchmarks",
  "starlark/testdata/bazel.star": "not run by starlark-go's tests",
  "starlark/testdata/paths.star": "not run by starlark-go's tests",
};

// ---- arguments

let jobs = cpus().length, verbose = false;
const only = [];
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "-j") jobs = Number(argv[++i]);
  else if (argv[i] === "-v") verbose = true;
  else only.push(argv[i]);
}

// ---- the starlark-go source tree (the version host/go.mod pins)

function upstreamDir() {
  if (process.env.STARLARK_GO_DIR) return process.env.STARLARK_GO_DIR;
  try {
    return execFileSync("go", ["list", "-m", "-f", "{{.Dir}}", "go.starlark.net"], { cwd: join(ROOT, "host"), encoding: "utf8" }).trim();
  } catch (e) {
    console.error("can't find go.starlark.net's source: run `cd host && go mod download`, or set STARLARK_GO_DIR");
    process.exit(2);
  }
}

// ---- chunks (as go.starlark.net/internal/chunkedfile)

// Go's strconv.Unquote, for the quoted regexps after ###.
function goUnquote(s) {
  if (s.length >= 2 && s[0] === "`" && s.at(-1) === "`") return s.slice(1, -1);
  if (s.length >= 2 && s[0] === '"' && s.at(-1) === '"') {
    return s.slice(1, -1).replace(/\\(x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|[0-7]{3}|.)/g, (_, e) => {
      const simple = { a: "\x07", b: "\b", f: "\f", n: "\n", r: "\r", t: "\t", v: "\v", "\\": "\\", '"': '"', "'": "'" };
      if (e in simple) return simple[e];
      if (/^[xuU]/.test(e)) return String.fromCodePoint(parseInt(e.slice(1), 16));
      if (/^[0-7]{3}$/.test(e)) return String.fromCharCode(parseInt(e, 8));
      throw new Error(`bad escape \\${e}`);
    });
  }
  throw new Error(`not a quoted regexp: ${s}`);
}

// Go regexp syntax as a JavaScript RegExp (the patterns in the test files
// are simple; \pL-style classes need braces).
function goRegExp(p) {
  const q = p.replace(/\\p([A-Z])/g, "\\p{$1}").replace(/\\P([A-Z])/g, "\\P{$1}");
  try { return new RegExp(q, "u"); } catch { return new RegExp(q); }
}

function readChunks(text) {
  const chunks = [];
  let linenum = 1;
  for (const chunk of text.split("\n---\n")) {
    const src = "\n".repeat(linenum - 1) + chunk;
    const first = linenum;
    const want = new Map(); // line -> {pattern, rx}
    for (const line of chunk.split("\n")) {
      const k = line.indexOf("###");
      if (k >= 0) {
        let pattern = null;
        try { pattern = goUnquote(line.slice(k + 3).trim()); } catch {}  // chunkedfile skips these too
        if (pattern !== null) want.set(linenum, { pattern, rx: goRegExp(pattern) });
      }
      linenum++;
    }
    chunks.push({ src, first, last: linenum - 1, want });
    linenum++; // the "---" line
  }
  return chunks;
}

// ---- running

function run(cmd, args, cwd) {
  return new Promise((res) => {
    const p = spawn(cmd, args, { cwd });
    let out = "", err = "";
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (err += d));
    p.on("close", (code, signal) => res({ code: code ?? 128, signal, out, err }));
  });
}

async function pool(items, n, fn) {
  const results = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => {
    while (next < items.length) {
      const i = next++;
      results[i] = await fn(items[i]);
    }
  }));
  return results;
}

// ---- checking a run against the chunk's expectations

const isChunk = (where, name) => basename(where.replace(/:\d+:\d+$/, "")) === name;

// exec mode: assertion failures (@@test_error lines) and the final error
// (outermost frame in the chunk file, as starlark-go's TestExecFile).
function checkExec(r, chunk, name) {
  const problems = [];
  let compileTime = false;
  const want = new Map(chunk.want);
  const gotError = (line, msg) => {
    const w = want.get(line);
    if (!w) problems.push(`line ${line}: unexpected error: ${msg}`);
    else {
      want.delete(line);
      if (!w.rx.test(msg)) problems.push(`line ${line}: error ${JSON.stringify(msg)} does not match ${JSON.stringify(w.pattern)}`);
    }
  };
  const lines = r.err.split("\n");
  let i = 0;
  for (; i < lines.length && lines[i].startsWith("@@test_error "); i++) {
    const { msg, frames } = JSON.parse(lines[i].slice(13));
    const at = [...frames].reverse().find((f) => isChunk(f, name));
    problems.push(`line ${at ? at.split(":").at(-2) : "?"}: assertion: ${msg}`);
  }
  const rest = lines.slice(i).join("\n").replace(/\n+$/, "");
  // stray @@test_error lines after other output
  for (const l of lines.slice(i)) if (l.startsWith("@@test_error ")) problems.push(`assertion: ${JSON.parse(l.slice(13)).msg}`);
  if (r.code === 0 && rest === "") {
    // ok
  } else if (r.code === 1 && rest.startsWith("Traceback")) {
    const frames = [...rest.matchAll(/^  (\S+:\d+:\d+): in /gm)].map((m) => m[1]);
    const m = /\nError(?: in [^:]+)?: ([\s\S]*)$/.exec(rest);
    const msg = m ? m[1] : rest;
    const at = frames.reverse().find((f) => isChunk(f, name)); // innermost, as TestExecFile
    if (at) gotError(Number(at.split(":").at(-2)), msg);
    else problems.push(`error outside the chunk: ${msg}`);
  } else if (r.code === 1) {
    // a static error (starwasm finds some, e.g. bad load() names, at compile
    // time, where starlark-go fails at run time): it may meet a ### too
    const m = /([^\s:]+\.star):(\d+):(\d+): (.*)$/.exec(rest.split("\n").at(-1));
    if (m && basename(m[1]) === name && want.has(Number(m[2]))) {
      gotError(Number(m[2]), m[4]);
      compileTime = true;
    } else {
      problems.push(m ? `line ${m[2]}: static error: ${m[4]}` : `error: ${rest.split("\n").at(-1)}`);
    }
  } else {
    problems.push(`exit status ${r.code}${r.signal ? " (" + r.signal + ")" : ""}: ${rest.split("\n").at(-1)}`);
  }
  for (const [line, w] of want) problems.push(`line ${line}: expected error matching ${JSON.stringify(w.pattern)}`);
  return { problems, unreported: 0, compileTime };
}

// static modes: "file:line:col: msg" errors; starwasm stops at the first
// (it's the last line of the compiler's traceback), starlark-go lists all.
function checkStatic(r, chunk, name, firstOnly) {
  const problems = [];
  const want = new Map(chunk.want);
  const errs = [];
  if (r.code === 1) {
    const ls = r.err.trim().split("\n");
    for (const l of firstOnly ? [ls.at(-1)] : ls) {
      const m = /([^\s:]+\.star):(\d+):(\d+): ([\s\S]*)$/.exec(l);
      if (m && basename(m[1]) === name) errs.push([Number(m[2]), m[4]]);
      else problems.push(`error: ${l}`);
    }
  } else if (r.code !== 0) {
    problems.push(`exit status ${r.code}: ${r.err.trim().split("\n").at(-1)}`);
  }
  // starwasm's message wording is its own: on the right line, a message
  // that doesn't match is "wording" (starwasm), a problem (starlark-go)
  const wording = [];
  for (const [line, msg] of errs) {
    const w = want.get(line);
    if (!w) problems.push(`line ${line}: unexpected error: ${msg}`);
    else {
      want.delete(line);
      if (!w.rx.test(msg)) (firstOnly ? wording : problems).push(`line ${line}: error ${JSON.stringify(msg)} does not match ${JSON.stringify(w.pattern)}`);
    }
  }
  // starwasm reports one error: later expected errors can't show up
  let unreported = 0;
  if (firstOnly && errs.length === 1 && problems.length === 0) {
    for (const [line] of [...want]) if (line > errs[0][0]) { want.delete(line); unreported++; }
  }
  for (const [line, w] of want) problems.push(`line ${line}: expected error matching ${JSON.stringify(w.pattern)}`);
  return { problems, unreported, wording };
}

// resolve/testdata loads modules that don't exist (starlark-go's resolver
// never reads them); starwasm's compiler does, so give it stubs that
// define every name loaded from them.
function writeStubs(dir, src) {
  const mods = new Map();
  for (const m of src.matchAll(/\bload\(\s*"([^"]*)"([^)]*)\)/g)) {
    if (m[1] === "assert.star" || m[1] === "" || m[1].includes("/")) continue;
    const names = mods.get(m[1]) ?? new Set();
    for (const n of m[2].matchAll(/"([A-Za-z_][A-Za-z0-9_]*)"/g)) if (!n[1].startsWith("_")) names.add(n[1]);
    mods.set(m[1], names);
  }
  for (const [mod, names] of mods) {
    writeFileSync(join(dir, mod), [...names].map((n) => `${n} = None\n`).join("") || "pass\n");
  }
}

// ---- one chunk

async function runChunk(job) {
  const { file, idx, chunk } = job;
  const name = basename(file.path);
  const dir = join(OUT, `${name.replace(/\.star$/, "")}-${idx + 1}`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, name), chunk.src);
  copyFileSync(join(ROOT, "tests/upstream/assert.star"), join(dir, "assert.star"));
  if (file.mode === "resolve") writeStubs(dir, chunk.src);
  const oracle = (options) => run(join(ROOT, "bin/upstreamhost"), [`-options=${options}`, `-mode=${file.mode}`, "./" + name], dir);
  const check = (r, firstOnly) => (file.mode === "exec" ? checkExec(r, chunk, name) : checkStatic(r, chunk, name, firstOnly));

  const up = check(await oracle("file"), false);
  const ref = await oracle("starwasm");
  const refc = check(ref, false);

  let sw;
  if (file.mode === "parse") {
    sw = await run(join(ROOT, "bin/starhost"), ["tests/upstream/parse_only.star", join(dir, name)], ROOT);
  } else {
    const wasm = join(dir, "prog.wasm");
    sw = await run(COMPILER[0], [...COMPILER.slice(1), "--test", join(dir, name), wasm], ROOT);
    if (sw.code !== 0) {
      // a compile error: keep "file:line:col: msg" (the last line of the
      // compiler's own traceback)
      const last = sw.err.trim().split("\n").at(-1).replace(/^Error in fail: fail: /, "");
      sw = { code: 1, out: "", err: last + "\n" };
    } else if (file.mode === "exec") {
      sw = await run("node", [join(ROOT, "host/run.mjs"), wasm], dir);
    }
  }
  const swc = check(sw, true);
  // exec: prints must match the reference too
  if (file.mode === "exec" && refc.problems.length === 0 && swc.problems.length === 0 && sw.out !== ref.out) {
    swc.problems.push("stdout differs from starlark-go's");
  }

  let verdict;
  if (up.problems.length) verdict = "n/a";
  else if (refc.problems.length) verdict = "dialect";
  else if (swc.problems.length) verdict = "FAIL";
  else if (swc.wording && swc.wording.length) verdict = "wording";
  else verdict = swc.unreported ? "first" : swc.compileTime ? "static" : "pass";
  return {
    file: file.path, chunk: idx + 1, lines: `${chunk.first}-${chunk.last}`, verdict,
    problems: verdict === "n/a" ? up.problems : verdict === "dialect" ? refc.problems : verdict === "wording" ? swc.wording : swc.problems,
    unreported: swc.unreported,
  };
}

// ---- main

const dir = upstreamDir();
for (const b of ["bin/starhost", "bin/upstreamhost"]) {
  if (!existsSync(join(ROOT, b))) {
    console.error(`${b} missing: see tests/upstream/README.md`);
    process.exit(2);
  }
}
rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });

const files = only.length ? FILES.filter((f) => only.some((o) => f.path.endsWith(o))) : FILES;
const jobsList = [];
for (const file of files) {
  let text = readFileSync(join(dir, file.path), "utf8");
  if (file.lines) text = text.split("\n").slice(0, file.lines).join("\n") + "\n";
  if (file.blank) {
    const ls = text.split("\n");
    for (const [a, b] of file.blank) for (let i = a; i <= b; i++) ls[i - 1] = "";
    text = ls.join("\n");
  }
  readChunks(text).forEach((chunk, idx) => jobsList.push({ file, idx, chunk }));
}
const results = await pool(jobsList, jobs, runChunk);

// known failures: "file.star:chunk  reason" lines
const knownPath = join(ROOT, "tests/upstream/known_failures.txt");
const known = new Map();
if (existsSync(knownPath)) {
  for (const l of readFileSync(knownPath, "utf8").split("\n")) {
    const m = /^(\S+\.star):(\d+)\b\s*(.*)$/.exec(l.trim());
    if (m) known.set(`${m[1]}:${m[2]}`, m[3]);
  }
}
let bad = 0;
const nowPassing = [];
for (const r of results) {
  const key = `${basename(r.file)}:${r.chunk}`;
  if (r.verdict === "FAIL" && known.has(key)) { r.verdict = "known"; r.known = known.get(key); }
  else if (r.verdict === "FAIL") bad++;
  else if (known.has(key) && ["pass", "first", "static", "wording"].includes(r.verdict) && (only.length === 0 || files.some((f) => f.path === r.file))) nowPassing.push(key);
}

const VERDICTS = ["pass", "first", "static", "wording", "dialect", "n/a", "known", "FAIL"];
let report = "";
const say = (s) => { report += s + "\n"; };
const total = Object.fromEntries(VERDICTS.map((v) => [v, 0]));
for (const file of files) {
  const rs = results.filter((r) => r.file === file.path);
  const c = Object.fromEntries(VERDICTS.map((v) => [v, rs.filter((r) => r.verdict === v).length]));
  for (const v of VERDICTS) total[v] += c[v];
  say(`${file.path}: ${rs.length} chunks: ` + VERDICTS.filter((v) => c[v]).map((v) => `${c[v]} ${v}`).join(", "));
  for (const r of rs) {
    if (r.verdict === "pass" || (r.verdict !== "FAIL" && !verbose)) continue;
    say(`  ${basename(r.file)}:${r.chunk} (lines ${r.lines}) ${r.verdict}${r.known ? ": " + r.known : ""}`);
    for (const p of r.problems.slice(0, verbose ? 1000 : 5)) say(`      ${p}`);
    if (!verbose && r.problems.length > 5) say(`      ... ${r.problems.length - 5} more`);
  }
}
say(`upstream: ${results.length} chunks: ` + VERDICTS.filter((v) => total[v]).map((v) => `${total[v]} ${v}`).join(", "));
for (const k of nowPassing) say(`upstream: ${k} is listed in known_failures.txt but passes now: remove it`);
for (const [f, why] of Object.entries(SKIPPED)) if (!only.length) say(`upstream: not run: ${f} (${why})`);
process.stdout.write(report);
writeFileSync(join(OUT, "report.txt"), report);
writeFileSync(join(OUT, "results.json"), JSON.stringify(results, null, 1));
process.exit(bad || nowPassing.length ? 1 : 0);
