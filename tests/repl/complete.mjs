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
const feed = async (lines) => {
  for (const line of lines) await session.feed(line);
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
await show("    return point."); // a parameter: nothing is known of it yet

// ... and after a ".", what the checker knows at that point of the block:
// loop variables, locals, and the fields a parameter was used with so far
await session.feed("    for b in boxes:");
await show("        b.");
await show("        total = factor * b.he");
await session.feed("        label = b.name");
await show("        label.sp");
await session.feed("        w = point.width + point.depth");
await show("    return point.");
await show("    return sizes.");
await show("return box."); // (a line that doesn't fit the block: as at top level)
await session.feed("    return (label,");
await show("        box."); // (in an open bracket: as at top level)

// keyword arguments: where an argument of a call starts, the parameters
// the call can name (not those given already), then the names
await feed(["        label)", ""]);
await feed(["def greet(name, punctuation = \"!\", *rest, loud = False):", "    return name + punctuation", ""]);
await show("greet(");
await show("greet(\"a\", pu");
await show("greet(\"a\", punctuation = \"?\", ");
await show("greet(name = box.name, l");
await show("x = [greet(n");
await show("greet(\"a\" + n"); // not where an argument starts: names only
await show("greet(len(boxes), ");
await show("sorted(boxes, "); // a builtin: its keyword-only parameters
await show("sorted(boxes, key = lambda b: b.width, r");
await show("(lambda first, second: first)(");
await show("box.name.split("); // a method: positional
await show("print(greet(");
await show("len(");
// ... in a call that goes on over several lines, and in a block
await feed(["greet(", "    \"a\","]);
await show("    ");
await show("    lo");
await feed(["    loud = True)"]);
await feed(["def outer(prefix):", "    def inner(text, width = 10):", "        return prefix + text"]);
await show("    inner(");
await show("    return inner(prefix, w");
