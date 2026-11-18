// repl.js — the browser REPL's page: a terminal over web/repl_worker.js.
//
// The session is saved in localStorage as a journal of the inputs accepted
// (host/repl_core.mjs's Session.journal()), with the dialect, the screen
// and the ↑/↓ history: reloading the page (or Stop) restores it, by
// replaying the journal. :reset clears it and the screen (not the ↑/↓
// history), as does a change of dialect (the session only).
// (Several tabs share it: the last input saved wins.)
import { pastedInput } from "./host/repl_core.mjs";

const $ = (id) => document.getElementById(id);
const out = $("out"), input = $("input"), promptEl = $("prompt"), status = $("status");
const term = $("term"), edit = input.parentElement, marksEl = $("marks"), tip = $("tip");

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
function saveScreen() {
  // the last 200,000 characters
  let n = 0, at = screen.length;
  while (at > 0 && n + screen[at - 1][1].length <= 200000) n += screen[--at][1].length;
  screen.splice(0, at);
  save("screen", screen);
  save("lines", history.slice(-500));
}
// Ctrl-L, :reset: also the screen saved
function clearScreen() {
  out.textContent = "";
  screen.length = 0;
  clearTimeout(saveTimer);
  saveScreen();
}
let saveTimer = null;
const saveScreenSoon = () => {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveScreen, 300);
};
// (and right away when the page goes: a reload within 300 ms)
addEventListener("pagehide", () => {
  clearTimeout(saveTimer);
  saveScreen();
});

let worker = null;
let pending = 0; // lines sent, not yet answered with a prompt
let loading = false; // the worker is loading the compiler, restoring the session
const history = Array.isArray(load("lines")) ? load("lines") : [];
let histAt = history.length;
const screen = []; // what is on it: [class, text, marks] (marks: of an echoed line with type errors)

// Show text in el, the characters [from, to) of each of marks ([{from,
// to, message}]) as a type error, which says its message when pointed at.
function render(el, text, marks) {
  el.textContent = "";
  let at = 0;
  for (const m of [...marks].sort((a, b) => a.from - b.from || b.to - a.to)) {
    const from = Math.max(at, m.from), to = Math.min(m.to, text.length);
    if (from >= to) {
      // (inside the one before: its message too)
      if (el.lastChild?.dataset && !el.lastChild.dataset.message.includes(m.message)) el.lastChild.dataset.message += "\n\n" + m.message;
      continue;
    }
    el.append(text.slice(at, from));
    const span = document.createElement("span");
    span.className = "terr";
    span.dataset.message = m.message;
    span.textContent = text.slice(from, to);
    el.append(span);
    at = to;
  }
  el.append(text.slice(at));
}

function write(text, cls = "", keep = true, marks = null) {
  const span = document.createElement("span");
  if (cls) span.className = cls;
  if (marks?.length) render(span, text, marks);
  else span.textContent = text;
  out.append(span);
  term.scrollTop = term.scrollHeight;
  const entry = marks?.length ? [cls, text, marks] : [cls, text];
  if (keep) {
    screen.push(entry);
    saveScreenSoon();
  }
  return { span, entry };
}

// ---- type errors (Session.diagnose in host/repl_core.mjs, by the type
// checker): marked in the lines of the input being typed, those entered
// (echoed) and the one in the input field, which is checked when typing
// pauses. The message shows when the pointer is on a mark.

const PROMPT = 4; // the length of ">>> " and "... ", before an echoed line
let echoes = []; // the lines echoed of the input being typed: what write() returned
let checkTimer = null;
let checking = null; // the check requested: {id, text}
let checkId = 0;

