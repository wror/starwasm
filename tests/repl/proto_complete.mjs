// Tab completion of proto values in the REPL (Session.complete, with a
// descriptor set: the checker types them from the schema). test.sh
// compares the output with tests/repl/proto_complete.out.
//   node tests/repl/proto_complete.mjs [compiler.wasm]
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { loadModule } from "../../host/wasmhost.mjs";
import { compileStar, defaultCompiler } from "../../host/wasmcache.mjs";
import { Session } from "../../host/repl_core.mjs";

const files = new Map();
const compilerBytes = process.argv[2] ? readFileSync(process.argv[2]) : null;
const session = new Session({
  compiler: loadModule(compilerBytes ?? defaultCompiler()),
  descriptorSet: "tests/proto/test.binpb",
  sessionPath: "session.star",
  wasmPath: "session.wasm",
  readFile: (p) => files.get(p) ?? readFileSync(p),
  writeFile: (p, data) => files.set(p, data),
  out: () => {},
  err: (t) => process.stdout.write(t),
  checker: () => loadModule(compileStar(fileURLToPath(new URL("../../typecheck/main.star", import.meta.url)), ["--recursion"], compilerBytes)),
});
await session.feed('p3 = proto.file("p3.proto")');
await session.feed('n = p3.Node(name = "x")');
for (const text of [
  "p3.", // a file's messages and enums
  "p3.Node.", // a message descriptor's nested types and fields
  "n.", // a message's fields
  "n.inner.k",
  "p3.Color.", // an enum's values
  "p3.Color.RED.",
  "n.kids.", // a repeated field: append
  "proto.", // the module's functions
  "p3.Scalars(i32 = 1, ", // a message's fields, as keyword arguments
]) {
  const r = await session.complete(text);
  console.log(`${JSON.stringify(text)} @${r.from}: ` + r.items.map((i) => i.name + (i.detail ? ": " + i.detail : "")).join(" | "));
}
