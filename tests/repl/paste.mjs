// Text pasted into the REPL (pastedInput in host/repl_core.mjs, which both
// REPLs use): of text copied from a REPL session, the lines typed there.
//   node tests/repl/paste.mjs
import assert from "node:assert/strict";
import { pastedInput } from "../../host/repl_core.mjs";

// a session: the lines typed, without prompts; not the lines printed
assert.equal(pastedInput('>>> def f(x):\n... \tfor i in range(2):\n... \t\tprint("wee")\n... \n>>> f(1)\nwee\nwee\n>>> 1 + 1\n2\n'),
  'def f(x):\n\tfor i in range(2):\n\t\tprint("wee")\n\nf(1)\n1 + 1\n');
// ... ending with a line typed, not entered yet
assert.equal(pastedInput(">>> x = 1\n>>> x\n1\n>>> x + 1"), "x = 1\nx\nx + 1");
// ... ending with what was printed: the last line typed is entered
assert.equal(pastedInput(">>> x = 1\n>>> x\n1"), "x = 1\nx\n");
// ... starting with what was printed, with \r\n, indented, and with the
// space after an empty "..." trimmed
assert.equal(pastedInput("3\r\n>>> def f():\r\n...     return 1\r\n...\r\n"), "def f():\n    return 1\n\n");
assert.equal(pastedInput("  >>> x = 1\n  >>> x\n  1\n"), "x = 1\nx\n");
// one line
assert.equal(pastedInput(">>> f(1)"), "f(1)");
// not a session: as it is
assert.equal(pastedInput("def f(x):\n    return x >> 1\n\nf(2)\n"), "def f(x):\n    return x >> 1\n\nf(2)\n");
assert.equal(pastedInput("x = [1,\n... ]"), "x = [1,\n... ]");
assert.equal(pastedInput("f(1)"), "f(1)");
console.log("ok");
