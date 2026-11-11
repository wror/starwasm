// Tab completion in the REPL (Session.complete in host/repl_core.mjs, which
// the browser REPL's Tab key uses): prints, for each line completed, where
// the completed text starts and the candidates; test.sh compares that with
// tests/repl/complete.out.
//   node tests/repl/complete.mjs [compiler.wasm]
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { loadModule } from "../../host/wasmhost.mjs";
import { compileStar, defaultCompiler } from "../../host/wasmcache.mjs";
import { Session } from "../../host/repl_core.mjs";

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
const show = async (text) => {
  const r = await session.complete(text);
  console.log(`${JSON.stringify(text)} @${r.from}: ` + r.items.map((i) => i.name + (i.detail ? ": " + i.detail : "")).join(" | "));
};

for (const line of [
  'box = struct(width = 2, height = 3, name = "box")',
  "boxes = [box]",
  "def area(s):",
  "    return s.width * s.height",
  "",
  'sizes = {"k": [1]}',
]) await session.feed(line);

for (const text of [
  "box.", // the fields of a struct, with their types
  "box.w",
  "box.name.up", // the methods of the field's type
  "boxes[0].he",
  "print(box.na",
  "x = 1 + box.",
  'sizes.get("k").', // T | None: the methods of T, for this receiver
  '"x".st',
  ":type box.h",
  "bo", // names: the session's, and builtins
  "ar",
  "ret", // keywords
  ":t", // commands
  "area(box).", // an int: nothing
  "zz",
  "1.",
  "nosuch.",
  "box.width", // already complete
  "",
]) await show(text);

// in a block being typed: also the names in its lines
await session.feed("def scaled(point, factor):");
await show("    return po");
await show("    return point."); // (its type is not known before the block ends)
