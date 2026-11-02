// The REPL session as the browser runs it (web/repl_worker.js): files in
// memory (reading falls back to the disk, for load()), and no live
// programs, so each update replays the session. Feeds standard input to
// it and prints the transcript (stdout and stderr together), which must
// equal host/repl.mjs's (tests/repl/session.out). Then the session, saved
// (journal()) and restored into a new one, as the page does on a reload,
// must be the same: if not, that is printed too.
//   node tests/repl/browser_mode.mjs [compiler.wasm] < tests/repl/session.in
import { readFileSync } from "node:fs";
import { loadModule } from "../../host/wasmhost.mjs";
import { defaultCompiler } from "../../host/wasmcache.mjs";
import { Session } from "../../host/repl_core.mjs";

const files = new Map();
const compiler = loadModule(process.argv[2] ? readFileSync(process.argv[2]) : defaultCompiler());
const session = new Session({
  compiler,
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

const restored = new Session({ ...session, out: () => {}, err: () => {} });
Object.assign(restored, { history: [], printed: "", live: null, inputNum: 0, buffer: [] });
const j = JSON.parse(JSON.stringify(session.journal()));
const error = await restored.restore(j);
if (error || restored.printed !== session.printed || restored.inputNum !== session.inputNum ||
    JSON.stringify(restored.history) !== JSON.stringify(session.history)) {
  process.stdout.write(`restore: different session${error ? `: ${error}` : ""}\n`);
}
