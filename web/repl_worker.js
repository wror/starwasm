// repl_worker.js — the browser REPL's session (host/repl_core.mjs), in a
// module worker so that a long computation doesn't freeze the page (and
// can be stopped by terminating the worker).
//
// Messages from the page: {type: "init", flags: [...]}, then
// {type: "line", line} for each line typed. To the page: {type: "ready"},
// {type: "echo", text} (the line, after its prompt) before running it,
// {type: "out" | "err", text}, {type: "prompt", more} after each line,
// {type: "fatal", text} if the compiler can't be loaded.
//
// Files live in memory: read_file/write_file and load() see the files
// written in this session (the session file itself is session.star).
// A session with reactive variables is replayed on each update (no
// program is kept alive waiting for input, which would need
// SharedArrayBuffer and so cross-origin isolation).
import { Session } from "./host/repl_core.mjs";

let session = null;
let busy = Promise.resolve();
const post = (m) => postMessage(m);

async function init(flags) {
  let compiler;
  try {
    const res = await fetch("compiler.wasm");
    if (!res.ok) throw new Error(`compiler.wasm: HTTP ${res.status}`);
    compiler = await WebAssembly.compile(await res.arrayBuffer());
  } catch (e) {
    post({
      type: "fatal",
      text: `Can't load the compiler: ${e.message}\n` +
        "starwasm needs WebAssembly GC (Chrome/Edge 119+, Firefox 120+, Safari 18.2+).\n",
    });
    return;
  }
  const files = new Map();
  session = new Session({
    compiler,
    dialectFlags: flags,
    sessionPath: "session.star",
    wasmPath: "session.wasm",
    readFile(p) {
      const f = files.get(p.replace(/^\.\//, ""));
      if (!f) throw new Error(`${p}: no such file`);
      return f;
    },
    writeFile: (p, data) => files.set(p.replace(/^\.\//, ""), data.slice()),
    out: (text) => text && post({ type: "out", text }),
    err: (text) => text && post({ type: "err", text }),
  });
  post({ type: "ready" });
}

onmessage = ({ data: m }) => {
  if (m.type === "init") busy = busy.then(() => init(m.flags));
  else if (m.type === "line") {
    busy = busy.then(async () => {
      let r = null;
      // echoed here, in order with the output of the lines before it
      post({ type: "echo", text: (session?.buffer.length ? "... " : ">>> ") + m.line + "\n" });
      try {
        r = session ? await session.feed(m.line) : null;
      } catch (e) {
        post({ type: "err", text: `internal error: ${e.stack || e}\n` });
      }
      if (r === "quit") post({ type: "out", text: "(nothing to quit in a web page: :reset starts over)\n" });
      post({ type: "prompt", more: r === "more" });
    });
  }
};
