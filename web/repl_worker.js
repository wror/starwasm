// repl_worker.js — the browser REPL's session (host/repl_core.mjs), in a
// module worker so that a long computation doesn't freeze the page (and
// can be stopped by terminating the worker).
//
// Messages from the page: {type: "init", flags: [...], journal}, journal
// being a saved session (host/repl_core.mjs's Session.journal()) or null,
// then {type: "line", line} for each line typed. To the page:
// {type: "restored", count, error} after restoring the journal (error:
// null, or why the session couldn't be restored), {type: "ready"},
// {type: "echo", text} (the line, after its prompt) before running it,
// {type: "out" | "err", text}, {type: "prompt", more} after each line,
// {type: "fatal", text} if the compiler can't be loaded, and
// {type: "journal", journal} whenever the inputs accepted change, to save:
// the session's journal() plus `files`, the files in memory (base64), which
// the restore needs before replaying: the session's load()s are compiled
// before it runs the write_file()s that make them.
//
// Files live in memory: read_file/write_file and load() see the files
// written in this session (the session file itself is session.star).
// A session with reactive variables is replayed on each update (no
// program is kept alive waiting for input, which would need
// SharedArrayBuffer and so cross-origin isolation).
import { Session } from "./host/repl_core.mjs";

let session = null;
const files = new Map();
const SESSION_FILES = new Set(["session.star", "session.wasm"]);

function toBase64(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
const fromBase64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
let busy = Promise.resolve();
const post = (m) => postMessage(m);

async function init(flags, journal) {
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
    onChange() {
      const saved = {};
      for (const [p, data] of files) if (!SESSION_FILES.has(p)) saved[p] = toBase64(data);
      post({ type: "journal", journal: { ...session.journal(), files: saved } });
    },
  });
  if (journal) {
    let error;
    try {
      for (const [p, data] of Object.entries(journal.files ?? {})) files.set(p, fromBase64(data));
      error = await session.restore(journal);
    } catch (e) {
      error = `${e.message}\n`;
    }
    post({ type: "restored", count: error ? 0 : journal.history.length, error });
  }
  post({ type: "ready" });
}

onmessage = ({ data: m }) => {
  if (m.type === "init") busy = busy.then(() => init(m.flags, m.journal));
  else if (m.type === "line") {
    busy = busy.then(async () => {
      let r = null;
      // echoed here, in order with the output of the lines before it
      post({ type: "echo", text: (session?.buffer.length ? "... " : ">>> ") + m.line + "\n" });
      try {
        r = session ? await session.feed(m.line) : null;
      } catch (e) {
        // (Safari's stack has no message)
        const stack = e.stack && !e.stack.includes(e.message) ? `${e}\n${e.stack}` : e.stack || e;
        post({ type: "err", text: `internal error: ${stack}\n` });
      }
      if (r === "quit") post({ type: "out", text: "(nothing to quit in a web page: :reset starts over)\n" });
      post({ type: "prompt", more: r === "more" });
    });
  }
};
