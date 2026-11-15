// The type errors that the browser REPL marks in what is typed
// (Session.diagnose and diagnosticRange in host/repl_core.mjs).
//   node tests/repl/diagnose.mjs [compiler.wasm]
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { loadModule } from "../../host/wasmhost.mjs";
import { compileStar, defaultCompiler } from "../../host/wasmcache.mjs";
import { diagnosticRange, Session } from "../../host/repl_core.mjs";

// what a diagnostic at the "^" is about
const range = (line, caret) => line.slice(...diagnosticRange(line, caret.indexOf("^")));
assert.equal(range('total = 1 + "one"',
                   "          ^"), '1 + "one"');
assert.equal(range("    return x.upper() + 1",
                   "                     ^"), "x.upper() + 1");
assert.equal(range('x = [f(a), b[0]] + -g("a)", 2).h + 1',
                   "                 ^"), '[f(a), b[0]] + -g("a)", 2).h');
assert.equal(range("a <= not b.c",
                   "  ^"), "a <= not b.c");
assert.equal(range("box.nme + 1",
                   "   ^"), ".nme");
assert.equal(range('area("box", 2)',
                   "     ^"), '"box"');
assert.equal(range("f(nosuch.x)",
                   "  ^"), "nosuch");
assert.equal(range("f([1, 2], 3)",
                   "  ^"), "[1, 2]");
assert.equal(range("x = 12", "         ^"), "2"); // (past the end: the last character)
assert.deepEqual(diagnosticRange("", 0), [0, 1]);

const files = new Map();
const compilerBytes = process.argv[2] ? readFileSync(process.argv[2]) : null;
const session = new Session({
  compiler: loadModule(compilerBytes ?? defaultCompiler()),
  sessionPath: "session.star",
  wasmPath: "session.wasm",
  readFile: (p) => files.get(p) ?? readFileSync(p),
  writeFile: (p, data) => files.set(p, data),
  out: () => {},
  err: (t) => process.stdout.write(t),
  checker: () => loadModule(compileStar(fileURLToPath(new URL("../../typecheck/main.star", import.meta.url)), ["--recursion"], compilerBytes)),
});
// the marks of a line typed now: [line of the input, text marked, message]
const marks = async (line) => (await session.diagnose(line)).map((m) =>
  [m.line, [...session.buffer, line][m.line].slice(m.from, m.to), m.message]);
for (const l of ["def area(shape):", "\treturn shape.width * shape.height", "", 'box = struct(width = 2, height = 3, name = "box")']) await session.feed(l);

assert.deepEqual(await marks("area(box) + 1"), []);
assert.deepEqual(await marks('total = 1 + "one"'), [[0, '1 + "one"', "cannot apply + to int and str"]]);
assert.deepEqual(await marks("nosuch"), [[0, "nosuch", "undefined: nosuch"]]);
// the checker's notes follow its message
assert.deepEqual(await marks("box.nme"), [[0, ".nme", "struct has no field 'nme' (did you mean 'name'?); it has 'width', 'height', 'name'\n" +
  "note: the struct is struct[width: int, height: int, name: str] (a struct made here) (input 2, line 1)"]]);
assert.deepEqual((await marks('area("box")')).map((m) => m[1]), ['"box"']);
// not parsed (yet), commands, nothing typed: no marks
assert.deepEqual(await marks("area("), []);
assert.deepEqual(await marks("1 +"), []);
assert.deepEqual(await marks(":type box.nme"), []);
assert.deepEqual(await marks("  "), []);
// in a block being typed: in its lines, also those entered
await session.feed("def bad(x):");
assert.deepEqual(await marks("\treturn x.upper() + 1"), [[1, "x.upper() + 1", "cannot apply + to str and int"]]);
await session.feed("\ty = x.upper() + 1");
assert.deepEqual(await marks("\treturn area(y)"), [[1, "x.upper() + 1", "cannot apply + to str and int"]]);
// nothing was run or added to the session
assert.equal(session.history.length, 2);
console.log("ok");
