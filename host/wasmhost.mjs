// wasmhost.mjs — runs compiled Starlark modules: host imports, argv,
// files, and starlark-go-style tracebacks. Used by run.mjs (command line)
// and repl.mjs.
//
// Host imports provided under "host" (see lib/runtime.star):
//   write(fd, ptr, len)        fd 1/2: stdout/stderr; fd 3: file being written
//   exit(code)                 stop with an exit status
//   fail(ptr, len, plain)      a Starlark error: report a traceback and the
//                              message (like starlark-go), exit status 1;
//                              plain: no "Error in <builtin>" prefix
//   file_size(ptr, len)        load the named file; returns size or -1
//   file_chunk(off, ptr, n)    copy n loaded bytes from off into memory
//   out_begin(ptr, len)        start writing the named file (via fd 3)
//   out_end()                  finish it
//   arg_count() arg_len(i) arg_copy(i, ptr)
//   float_fmt(x, conv)         format a float (Go strconv style) at memory 0
//   float_parse(ptr, len)      parse a float; f64 at memory 0; 0/1/2 status
//   float_mod(x, y)            fmod
//   print_i32 / print_i64      (milestone 1 demo)
// and, for programs compiled with --test (tests/upstream/):
//   catch(f)                   call f() via the test_call0 export; -1, or
//                              the length of its error message (at 0)
//   test_error(ptr, len)       report a test failure (see testErrorLine)
//   matches(plen, slen)        regexp at 0 matches the string after it
//   floateq(x, y)              equal within 1 ULP
import { readFileSync, writeFileSync } from "node:fs";

// ---- Floats (the runtime's float_fmt / float_parse imports)

// x formatted like Go's strconv.FormatFloat(x, conv, prec, 64) as
// starlark-go uses it: conv 'g'/'G' with the shortest round-trip digits
// (JavaScript's are the same), 'e'/'E'/'f' with 6 digits; str() adds ".0"
// to 'g' results that would otherwise look like ints.
// The exact value of finite a >= 0 as [m, e]: a = m * 2**e (BigInt m).
function exactParts(a) {
  const dv = new DataView(new ArrayBuffer(8));
  dv.setFloat64(0, a);
  const bits = dv.getBigUint64(0);
  const be = Number((bits >> 52n) & 0x7ffn);
  const frac = bits & ((1n << 52n) - 1n);
  return be === 0 ? [frac, -1074] : [frac | (1n << 52n), be - 1075];
}

// round(a * 10**p) to the nearest integer, ties to even (Go's rounding of
// the exact decimal value), as a BigInt.
function scaledDigits(a, p) {
  const [m, e] = exactParts(a);
  let num = m, den = 1n;
  if (e >= 0) num <<= BigInt(e); else den <<= BigInt(-e);
  if (p >= 0) num *= 10n ** BigInt(p); else den *= 10n ** BigInt(-p);
  const q = num / den, r2 = (num % den) * 2n;
  return r2 > den || (r2 === den && (q & 1n) === 1n) ? q + 1n : q;
}

// sign of a - 10**d, exactly
function cmpPow10(a, d) {
  const [m, e] = exactParts(a);
  let l = m, r = 1n;
  if (e >= 0) l <<= BigInt(e); else r <<= BigInt(-e);
  if (d >= 0) r *= 10n ** BigInt(d); else l *= 10n ** BigInt(-d);
  return l < r ? -1 : l > r ? 1 : 0;
}

export function formatFloat(x, conv) {
  if (Number.isNaN(x)) return "nan";
  if (x === Infinity) return "+inf";
  if (x === -Infinity) return "-inf";
  const neg = x < 0 || Object.is(x, -0) ? "-" : "";
  const a = Math.abs(x);
  const expo = (e) => (e < 0 ? "-" : "+") + String(Math.abs(e)).padStart(2, "0");
  const upper = conv === "G" || conv === "E";
  let s;
  if (conv === "f") {
    const n = scaledDigits(a, 6).toString().padStart(7, "0");
    s = n.slice(0, -6) + "." + n.slice(-6);
  } else if (conv === "e" || conv === "E") {
    let d = a === 0 ? 0 : Math.floor(Math.log10(a));
    // fix the estimate exactly: 10**d <= a < 10**(d+1)
    if (a !== 0) {
      while (cmpPow10(a, d) < 0) d--;
      while (cmpPow10(a, d + 1) >= 0) d++;
    }
    let n = scaledDigits(a, 6 - d);
    if (n === 10n ** 7n) { n = 10n ** 6n; d++; }
    const t = n.toString().padStart(7, "0");
    s = t[0] + "." + t.slice(1) + "e" + expo(d);
  } else {
    // shortest digits d1 d2 ... dn and decimal exponent: x = d1.d2...dn * 10**exp
    let [m, e] = a.toExponential().split("e");
    const digits = m.replace(".", "");
    const exp = a === 0 ? 0 : Number(e);
    if (exp < -4 || exp >= 6) {  // Go: %e when exp < -4 || exp >= 6 (shortest)
      s = digits[0] + (digits.length > 1 ? "." + digits.slice(1) : "") + "e" + expo(exp);
    } else if (exp < 0) {
      s = "0." + "0".repeat(-exp - 1) + digits;
    } else if (digits.length > exp + 1) {
      s = digits.slice(0, exp + 1) + "." + digits.slice(exp + 1);
    } else {
      s = digits + "0".repeat(exp + 1 - digits.length);
    }
    if (!s.includes(".") && !s.includes("e")) s += ".0";
  }
  return neg + (upper ? s.toUpperCase() : s);
}