// Mark what the checker found in the input, marks: [{line, from, to,
// message}], the last line being `typed` (the input field's, or null: all
// were entered). The lines entered keep their marks if it found nothing,
// which is also what it says of an input that doesn't parse yet.
function mark(marks, typed) {
  const of = (n) => marks.filter((m) => m.line === n);
  if (marks.length) {
    echoes.forEach(({ span, entry }, n) => {
      const text = entry[1];
      entry[2] = of(n).map((m) => ({ from: m.from + PROMPT, to: m.to + PROMPT, message: m.message }));
      if (!entry[2].length) entry.length = 2;
      render(span, text, entry[2] ?? []);
    });
    saveScreenSoon();
  }
  if (typed === null) return;
  const mine = of(echoes.length);
  edit.classList.toggle("marked", mine.length > 0);
  render(marksEl, typed, mine);
  marksEl.scrollLeft = input.scrollLeft;
}
// The input field changed: its marks are of the text before; check again
// once typing pauses.
function edited() {
  clearTimeout(checkTimer);
  checking = null;
  hideTip();
  edit.classList.remove("marked");
  marksEl.textContent = "";
  if (input.value.trim() === "") return;
  checkTimer = setTimeout(() => {
    if (!worker || loading || pending > 0) return; // (a prompt checks again)
    checking = { id: ++checkId, text: input.value };
    worker.postMessage({ type: "check", ...checking });
  }, 200);
}
input.addEventListener("input", edited);
input.addEventListener("scroll", () => (marksEl.scrollLeft = input.scrollLeft));

function showTip(el) {
  if (tip.textContent !== el.dataset.message) tip.textContent = el.dataset.message;
  tip.style.display = "block";
  // below the mark, or above it at the bottom of the window
  const r = el.getBoundingClientRect(), t = tip.getBoundingClientRect();
  tip.style.left = `${Math.max(8, Math.min(r.left, innerWidth - t.width - 8))}px`;
  tip.style.top = `${r.bottom + 6 + t.height > innerHeight ? Math.max(8, r.top - 6 - t.height) : r.bottom + 6}px`;
}
function hideTip() {
  tip.style.display = "none";
}
out.addEventListener("pointerover", (e) => {
  const el = e.target.closest?.(".terr");
  if (el) showTip(el);
  else hideTip();
});
out.addEventListener("pointerleave", hideTip);
// (the marks of the input field are under the pointer, but not its target)
input.addEventListener("pointermove", (e) => {
  const el = [...marksEl.querySelectorAll(".terr")].find((s) => {
    const r = s.getBoundingClientRect();
    return e.clientX >= r.left && e.clientX < r.right && e.clientY >= r.top && e.clientY < r.bottom;
  });
  if (el) showTip(el);
  else hideTip();
});
input.addEventListener("pointerleave", hideTip);
term.addEventListener("scroll", hideTip);

function setBusy() {
  if (!loading) status.textContent = pending > 0 ? "running…" : "";
  $("stop").disabled = pending === 0 && !loading;
}

function flags() {
  // (a toggle may stand for several options)
  return [...document.querySelectorAll("input[data-flag]")].filter((c) => c.checked).flatMap((c) => c.dataset.flag.split(" "));
}

