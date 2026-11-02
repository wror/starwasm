// repl.js — the browser REPL's page: a terminal over web/repl_worker.js.
//
// The session is saved in localStorage as a journal of the inputs accepted
// (host/repl_core.mjs's Session.journal()), with the dialect, the screen
// and the ↑/↓ history: reloading the page (or Stop) restores it, by
// replaying the journal. :reset clears it, as does a change of dialect.
// (Several tabs share it: the last input saved wins.)
const $ = (id) => document.getElementById(id);
const out = $("out"), input = $("input"), promptEl = $("prompt"), status = $("status");
const term = $("term");

// ---- saved state (all optional: storage may be unavailable or full)

const KEY = "starwasm-repl:";
function load(name) {
  try {
    return JSON.parse(localStorage.getItem(KEY + name));
  } catch {
    return null;
  }
}
function save(name, value) {
  try {
    if (value === null) localStorage.removeItem(KEY + name);
    else localStorage.setItem(KEY + name, JSON.stringify(value));
  } catch {}
}
let saveTimer = null;
const saveScreenSoon = () => {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    // the last 200,000 characters
    let n = 0, at = screen.length;
    while (at > 0 && n + screen[at - 1][1].length <= 200000) n += screen[--at][1].length;
    screen.splice(0, at);
    save("screen", screen);
    save("lines", history.slice(-500));
  }, 300);
};

let worker = null;
let pending = 0; // lines sent, not yet answered with a prompt
let loading = false; // the worker is loading the compiler, restoring the session
const history = Array.isArray(load("lines")) ? load("lines") : [];
let histAt = history.length;
const screen = []; // what is on it: [class, text]

function write(text, cls = "", keep = true) {
  const span = document.createElement("span");
  if (cls) span.className = cls;
  span.textContent = text;
  out.append(span);
  term.scrollTop = term.scrollHeight;
  if (keep) {
    screen.push([cls, text]);
    saveScreenSoon();
  }
}

function setBusy() {
  if (!loading) status.textContent = pending > 0 ? "running…" : "";
  $("stop").disabled = pending === 0 && !loading;
}

function flags() {
  return [...document.querySelectorAll("input[data-flag]")].filter((c) => c.checked).map((c) => c.dataset.flag);
}

function start(note) {
  if (worker) worker.terminate();
  pending = 0;
  promptEl.textContent = ">>> ";
  if (note) write(note, "note");
  const saved = load("journal");
  const journal = saved && JSON.stringify(saved.flags) === JSON.stringify(flags()) ? saved.journal : null;
  loading = true;
  status.textContent = journal ? "restoring the session…" : "loading the compiler…";
  input.disabled = true;
  worker = new Worker("repl_worker.js", { type: "module" });
  worker.onmessage = ({ data: m }) => {
    if (m.type === "ready") {
      loading = false;
      setBusy();
      input.disabled = false;
      input.focus();
    } else if (m.type === "restored") {
      if (m.error) {
        write(`(the saved session no longer runs, so it was dropped:)\n${m.error}`, "err");
        save("journal", null);
      } else if (m.count) {
        write(`(restored ${m.count} input${m.count === 1 ? "" : "s"}; :history lists them, :reset starts over)\n`, "note");
      }
    } else if (m.type === "journal") {
      save("journal", m.journal.history.length ? { flags: flags(), journal: m.journal } : null);
    } else if (m.type === "echo") write(m.text, "echo");
    else if (m.type === "out") write(m.text);
    else if (m.type === "err") write(m.text, "err");
    else if (m.type === "fatal") {
      write(m.text, "err");
      loading = false;
      setBusy();
    } else if (m.type === "prompt") {
      pending--;
      if (pending === 0) promptEl.textContent = m.more ? "... " : ">>> ";
      setBusy();
    }
  };
  worker.onerror = (e) => {
    write(`worker error: ${e.message}\n`, "err");
    loading = false;
    setBusy();
  };
  worker.postMessage({ type: "init", flags: flags(), journal });
  setBusy();
}

// (the worker echoes the line when it gets to it)
function send(line) {
  pending++;
  setBusy();
  worker.postMessage({ type: "line", line });
}

input.addEventListener("keydown", (e) => {
  if (e.key === "Enter") {
    e.preventDefault();
    const line = input.value;
    input.value = "";
    if (line.trim() !== "" && history[history.length - 1] !== line) history.push(line);
    histAt = history.length;
    send(line);
  } else if (e.key === "ArrowUp" && histAt > 0) {
    e.preventDefault();
    input.value = history[--histAt];
  } else if (e.key === "ArrowDown") {
    e.preventDefault();
    histAt = Math.min(history.length, histAt + 1);
    input.value = history[histAt] ?? "";
  } else if (e.key === "l" && e.ctrlKey) {
    e.preventDefault();
    out.textContent = "";
    screen.length = 0;
    saveScreenSoon();
  }
});

// pasting several lines types each of them
input.addEventListener("paste", (e) => {
  const text = e.clipboardData.getData("text");
  if (!text.includes("\n")) return;
  e.preventDefault();
  const lines = (input.value + text).replace(/\r\n?/g, "\n").split("\n");
  input.value = lines.pop();
  for (const line of lines) send(line);
});

term.addEventListener("click", () => {
  if (!getSelection().toString()) input.focus();
});

// Stop: the input running is dropped (it isn't in the journal); stopping
// the restore drops the saved session
$("stop").addEventListener("click", () => {
  if (loading && load("journal")) {
    save("journal", null);
    start("\n(stopped restoring; the session starts over)\n");
  } else start("\n(stopped)\n");
});
for (const c of document.querySelectorAll("input[data-flag]")) {
  c.addEventListener("change", () => {
    save("journal", null);
    start(`\n(dialect: ${flags().join(" ") || "default"}; the session starts over)\n`);
  });
}
for (const b of document.querySelectorAll("[data-example]")) {
  b.addEventListener("click", () => {
    for (const line of b.dataset.example.split("\n")) send(line);
    input.focus();
  });
}

// the previous visit: its dialect and screen
const saved = load("journal");
if (saved && Array.isArray(saved.flags)) {
  for (const c of document.querySelectorAll("input[data-flag]")) c.checked = saved.flags.includes(c.dataset.flag);
}
const shown = load("screen");
if (Array.isArray(shown)) for (const [cls, text] of shown) if (typeof text === "string") write(text, cls);
start();