// float(s) / float literals: [status, value]; status 0 ok, 1 invalid
// syntax, 2 out of range (as Go's strconv.ParseFloat).
export function parseFloat_(s) {
  const t = s.replace(/^([+-]?)(?:inf|infinity)$/i, "$1Infinity").replace(/^[+-]?nan$/i, "NaN");
  if (t === "NaN") return [0, NaN];
  if (!/^[+-]?(Infinity|(\d(_?\d)*\.?(\d(_?\d)*)?|\.\d(_?\d)*)([eE][+-]?\d+)?)$/.test(t)) return [1, 0];
  const v = Number(t.replace(/_/g, ""));
  if (!Number.isFinite(v) && !/Infinity/.test(t)) return [2, 0];
  return [0, v];
}

class Exit extends Error {
  constructor(code) {
    super(`exit ${code}`);
    this.code = code;
  }
}

class StarlarkError extends Error {}

// ---- Tracebacks
//
// The compiler emits these custom sections:
//   starwasm.marks  (function index, module offset, tag) for every call that
//                   may fail, placed right before the call instruction
//   starwasm.pos    per tag: file, line, column, builtin + 1, and for
//                   method calls the "." line/column (LEB128)
//   starwasm.debug  JSON: files, builtins, funcs (which Wasm functions are
//                   Starlark frames, and their names)
// V8 reports each Wasm frame as wasm-function[index]:0xOFFSET, where OFFSET
// is the call instruction being executed in that frame; the marker at that
// offset gives the Starlark position.
Error.stackTraceLimit = 200000; // starlark-go tracebacks can be 100,000 frames deep

const debugCache = new WeakMap();

function readDebugInfo(mod) {
  if (debugCache.has(mod)) return debugCache.get(mod);
  const dbg = WebAssembly.Module.customSections(mod, "starwasm.debug");
  const mk = WebAssembly.Module.customSections(mod, "starwasm.marks");
  let result = null;
  if (dbg.length > 0) {
    const info = JSON.parse(new TextDecoder().decode(dbg[0]));
    const funcs = new Map(info.funcs.map(([idx, kind, name, entry]) => [idx, { kind, name, entry }]));
    const reader = (buf) => {
      const b = new Uint8Array(buf);
      let p = 0;
      return () => {
        let r = 0, shift = 0, x;
        do { x = b[p++]; r += (x & 0x7f) * 2 ** shift; shift += 7; } while (x & 0x80);
        return r;
      };
    };
    const marks = new Map(); // function index -> [[offset, tag], ...] ascending
    if (mk.length) {
      const leb = reader(mk[0]);
      for (let groups = leb(); groups > 0; groups--) {
        const f = leb(), ms = [];
        for (let n = leb(), off = 0; n > 0; n--) {
          off += leb();
          ms.push([off, leb()]);
        }
        marks.set(f, ms);
      }
    }
    const pos = []; // per tag: [file, line, col, builtin or -1, dotLine, dotCol]
    const ps = WebAssembly.Module.customSections(mod, "starwasm.pos");
    if (ps.length) {
      const leb = reader(ps[0]);
      for (let n = leb(); n > 0; n--) pos.push([leb(), leb(), leb(), leb() - 1, leb(), leb()]);
    }
    info.pos = pos;
    result = { info, funcs, marks };
  }
  debugCache.set(mod, result);
  return result;
}