function start(note) {
  if (worker) worker.terminate();
  pending = 0;
  echoes = [];
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
      // (not on a touch screen, where focus raises the keyboard and hides
      // the controls before anything is tapped)
      if (!matchMedia("(pointer: coarse)").matches) input.focus();
    } else if (m.type === "restored") {
      if (m.error) {
        write(`(the saved session no longer runs, so it was dropped:)\n${m.error}`, "err");
        save("journal", null);
      } else if (m.count) {
        write(`(restored ${m.count} input${m.count === 1 ? "" : "s"}; :history lists them, :reset starts over)\n`, "note");
      }
    } else if (m.type === "journal") {
      save("journal", m.journal.history.length ? { flags: flags(), journal: m.journal } : null);
    } else if (m.type === "clear") clearScreen();
    else if (m.type === "completions") completed(m);
    else if (m.type === "checked") {
      // (not if the line changed since, or was entered)
      if (checking && m.id === checking.id && input.value === checking.text && pending === 0) mark(m.marks, input.value);
    } else if (m.type === "echo") {
      echoes.push(write(m.text, "echo"));
      mark(m.marks ?? [], null);
    }
    else if (m.type === "out") {
      const { span } = write(m.text);
      // :help taller than the terminal (a phone's): show it from its start
      if (m.text.startsWith("Starlark REPL on")) {
        const r = span.getBoundingClientRect();
        if (r.height > term.clientHeight - 40) term.scrollTop += r.top - term.getBoundingClientRect().top - 12;
      }
    }
    else if (m.type === "err") write(m.text, "err");
    else if (m.type === "fatal") {
      write(m.text, "err");
      loading = false;
      setBusy();
    } else if (m.type === "prompt") {
      pending--;
      if (!m.more) echoes = []; // the next line starts another input
      if (pending === 0) {
        promptEl.textContent = m.more ? "... " : ">>> ";
        // a "..." line starts at the block's indent (Session.indent()),
        // unless something was typed meanwhile; backspace removes it
        if (m.indent && input.value === "") input.value = m.indent;
        edited(); // (what was typed meanwhile is checked now)
      }
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

// ---- Tab completion: the worker asks the session (Session.complete in
// host/repl_core.mjs: after a "." the fields and methods that the type
// checker finds for the expression before it, else the names in scope).
// One candidate is inserted; of several, what they have in common, and if
// that adds nothing they are listed (with their types, if few).

let asked = null; // the completion requested: {id, text, cursor}
function complete() {
  if (!worker || loading) return;
  const text = input.value, cursor = input.selectionStart ?? text.length;
  if (/^\s*$/.test(text.slice(0, cursor))) {
    // at the start of a line Tab indents (a block's lines), with a tab as
    // the indentation that "..." lines start with
    input.setRangeText("\t", cursor, input.selectionEnd ?? cursor, "end");
    edited();
    return;
  }
  asked = { id: (asked?.id ?? 0) + 1, text, cursor };
  worker.postMessage({ type: "complete", ...asked });
}
function completed(m) {
  // (not if the line changed since)
  if (!asked || m.id !== asked.id || input.value !== asked.text || m.items.length === 0) return;
  const names = m.items.map((it) => it.name);
  let common = names[0];
  for (const n of names) while (!n.startsWith(common)) common = common.slice(0, -1);
  if (common.length > m.to - m.from) {
    input.setRangeText(common, m.from, m.to, "end");
    edited();
    return;
  }
  const detailed = m.items.length <= 12 && m.items.some((it) => it.detail);
  const list = detailed
    ? m.items.map((it) => `  ${it.label ?? it.name}${it.detail ? (it.label ? " " : ": ") + it.detail : ""}\n`).join("")
    : "  " + m.items.map((it) => it.label ?? it.name).join("  ") + "\n";
  write(list, "note", false);
}
$("tab").addEventListener("pointerdown", (e) => e.preventDefault()); // keep the input's focus and cursor
$("tab").addEventListener("click", () => {
  complete();
  input.focus();
});
// Clear: as Ctrl-L (the screen; the session is kept), without taking the
// focus from the input (on a phone, the keyboard stays up)
$("clear").addEventListener("pointerdown", (e) => e.preventDefault());
$("clear").addEventListener("click", () => {
  clearScreen();
  input.focus();
});

input.addEventListener("keydown", (e) => {
  if (e.key === "Tab" && !e.shiftKey && !e.ctrlKey && !e.altKey && !e.metaKey) {
    e.preventDefault();
    complete();
  } else if (e.key === "Enter") {
    e.preventDefault();
    const line = input.value;
    input.value = "";
    if (line.trim() !== "" && history[history.length - 1] !== line) history.push(line);
    histAt = history.length;
    edited();
    send(line);
  } else if (e.key === "ArrowUp" && histAt > 0) {
    e.preventDefault();
    input.value = history[--histAt];
    edited();
  } else if (e.key === "ArrowDown") {
    e.preventDefault();
    histAt = Math.min(history.length, histAt + 1);
    input.value = history[histAt] ?? "";
    edited();
  } else if (e.key === "l" && e.ctrlKey) {
    e.preventDefault();
    clearScreen();
  }
});

// Pasting several lines types each of them. Of text copied from a REPL
// session (lines with the ">>> " prompt) those are the lines typed there,
// without their prompts, and not what the REPL printed (pastedInput in
// host/repl_core.mjs).
input.addEventListener("paste", (e) => {
  const text = e.clipboardData.getData("text");
  const typed = pastedInput(text);
  if (typed === text && !text.includes("\n")) return;
  e.preventDefault();
  if (!typed.includes("\n")) {
    input.setRangeText(typed, input.selectionStart, input.selectionEnd, "end");
    edited();
    return;
  }
  // (lines pasted have their own indentation: not after the block's)
  const lines = ((input.value.trim() === "" ? "" : input.value) + typed).split("\n");
  input.value = lines.pop();
  edited();
  for (const line of lines) send(line);
});

// A click in the terminal focuses the input line, unless it selected text.
// On a touch screen, only a short tap does: a long press may start
// selecting the output to copy (iOS ends it with a click), and focusing the
// input would drop that selection.
let pointer = { type: "mouse", at: 0 };
term.addEventListener("pointerdown", (e) => (pointer = { type: e.pointerType, at: e.timeStamp }));
term.addEventListener("click", (e) => {
  if (getSelection().toString()) return;
  if (pointer.type !== "mouse" && e.timeStamp - pointer.at > 400) return;
  input.focus();
});

// Typing shows the end of the session: focusing the input scrolls the
// terminal to the bottom, after the controls hide (on a touch screen) and
// as the on-screen keyboard comes up.
const bottom = () => (term.scrollTop = term.scrollHeight);
input.addEventListener("focus", () => {
  requestAnimationFrame(bottom);
  setTimeout(bottom, 400); // (the keyboard's animation)
});
window.visualViewport?.addEventListener("resize", () => {
  if (document.activeElement === input) bottom();
});

// iOS zooms the page in to focus a text field with text under 16px (the
// input's is 14px), and leaves it zoomed. maximum-scale stops that; iOS
// still lets the user zoom by pinching.
if (/iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)) {
  const vp = document.querySelector('meta[name="viewport"]');
  vp.content += ", maximum-scale=1";
}

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
    // (no focus to the input: on a phone that would raise the keyboard
    // over the example's output)
    for (const line of b.dataset.example.split("\n")) send(line);
  });
}

// the previous visit: its dialect and screen
const saved = load("journal");
let dropped = [];
if (saved && Array.isArray(saved.flags)) {
  // (a session saved when the globalreassign toggle was that option alone
  // runs as well with --globalredefine, which the toggle now adds)
  for (const c of document.querySelectorAll("input[data-flag]")) c.checked = c.dataset.flag.split(" ").some((f) => saved.flags.includes(f));
  // (a session saved with an option no toggle offers any more, such as
  // --recursion, may not run without it: it starts over)
  const offered = new Set([...document.querySelectorAll("input[data-flag]")].flatMap((c) => c.dataset.flag.split(" ")));
  dropped = saved.flags.filter((f) => !offered.has(f));
  if (dropped.length) save("journal", null);
  else if (JSON.stringify(saved.flags) !== JSON.stringify(flags())) save("journal", { ...saved, flags: flags() });
}
const shown = load("screen");
if (Array.isArray(shown)) for (const [cls, text, marks] of shown) if (typeof text === "string") write(text, cls, true, Array.isArray(marks) ? marks : null);
start(dropped.length ? `\n(the saved session used ${dropped.join(" ")}, which this REPL no longer offers; the session starts over)\n` : undefined);
