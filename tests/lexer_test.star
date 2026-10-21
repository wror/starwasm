# Unit tests for compiler/lexer.star. Run: bin/starhost tests/lexer_test.star

load("../compiler/lexer.star", "lex")

failures = []

def check_eq(what, got, want):
    if got != want:
        failures.append(what + ": got " + repr(got) + ", want " + repr(want))

def kinds(src):
    out = []
    for t in lex(src, "t.star"):
        if t["kind"] in ("name", "int", "string"):
            out.append(t["kind"] + ":" + str(t["val"]))
        else:
            out.append(t["kind"])
    return out

check_eq("simple", kinds("x = 1\n"), ["name:x", "=", "int:1", "newline", "eof"])
# as starlark-go: no newline token for a missing final newline, unless a
# block is open ("dedent at eof")
check_eq("no trailing newline", kinds("x"), ["name:x", "eof"])
check_eq("ints", kinds("0x1F 0o17 0b101 0 42"), ["int:31", "int:15", "int:5", "int:0", "int:42", "eof"])
check_eq("ops", kinds("a//=b<<c!=d"), ["name:a", "//=", "name:b", "<<", "name:c", "!=", "name:d", "eof"])
check_eq("keywords", kinds("not x in y"), ["not", "name:x", "in", "name:y", "eof"])
check_eq("reserved words are tokens", kinds("class x"), ["class", "name:x", "eof"])
check_eq("unicode identifiers", kinds("héllo = 1\n"), ["name:héllo", "=", "int:1", "newline", "eof"])
check_eq(
    "indent",
    kinds("if x:\n  y\n  if z:\n    w\nv\n"),
    ["if", "name:x", ":", "newline", "indent", "name:y", "newline", "if", "name:z", ":", "newline",
     "indent", "name:w", "newline", "dedent", "dedent", "name:v", "newline", "eof"],
)
check_eq(
    "blank and comment lines ignored",
    kinds("def f():\n\n    # hi\n    return 1  # x\n\n"),
    ["def", "name:f", "(", ")", ":", "newline", "indent", "return", "int:1", "newline", "dedent", "eof"],
)
check_eq("brackets join lines", kinds("f(1,\n  2)\n"), ["name:f", "(", "int:1", ",", "int:2", ")", "newline", "eof"])
check_eq("backslash continuation", kinds("x = 1 + \\\n  2\n"), ["name:x", "=", "int:1", "+", "int:2", "newline", "eof"])
check_eq("dedent at eof", kinds("if x:\n    y"), ["if", "name:x", ":", "newline", "indent", "name:y", "newline", "dedent", "eof"])

def strval(src):
    return lex(src, "t.star")[0]["val"]

check_eq("escapes", strval("'a\\tb\\n\\\\\\'\"'"), "a\tb\n\\'\"")
check_eq("double quotes", strval("\"it's\""), "it's")
check_eq("hex escape", strval("'\\x41\\101'"), "AA")
check_eq("unicode escape", strval("'\\u00e9'"), "é")
check_eq("raw", strval("r'a\\nb'"), "a\\nb")
check_eq("triple", strval("'''a\n'b'\nc'''"), "a\n'b'\nc")
check_eq("utf8 literal", strval("'héllo'"), "héllo")

toks = lex("x = 1\n  \ny = '''a\nb'''\nz\n", "t.star")
check_eq("line numbers", [(t["line"], t["col"]) for t in toks if t["kind"] == "name"], [(1, 1), (3, 1), (5, 1)])

# columns count code points, as starlark-go; each token also has its end
toks = lex("s = 'é' + x\n", "t.star")
check_eq("columns in code points", [(t["kind"], t["col"], t["ecol"]) for t in toks[:5]],
         [("name", 1, 2), ("=", 3, 4), ("string", 5, 8), ("+", 9, 10), ("name", 11, 12)])

if failures:
    fail(str(len(failures)) + " failure(s):\n  " + "\n  ".join(failures))
print("lexer_test: ok")
