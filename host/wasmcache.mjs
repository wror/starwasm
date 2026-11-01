// wasmcache.mjs — compile a .star program to .wasm only when needed, the
// way CPython caches bytecode: prog.star's Wasm is kept in
// __wasmcache__/prog[.<options>].wasm next to it (as foo.py's bytecode in
// __pycache__/foo.cpython-312[.opt-1].pyc), and a header inside the cached
// file says what it was compiled from. It is reused only while all of that
// is unchanged, else recompiled (and rewritten, atomically: written to a
// temporary file, then renamed). If the cache can't be written (read-only
// directory) the program is just compiled in memory, as Python does.
//
// The header (a custom section "starwasm.cache", as JSON) holds, like a
// .pyc's magic number + source mtime and size:
//   compiler  a hash of the compiler's Wasm (Python: the magic number,
//             i.e. which interpreter version wrote it)
//   name      the source path as given: compiled into the module for
//             tracebacks, so another spelling of the path recompiles
//   flags     the compiler options (dialect, --test, --descriptor_set)
//   deps      [absolute path, mtime (ms), size] of every file the compiler
//             read: the program, the modules it load()s (all compiled into
//             the one module, unlike Python's one .pyc per module) and the
//             descriptor set
//
// The compiler is a .star program too: by default it is
// compiler/__wasmcache__/main.recursion.wasm, compiled from
// compiler/main.star by the interpreted compiler (bin/starhost) when any
// .star file under compiler/ or lib/ changed (or was added or removed).
import { createHash } from "node:crypto";
import { closeSync, mkdirSync, openSync, readdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { loadModule, runModule } from "./wasmhost.mjs";

const ROOT = resolve(fileURLToPath(new URL("..", import.meta.url)));
const SECTION = "starwasm.cache";
const VERSION = 1; // of the header's format
const CACHE_DIR = "__wasmcache__";

/** A compile error; message is the compiler's ("file:line:col: msg"). */
export class CompileError extends Error {}

// ---- the header: a custom section appended to the module

function uleb(n) {
  const out = [];
  do {
    let b = n & 0x7f;
    n >>>= 7;
    if (n) b |= 0x80;
    out.push(b);
  } while (n);
  return Buffer.from(out);
}

function withHeader(wasm, header) {
  const name = Buffer.from(SECTION);
  const body = Buffer.concat([uleb(name.length), name, Buffer.from(JSON.stringify(header))]);
  return Buffer.concat([wasm, Buffer.from([0]), uleb(body.length), body]);
}

/** The header of cached Wasm bytes, or null. */
function readHeader(bytes) {
  const uint = (p) => {
    let n = 0, shift = 0, b;
    do {
      b = bytes[p.at++];
      n += (b & 0x7f) * 2 ** shift;
      shift += 7;
    } while (b & 0x80);
    return n;
  };
  const p = { at: 8 }; // past magic and version
  while (p.at < bytes.length) {
    const id = bytes[p.at++];
    const size = uint(p);
    const end = p.at + size;
    if (id === 0) {
      const n = uint(p);
      if (bytes.toString("utf8", p.at, p.at + n) === SECTION) {
        try {
          return JSON.parse(bytes.toString("utf8", p.at + n, end));
        } catch {
          return null;
        }
      }
    }
    p.at = end;
  }
  return null;
}

// ---- freshness

function stamp(path) {
  try {
    const st = statSync(path);
    return [path, st.mtimeMs, st.size];
  } catch {
    return [path, null, null];
  }
}

const sameStamps = (a, b) => JSON.stringify(a) === JSON.stringify(b);

/** Cached bytes at path if their header matches want (deps re-stat'ed), else null. */
function cached(path, want) {
  let bytes;
  try {
    bytes = readFileSync(path);
  } catch {
    return null;
  }
  const h = readHeader(bytes);
  if (!h || h.version !== VERSION || h.compiler !== want.compiler || h.name !== want.name ||
      !sameStamps(h.flags, want.flags) || !Array.isArray(h.deps)) return null;
  if (want.deps ? !sameStamps(h.deps, want.deps) : !sameStamps(h.deps, h.deps.map(([p]) => stamp(p)))) return null;
  return bytes;
}

/** Write bytes to path atomically; false if the cache isn't writable. */
function store(path, bytes) {
  const tmp = `${path}.${process.pid}.tmp`;
  try {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(tmp, bytes);
    renameSync(tmp, path);
    return true;
  } catch {
    try { unlinkSync(tmp); } catch {}
    return false;
  }
}

/** The cache file for src compiled with flags (paths in flags left out). */
export function cachePath(src, flags = []) {
  const tag = flags.map((f) => f.replace(/^--/, "").replace(/=.*/, "")).sort().join("-");
  return join(dirname(resolve(src)), CACHE_DIR, basename(src, ".star") + (tag ? `.${tag}` : "") + ".wasm");
}

// ---- the compiler

function starFiles(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
    if (e.isDirectory() && e.name !== CACHE_DIR) starFiles(join(dir, e.name), out);
    else if (e.isFile() && e.name.endsWith(".star")) out.push(join(dir, e.name));
  }
  return out;
}

