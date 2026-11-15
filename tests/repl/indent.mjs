// The indentation that the REPL starts a "..." line with (nextIndent in
// host/repl_core.mjs, which both REPLs use through Session.indent()).
//   node tests/repl/indent.mjs
import assert from "node:assert/strict";
import { needsMore, nextIndent } from "../../host/repl_core.mjs";

// Type lines as a user would: each is what the REPL offered, edited by
// `keys`: "<" is a backspace, anything else is typed. Returns the lines.
function type(steps) {
  const lines = [];
  for (const keys of steps) {
    let line = lines.length ? nextIndent(lines.join("\n")) : "";
    for (const k of keys.match(/<|[^<]+/g) ?? []) line = k === "<" ? line.slice(0, -1) : line + k;
    lines.push(line);
  }
  return lines;
}

// a block indents, a plain line keeps the indent
assert.deepEqual(type(["def f(x):", "for f in range(2):", 'print("wee")', 'print("woo")', ""]),
  ["def f(x):", "\tfor f in range(2):", '\t\tprint("wee")', '\t\tprint("woo")', "\t\t"]);
// ... and the line left empty ends the input
assert.equal(needsMore('def f(x):\n\tprint("wee")\n\t'), false);
// backspace dedents, and the lines after it follow
assert.deepEqual(type(["def f(x):", "for i in range(2):", "print(i)", "<return x", "<g = 1", "h = 2"]),
  ["def f(x):", "\tfor i in range(2):", "\t\tprint(i)", "\treturn x", "g = 1", "h = 2"]);
// the indentation typed is kept as it is
assert.equal(nextIndent("def f(x):\n    if x:"), "    \t");
assert.equal(nextIndent("def f(x):\n    y = x"), "    ");
// a comment after the ":", and a ":" that opens no block
assert.equal(nextIndent("def f(x): # doubles"), "\t");
assert.equal(nextIndent("def f(x):\n\ty = x # a:"), "\t");
assert.equal(nextIndent("def f(x):\n\ty = {1:"), "\t");
assert.equal(nextIndent("x = [1,"), "");
// none inside a triple-quoted string
assert.equal(nextIndent('def f(x):\n\ts = """a:'), "");
assert.equal(nextIndent('def f(x):\n\ts = """a\n\tb"""'), "\t");
console.log("ok");