function markAt(dbg, f, off) {
  const ms = dbg.marks.get(f);
  if (!ms) return -1;
  let lo = 0, hi = ms.length - 1, best = -1;
  while (lo <= hi) { // last marker at or before off
    const mid = (lo + hi) >> 1;
    if (ms[mid][0] <= off) { best = ms[mid][1]; lo = mid + 1; } else hi = mid - 1;
  }
  return best;
}

// Starlark frames, outermost first: [{where, name, builtin}]. builtin: the
// builtin the frame was calling when the error happened, if any: named by
// the call's marker (a direct call), or else by the outermost hidden frame
// called from it (a builtin called as a value).
function starlarkFrames(dbg, stack, plain) {
  const frames = [];
  let hidden = null; // outermost hidden frame since the last Starlark frame
  for (const line of stack.split("\n")) { // innermost first
    const m = /wasm-function\[(\d+)\]:0x([0-9a-f]+)/.exec(line);
    if (!m) continue;
    const f = Number(m[1]), off = parseInt(m[2], 16);
    const fn = dbg.funcs.get(f);
    if (!fn) continue;
    if (fn.kind === "hidden") { // prelude code and wrappers act like builtins
      hidden = fn.name;
      continue;
    }
    let tag;
    if (fn.kind === "dyn") {
      // argument binding failed before the body started: report the
      // callee's frame at its entry; otherwise its body frame is shown
      if (frames.length > 0) continue;
      tag = fn.entry;
    } else {
      tag = markAt(dbg, f, off);
    }
    if (tag < 0) continue;
    let [file, ln, col, bi, dl, dc] = dbg.info.pos[tag];
    // attribute errors of a method call point at its "."
    if (plain && frames.length === 0 && dl > 0) [ln, col] = [dl, dc];
    frames.push({
      where: `${dbg.info.files[file]}:${ln}:${col}`,
      name: fn.name,
      builtin: bi >= 0 ? dbg.info.builtins[bi] : hidden,
    });
    hidden = null;
  }
  return frames.reverse();
}

// A test_error() report: one line, "@@test_error " + JSON {msg, frames},
// frames being the Starlark call stack ("file:line:col"), outermost first.
// tests/upstream/oracle/main.go prints the same.
function testErrorLine(mod, message, stack) {
  const debug = readDebugInfo(mod);
  const frames = debug ? starlarkFrames(debug, stack, false).map((f) => f.where) : [];
  return "@@test_error " + JSON.stringify({ msg: message, frames }) + "\n";
}

// Go's regexp syntax, as far as JavaScript's RegExp shares it.
function goRegExp(pattern) {
  const p = pattern.replace(/\\p([A-Z])/g, "\\p{$1}").replace(/\\P([A-Z])/g, "\\P{$1}");
  try {
    return new RegExp(p, "u");
  } catch {
    return new RegExp(p);
  }
}

// Go's floating-point equality within 1 ULP (starlarktest's floateq).
function floatEq(x, y) {
  if (x === y) return true;
  if (Number.isNaN(x)) return Number.isNaN(y);
  if (Number.isNaN(y)) return false;
  const dv = new DataView(new ArrayBuffer(16));
  dv.setFloat64(0, x);
  dv.setFloat64(8, y);
  const a = dv.getBigUint64(0), b = dv.getBigUint64(8);
  return a === b + 1n || b === a + 1n;
}

function formatError(mod, message, stack, plain = false) {
  const debug = readDebugInfo(mod);
  const frames = debug ? starlarkFrames(debug, stack, plain) : [];
  let out = "";
  if (frames.length) {
    out += "Traceback (most recent call last):\n";
    frames.forEach((fr, i) => {
      out += `  ${fr.where}: in ${fr.name}\n`;
      // a builtin that called back into Starlark (sorted(key=f), min(key=f),
      // ...) shows as its own frame, as in starlark-go
      if (fr.builtin && i < frames.length - 1) out += `  <builtin>: in ${fr.builtin}\n`;
    });
  }
  const inner = frames[frames.length - 1];
  out += inner && inner.builtin && !plain ? `Error in ${inner.builtin}: ${message}\n` : `Error: ${message}\n`;
  return out;
}

// ---- Running

/** Compile Wasm bytes; throws an Error("invalid module: ...") on failure. */
export function loadModule(bytes) {
  try {
    return new WebAssembly.Module(bytes);
  } catch (e) {
    throw new Error(`invalid module: ${e.message}`);
  }
}

/**
 * Run an export of a compiled module.
 *   opts.exportName  default "main"
 *   opts.rawArgs     values passed to the export (Number, or BigInt)
 *   opts.progArgs    what the program sees as argv (strings)
 *   opts.stdout(bytes: Uint8Array), opts.stderr(text: string)
 * Returns the exit status: 0 ok, 1 Starlark error or exit(1), 3 internal
 * error (a Wasm trap), 2 no such export.
 */