const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

/**
 * The default compiler's Wasm bytes: compiler/main.star compiled with
 * --recursion by bin/starhost, cached as above. Concurrent callers (tests
 * run in parallel) wait for one of them to build it.
 */
export function defaultCompiler() {
  const path = join(ROOT, "compiler", CACHE_DIR, "main.recursion.wasm");
  const want = () => ({
    compiler: "bin/starhost",
    name: "compiler/main.star",
    flags: ["--recursion"],
    deps: [...starFiles(join(ROOT, "compiler")), ...starFiles(join(ROOT, "lib"))].map(stamp),
  });
  let w = want();
  let bytes = cached(path, w);
  if (bytes) return bytes;
  const lock = path + ".lock";
  for (const start = Date.now(); ;) {
    try {
      mkdirSync(dirname(path), { recursive: true });
      closeSync(openSync(lock, "wx"));
      break;
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
    }
    sleep(100);
    if ((bytes = cached(path, (w = want())))) return bytes;
    if (Date.now() - start > 300000) { // a builder that died: take over
      try { unlinkSync(lock); } catch {}
    }
  }
  try {
    w = want(); // stamped before compiling, so an edit meanwhile recompiles next time
    if ((bytes = cached(path, w))) return bytes;
    const starhost = join(ROOT, "bin/starhost");
    try {
      statSync(starhost);
    } catch {
      throw new Error(`${starhost} not found; it compiles the compiler. Build it:\n  (cd host && go build -o ../bin/starhost .)`);
    }
    const tmp = `${path}.${process.pid}.build`;
    try {
      execFileSync(starhost, ["--recursion", "compiler/main.star", "--recursion", "compiler/main.star", tmp],
        { cwd: ROOT, stdio: ["ignore", "inherit", "inherit"] });
      bytes = withHeader(readFileSync(tmp), { version: VERSION, ...w });
    } catch (e) {
      throw new Error(`compiling the compiler failed (${e.message.split("\n")[0]})`);
    } finally {
      try { unlinkSync(tmp); } catch {}
    }
    store(path, bytes);
    return bytes;
  } finally {
    try { unlinkSync(lock); } catch {}
  }
}

// ---- programs

const compilers = new Map(); // compiler bytes' hash -> WebAssembly.Module

/**
 * The Wasm bytes of src (a .star path, as the user gave it) compiled with
 * the compiler options flags (--test, --globalreassign, --recursion,
 * --descriptor_set=FILE): from the cache if fresh, else compiled (by the
 * compiler Wasm compilerBytes, default defaultCompiler()) and cached.
 * Throws CompileError on a compile error.
 */
export function compileStar(src, flags = [], compilerBytes = null) {
  statSync(src); // a missing file: ENOENT, before building any compiler
  compilerBytes ??= defaultCompiler();
  const id = createHash("sha256").update(compilerBytes).digest("hex").slice(0, 16);
  const path = cachePath(src, flags);
  const want = { compiler: id, name: src, flags };
  let bytes = cached(path, want);
  if (bytes) return bytes;

  if (!compilers.has(id)) compilers.set(id, loadModule(compilerBytes));
  const deps = new Map(); // stamped before reading, as want's freshness check
  let out = null;
  let err = "";
  const status = runModule(compilers.get(id), {
    progArgs: [...flags, src, "<output>"],
    readFile: (p) => {
      const s = stamp(resolve(p));
      const data = readFileSync(p); // throws for a missing file: the compiler reports it
      deps.set(s[0], s);
      return data;
    },
    writeFile: (p, data) => (out = data),
    stderr: (t) => (err += t),
  });
  if (status !== 0 || out === null) {
    // "Error in fail: fail: <file>:L:C: msg" after a traceback through the
    // compiler's own source: keep just the message
    const m = /Error in fail: fail: (.*)/.exec(err);
    throw new CompileError(m ? m[1] : err.trim() || `compiler exited with status ${status}`);
  }
  bytes = withHeader(out, { version: VERSION, ...want, deps: [...deps.values()] });
  store(path, bytes);
  return bytes;
}
