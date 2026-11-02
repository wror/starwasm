// The REPL session as the browser runs it (web/repl_worker.js): files in
// memory (reading falls back to the disk, for load()), and no live
// programs, so each update replays the session. Feeds standard input to
// it and prints the transcript (stdout and stderr together), which must
// equal host/repl.mjs's (tests/repl/session.out).
//   node tests/repl/browser_mode.mjs [compiler.wasm] < tests/repl/session.in
import { readFileSync } from "node:fs";
import { loadModule } from "../../host/wasmhost.mjs";
import { defaultCompiler } from "../../host/wasmcache.mjs";
import { Session } from "../../host/repl_core.mjs";

const files = new Map();
const session = new Session({
  compiler: loadModule(process.argv[2] ? readFileSync(process.argv[2]) : defaultCompiler()),
  sessionPath: "session.star",
  wasmPath: "session.wasm",
  readFile: (p) => files.get(p) ?? readFileSync(p),
  writeFile: (p, data) => files.set(p, data),
  out: (t) => process.stdout.write(t),
  err: (t) => process.stdout.write(t),
});
const lines = readFileSync(0, "utf8").replace(/\n$/, "").split("\n");
for (const line of lines) if ((await session.feed(line)) === "quit") break;
await session.finish();