export function runModule(module, opts = {}) {
  const { exportName = "main", rawArgs = [], progArgs = [] } = opts;
  const stdout = opts.stdout ?? (() => {});
  const stderr = opts.stderr ?? (() => {});
  const utf8 = new TextDecoder();
  const encodedArgs = progArgs.map((a) => new TextEncoder().encode(a));
  let instance;
  let loaded = null; // bytes of the last file_size() call
  let outPath = null;
  let outChunks = [];
  const mem = (ptr, len) => new Uint8Array(instance.exports.memory.buffer, ptr, len);

  const imports = {
    host: {
      write(fd, ptr, len) {
        const data = Buffer.from(mem(ptr, len)); // copy: memory is reused
        if (fd === 3) outChunks.push(data);
        else if (fd === 2) stderr(utf8.decode(data));
        else stdout(data);
      },
      exit(code) {
        throw new Exit(code);
      },
      fail(ptr, len, plain) {
        const e = new StarlarkError(utf8.decode(mem(ptr, len)));
        e.trace = new Error().stack;
        e.plain = plain;
        throw e;
      },
      file_size(ptr, len) {
        try {
          loaded = readFileSync(utf8.decode(mem(ptr, len)));
          return loaded.length;
        } catch {
          return -1;
        }
      },
      file_chunk(off, ptr, n) {
        mem(ptr, n).set(loaded.subarray(off, off + n));
      },
      out_begin(ptr, len) {
        outPath = utf8.decode(mem(ptr, len));
        outChunks = [];
      },
      out_end() {
        writeFileSync(outPath, Buffer.concat(outChunks));
        outChunks = [];
      },
      arg_count: () => encodedArgs.length,
      arg_len: (i) => encodedArgs[i].length,
      arg_copy(i, ptr) {
        mem(ptr, encodedArgs[i].length).set(encodedArgs[i]);
      },
      float_fmt(x, conv) {
        const b = Buffer.from(formatFloat(x, String.fromCharCode(conv)));
        mem(0, b.length).set(b);
        return b.length;
      },
      float_parse(ptr, len) {
        const [status, v] = parseFloat_(utf8.decode(mem(ptr, len)));
        new DataView(instance.exports.memory.buffer).setFloat64(0, v, true);
        return status;
      },
      float_mod: (x, y) => x % y,
      catch(f) {
        try {
          instance.exports.test_call0(f);
          return -1;
        } catch (e) {
          if (!(e instanceof StarlarkError)) throw e;
          const b = Buffer.from(e.message).subarray(0, 65536);
          mem(0, b.length).set(b);
          return b.length;
        }
      },
      test_error(ptr, len) {
        stderr(testErrorLine(module, utf8.decode(mem(ptr, len)), new Error().stack));
      },
      matches(plen, slen) {
        return goRegExp(utf8.decode(mem(0, plen))).test(utf8.decode(mem(plen, slen))) ? 1 : 0;
      },
      floateq: (x, y) => (floatEq(x, y) ? 1 : 0),
      print_i32: (x) => stdout(Buffer.from(String(x) + "\n")),
      print_i64: (x) => stdout(Buffer.from(String(x) + "\n")),
    },
  };

  // Only supply the imports the module actually asks for.
  const wanted = {};
  for (const imp of WebAssembly.Module.imports(module)) {
    wanted[imp.module] ??= {};
    wanted[imp.module][imp.name] = imports[imp.module]?.[imp.name];
  }
  instance = new WebAssembly.Instance(module, wanted);

  const fn = instance.exports[exportName];
  if (typeof fn !== "function") {
    stderr(`no exported function "${exportName}"\n`);
    return 2;
  }
  try {
    let result;
    try {
      result = fn(...rawArgs.map(Number));
    } catch (e) {
      if (!(e instanceof TypeError) || rawArgs.length === 0) throw e;
      result = fn(...rawArgs.map(BigInt));
    }
    if (result !== undefined) stdout(Buffer.from(String(result) + "\n"));
    return 0;
  } catch (e) {
    if (e instanceof Exit) return e.code;
    if (e instanceof StarlarkError) {
      stderr(formatError(module, e.message, e.trace, e.plain));
      return 1;
    }
    // Wasm traps (unreachable, null deref, bad cast, stack overflow): still a
    // traceback, but this is an internal error, so exit status 3.
    stderr(formatError(module, `internal error: ${e.message}`, e.stack || ""));
    return 3;
  }
}
