// repl.js — the browser REPL's page: a terminal over web/repl_worker.js.
const $ = (id) => document.getElementById(id);
const out = $("out"), input = $("input"), promptEl = $("prompt"), status = $("status");
const term = $("term");

let worker = null;
let pending = 0; // lines sent, not yet answered with a prompt
const history = [];
let histAt = 0;

function write(text, cls) {
  const span = document.createElement("span");
  if (cls) span.className = cls;
  span.textContent = text;
  out.append(span);
  term.scrollTop = term.scrollHeight;
}

function setBusy() {
  status.textContent = pending > 0 ? "running…" : "";
  $("stop").disabled = pending === 0;
}

function flags() {
  return [...document.querySelectorAll("input[data-flag]")].filter((c) => c.checked).map((c) => c.dataset.flag);
}

function start(note) {
  if (worker) worker.terminate();
  pending = 0;
  promptEl.textContent = ">>> ";
  if (note) write(note, "note");
  status.textContent = "loading the compiler…";
  input.disabled = true;
  worker = new Worker("repl_worker.js", { type: "module" });
  worker.onmessage = ({ data: m }) => {
    if (m.type === "ready") {
      status.textContent = "";
      input.disabled = false;
      input.focus();
    } else if (m.type === "echo") write(m.text, "echo");
    else if (m.type === "out") write(m.text);
    else if (m.type === "err") write(m.text, "err");
    else if (m.type === "fatal") {
      write(m.text, "err");
      status.textContent = "";
    } else if (m.type === "prompt") {
      pending--;
      if (pending === 0) promptEl.textContent = m.more ? "... " : ">>> ";
      setBusy();
    }
  };
  worker.onerror = (e) => {
    write(`worker error: ${e.message}\n`, "err");
    status.textContent = "";
  };
  worker.postMessage({ type: "init", flags: flags() });
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

$("stop").addEventListener("click", () => start("\n(stopped; the session starts over)\n"));
for (const c of document.querySelectorAll("input[data-flag]")) {
  c.addEventListener("change", () => start(`\n(dialect: ${flags().join(" ") || "default"}; the session starts over)\n`));
}
for (const b of document.querySelectorAll("[data-example]")) {
  b.addEventListener("click", () => {
    for (const line of b.dataset.example.split("\n")) send(line);
    input.focus();
  });
}

start();
