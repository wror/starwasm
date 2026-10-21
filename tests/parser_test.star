# Unit tests for compiler/parser.star. Run: bin/starhost tests/parser_test.star

load("../compiler/parser.star", "parse_file")

failures = []

def check_eq(what, got, want):
    if got != want:
        failures.append(what + ": got " + repr(got) + ", want " + repr(want))

def sx(n):
    """Compact s-expression rendering of an expression AST."""
    if type(n) == "list":
        return " ".join([sx(e) for e in n])
    k = n["kind"]
    if k == "name":
        return n["id"]
    if k == "int":
        return str(n["val"])
    if k == "string":
        return repr(n["val"])
    if k == "binop":
        return "(" + n["op"] + " " + sx(n["x"]) + " " + sx(n["y"]) + ")"
    if k == "unop":
        return "(" + n["op"] + " " + sx(n["x"]) + ")"
    if k == "cond":
        return "(if " + sx(n["test"]) + " " + sx(n["then"]) + " " + sx(n["else_"]) + ")"
    if k == "tuple" or k == "list":
        return k + "[" + sx(n["elems"]) + "]"
    if k == "dict":
        return "dict[" + " ".join([sx(a) + ":" + sx(b) for a, b in n["entries"]]) + "]"
    if k == "call":
        parts = []
        for a in n["args"]:
            parts.append(a["star"] + (a["name"] + "=" if a["name"] else "") + sx(a["value"]))
        return "(call " + sx(n["fn"]) + (" " if parts else "") + " ".join(parts) + ")"
    if k == "index":
        return "(index " + sx(n["x"]) + " " + sx(n["i"]) + ")"
    if k == "slice":
        return "(slice " + sx(n["x"]) + " " + " ".join([sx(e) if e else "_" for e in [n["lo"], n["hi"], n["step"]]]) + ")"
    if k == "dot":
        return "(. " + sx(n["x"]) + " " + n["name"] + ")"
    if k == "comp":
        out = "(" + n["comp"] + "comp "
        out += sx(n["body"][0]) + ":" + sx(n["body"][1]) if n["comp"] == "dict" else sx(n["body"])
        for c in n["clauses"]:
            if c["kind"] == "for":
                out += " for " + sx(c["target"]) + " in " + sx(c["iter"])
            else:
                out += " if " + sx(c["test"])
        return out + ")"
    if k == "lambda":
        return "(lambda " + " ".join([q["name"] for q in n["params"]]) + ": " + sx(n["body"]) + ")"
    return "<" + k + ">"

def expr(src):
    stmts = parse_file(src, "t.star")
    return sx(stmts[0]["x"])

check_eq("precedence", expr("1 + 2 * 3 - 4"), "(- (+ 1 (* 2 3)) 4)")
check_eq("unary binds tight", expr("-x * y"), "(* (- x) y)")
check_eq("not is low", expr("not a == b"), "(not (== a b))")
check_eq("and/or", expr("a or b and not c"), "(or a (and b (not c)))")
check_eq("not in", expr("x not in y"), "(not in x y)")
check_eq("bit ops", expr("a | b ^ c & d << 1"), "(| a (^ b (& c (<< d 1))))")
check_eq("cond", expr("a if b else c if d else e"), "(if b a (if d c e))")
check_eq("calls", expr("f(1, x=2, *a, **k)"), "(call f 1 x=2 *a **k)")
check_eq("postfix chain", expr("a.b(c)[d][1:-1:2]"), "(slice (index (call (. a b) c) d) 1 (- 1) 2)")
check_eq("slices", expr("s[:2]"), "(slice s _ 2 _)")
check_eq("slice step only", expr("s[::-1]"), "(slice s _ _ (- 1))")
check_eq("tuples", expr("(1,)"), "tuple[1]")
check_eq("paren", expr("(1)"), "1")
check_eq("bare tuple", expr("1, 2,"), "tuple[1 2]")
check_eq("literals", expr("[1, 'a', {}, {1: 2,}]"), 'list[1 "a" dict[] dict[1:2]]')
check_eq("listcomp", expr("[x * 2 for x in xs if x for y in x]"), "(listcomp (* x 2) for x in xs if x for y in x)")
check_eq("dictcomp", expr("{k: v for k, v in d.items()}"), "(dictcomp k:v for tuple[k v] in (call (. d items)))")
check_eq("lambda", expr("lambda a, b: a + b"), "(lambda a b: (+ a b))")

stmts = parse_file("""
def f(a, b = 1, *rest):
    if a:
        return
    elif b: pass
    else:
        x, y = 1, 2
        x += 1
    for i, j in z:
        break
    while x: continue
""", "t.star")
f = stmts[0]
check_eq("def params", [(q["name"], q["star"], q["default"] != None) for q in f["params"]], [("a", "", False), ("b", "", True), ("rest", "*", False)])
body = f["body"]
check_eq("stmt kinds", [s["kind"] for s in body], ["if", "for", "while"])
check_eq("elif nests", body[0]["else_"][0]["kind"], "if")
check_eq("else body", [s["kind"] for s in body[0]["else_"][0]["else_"]], ["assign", "assign"])
check_eq("aug op", body[0]["else_"][0]["else_"][1]["op"], "+=")
check_eq("for target", sx(body[1]["target"]), "tuple[i j]")

# Error positions.
def parse_err(src):
    # Errors fail(); we can't catch them in Starlark, so only test a valid
    # neighbor here. Error messages are covered by tests/compile_errors.
    return src

# Stress test: every .star file in the project must parse.
for path in [
    "lib/wasm.star", "lib/dsl.star", "lib/runtime.star", "lib/builtins.star",
    "compiler/lexer.star", "compiler/parser.star", "compiler/codegen.star", "compiler/main.star",
    "examples/demo.star", "tests/runtime/build.star", "tests/runtime/expect.star",
    "tests/lexer_test.star", "tests/parser_test.star", "tests/wasm_test.star",
]:
    parse_file(read_file(path), path)

if failures:
    fail(str(len(failures)) + " failure(s):\n  " + "\n  ".join(failures))
print("parser_test: ok")
