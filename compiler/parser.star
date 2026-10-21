# parser.star — tokens to AST.
#
# AST nodes are dicts with "kind" and "pos" (line, col).
#
# Expressions:
#   name {id}  int {val}  string {val}
#   list {elems}  tuple {elems}  dict {entries: [(k, v)]}
#   binop {op, x, y}        op: "or" "and" "==" "!=" "<" ">" "<=" ">=" "in"
#                               "not in" "|" "^" "&" "<<" ">>" "+" "-" "*"
#                               "/" "//" "%"
#   unop {op, x}            op: "-" "+" "~" "not"
#   cond {test, then, else_}
#   call {fn, args}         args: list of {name (or None), star ("", "*", "**"), value}
#   index {x, i}   slice {x, lo, hi, step}  (missing parts are None)
#   dot {x, name}
#   comp {comp: "list"|"dict", body (expr, or (k, v) for dicts), clauses}
#                           clauses: {kind: "for", target, iter} | {kind: "if", test}
#   lambda {params, body}
#
# Statements:
#   def {name, params, body}   params: list of {name, default (or None), star}
#   if {test, body, else_}     (elif becomes a nested if in else_)
#   for {target, iter, body}   while {test, body}
#   return {value}  break  continue  pass
#   assign {op, lhs, rhs}      op: "=" "+=" "-=" ...
#   expr {x}   load {module, names}

load("lexer.star", "lex")

BINOP_PREC = {
    "or": 1,
    "and": 2,
    # 3: not
    "==": 4,
    "!=": 4,
    "<": 4,
    ">": 4,
    "<=": 4,
    ">=": 4,
    "in": 4,
    "not in": 4,
    "|": 5,
    "^": 6,
    "&": 7,
    "<<": 8,
    ">>": 8,
    "+": 9,
    "-": 9,
    "*": 10,
    "/": 10,
    "//": 10,
    "%": 10,
}

AUG_OPS = {
    "=": True,
    "+=": True,
    "-=": True,
    "*=": True,
    "//=": True,
    "/=": True,
    "%=": True,
    "&=": True,
    "|=": True,
    "^=": True,
    "<<=": True,
    ">>=": True,
}

# ---------------------------------------------------------------- token stream

def peek(p):
    return p["toks"][p["i"]]

def peek_kind(p):
    return p["toks"][p["i"]]["kind"]

def peek2_kind(p):
    i = p["i"] + 1
    if i < len(p["toks"]):
        return p["toks"][i]["kind"]
    return "eof"

def advance(p):
    t = p["toks"][p["i"]]
    if t["kind"] != "eof":
        p["i"] += 1
    return t

def describe(t):
    k = t["kind"]
    if k == "name":
        return "identifier " + t["val"]
    if k == "int":
        return "int literal"
    if k == "string":
        return "string literal"
    if k == "bytes":
        return "bytes literal"
    if k == "float":
        return "float literal"
    if k in ("newline", "indent", "dedent", "eof"):
        return k
    return "'" + k + "'"

def error_at(p, t, msg):
    fail(p["file"] + ":" + str(t["line"]) + ":" + str(t["col"]) + ": " + msg)

def expect(p, kind):
    t = peek(p)
    if t["kind"] != kind:
        error_at(p, t, "got " + describe(t) + ", want '" + kind + "'")
    return advance(p)

def accept(p, kind):
    if peek_kind(p) == kind:
        advance(p)
        return True
    return False

def pos(t):
    return (t["line"], t["col"])

def node(kind, t):
    return {"kind": kind, "pos": pos(t)}

# ---------------------------------------------------------------- statements

def parse_file(src, filename):
    p = {"toks": lex(src, filename), "i": 0, "file": filename}
    stmts = []
    while peek_kind(p) != "eof":
        if accept(p, "newline"):
            continue
        parse_statement(p, stmts)
    return stmts

def parse_statement(p, out):
    k = peek_kind(p)
    if k == "def":
        out.append(parse_def(p))
    elif k == "if":
        out.append(parse_if(p))
    elif k == "for":
        t = advance(p)
        n = node("for", t)
        n["target"] = parse_loop_vars(p)
        expect(p, "in")
        n["iter"] = parse_expr(p)
        expect(p, ":")
        n["body"] = parse_suite(p)
        out.append(n)
    elif k == "while":
        t = advance(p)
        n = node("while", t)
        n["test"] = parse_test(p)
        expect(p, ":")
        n["body"] = parse_suite(p)
        out.append(n)
    else:
        parse_simple_line(p, out)

def parse_def(p):
    t = expect(p, "def")
    n = node("def", t)
    n["name"] = expect(p, "name")["val"]
    expect(p, "(")
    n["params"] = parse_params(p, ")")
    expect(p, ")")
    expect(p, ":")
    n["body"] = parse_suite(p)
    return n

def parse_params(p, closer):
    params = []
    while peek_kind(p) != closer:
        t = peek(p)
        if accept(p, "*"):
            if peek_kind(p) == "name":
                params.append({"name": advance(p)["val"], "default": None, "star": "*", "pos": pos(t)})
            else:
                params.append({"name": None, "default": None, "star": "*", "pos": pos(t)})
        elif accept(p, "**"):
            params.append({"name": expect(p, "name")["val"], "default": None, "star": "**", "pos": pos(t)})
        else:
            name = expect(p, "name")["val"]
            default = None
            if accept(p, "="):
                default = parse_test(p)
            params.append({"name": name, "default": default, "star": "", "pos": pos(t)})
        if not accept(p, ","):
            break
    return params

def parse_if(p):
    t = advance(p)  # "if" or "elif"
    n = node("if", t)
    n["test"] = parse_test(p)
    expect(p, ":")
    n["body"] = parse_suite(p)
    n["else_"] = []
    if peek_kind(p) == "elif":
        n["else_"] = [parse_if(p)]
    elif accept(p, "else"):
        expect(p, ":")
        n["else_"] = parse_suite(p)
    return n

def parse_suite(p):
    body = []
    if accept(p, "newline"):
        expect(p, "indent")
        while not accept(p, "dedent"):
            parse_statement(p, body)
    else:
        parse_simple_line(p, body)
    return body

def parse_simple_line(p, out):
    out.append(parse_small(p))
    while accept(p, ";"):
        if peek_kind(p) == "newline":
            break
        out.append(parse_small(p))
    t = peek(p)
    if t["kind"] != "newline" and t["kind"] != "eof":
        error_at(p, t, "got " + describe(t) + ", want newline")
    advance(p)

def parse_small(p):
    t = peek(p)
    k = t["kind"]
    if k == "return":
        advance(p)
        n = node("return", t)
        n["value"] = None
        if peek_kind(p) not in ("newline", ";", "eof"):
            n["value"] = parse_expr(p)
        return n
    if k == "break" or k == "continue" or k == "pass":
        advance(p)
        return node(k, t)
    if k == "load":
        return parse_load(p)
    x = parse_expr(p)
    op = peek_kind(p)
    if AUG_OPS.get(op):
        optok = advance(p)
        n = node("assign", t)
        n["op"] = op
        n["oppos"] = pos(optok)
        n["lhs"] = x
        n["rhs"] = parse_expr(p)
        check_target(p, x, op != "=")
        return n
    n = node("expr", t)
    n["x"] = x
    return n

def parse_load(p):
    t = expect(p, "load")
    n = node("load", t)
    expect(p, "(")
    n["module"] = expect(p, "string")["val"]
    names = []
    while accept(p, ","):
        if peek_kind(p) == ")":
            break
        if peek_kind(p) == "string":
            s = advance(p)["val"]
            names.append((s, s))
        else:
            local = expect(p, "name")["val"]
            expect(p, "=")
            names.append((local, expect(p, "string")["val"]))
    expect(p, ")")
    n["names"] = names
    return n

def check_target(p, x, augmented):
    k = x["kind"]
    if k == "name" or k == "index" or k == "slice" or k == "dot":
        if k == "slice":
            fail(p["file"] + ":" + str(x["pos"][0]) + ":" + str(x["pos"][1]) + ": cannot assign to a slice")
        return
    if (k == "tuple" or k == "list") and not augmented:
        for e in x["elems"]:
            check_target(p, e, False)
        return
    fail(p["file"] + ":" + str(x["pos"][0]) + ":" + str(x["pos"][1]) + ": cannot assign to this expression")

def parse_loop_vars(p):
    """for x, y in ...: parses primary expressions separated by commas."""
    t = peek(p)
    first = parse_primary(p)
    if peek_kind(p) != ",":
        check_target(p, first, False)
        return first
    elems = [first]
    while accept(p, ","):
        if peek_kind(p) == "in":
            break
        elems.append(parse_primary(p))
    n = node("tuple", t)
    n["elems"] = elems
    check_target(p, n, False)
    return n

# ---------------------------------------------------------------- expressions

def parse_expr(p):
    """Expression = Test {',' Test} [','] — a bare tuple if there are commas."""
    t = peek(p)
    x = parse_test(p)
    if peek_kind(p) != ",":
        return x
    elems = [x]
    while accept(p, ","):
        if not starts_test(peek_kind(p)):
            break
        elems.append(parse_test(p))
    n = node("tuple", t)
    n["elems"] = elems
    return n

def starts_test(k):
    return k in ("name", "int", "float", "string", "bytes", "(", "[", "{", "-", "+", "~", "not", "lambda")

def parse_test(p):
    t = peek(p)
    if t["kind"] == "lambda":
        advance(p)
        n = node("lambda", t)
        n["params"] = parse_params(p, ":")
        expect(p, ":")
        n["body"] = parse_test(p)
        return n
    x = parse_binary(p, 1)
    if peek_kind(p) == "if":
        advance(p)
        n = node("cond", t)
        n["then"] = x
        n["test"] = parse_binary(p, 1)
        expect(p, "else")
        n["else_"] = parse_test(p)
        return n
    return x

def peek_binop(p):
    k = peek_kind(p)
    if k == "not" and peek2_kind(p) == "in":
        return "not in"
    if BINOP_PREC.get(k) != None:
        return k
    return None

def parse_binary(p, minprec):
    t = peek(p)
    if minprec <= 3 and t["kind"] == "not":
        advance(p)
        x = node("unop", t)
        x["op"] = "not"
        x["x"] = parse_binary(p, 3)
    else:
        x = parse_unary(p)
    while True:
        op = peek_binop(p)
        if op == None:
            return x
        prec = BINOP_PREC[op]
        if prec < minprec:
            return x
        optok = advance(p)
        if op == "not in":
            optok = advance(p)  # starlark-go reports `not in` at the `in`
        y = parse_binary(p, prec + 1)
        n = node("binop", optok)
        n["op"] = op
        n["x"] = x
        n["y"] = y
        x = n
        if prec == 4:
            nxt = peek_binop(p)
            if nxt != None and BINOP_PREC[nxt] == 4:
                error_at(p, peek(p), "comparison operators are not associative; use parentheses")

def parse_unary(p):
    t = peek(p)
    k = t["kind"]
    if k == "-" or k == "+" or k == "~":
        advance(p)
        n = node("unop", t)
        n["op"] = k
        n["x"] = parse_unary(p)
        return n
    return parse_primary(p)

def parse_primary(p):
    x = parse_operand(p)
    while True:
        t = peek(p)
        k = t["kind"]
        if k == ".":
            advance(p)
            n = node("dot", t)
            n["x"] = x
            n["name"] = expect(p, "name")["val"]
            x = n
        elif k == "(":
            advance(p)
            n = node("call", t)
            n["pos"] = x["pos"]  # compile errors point at the callee...
            n["lparen"] = pos(t)  # ...runtime errors at the "(" (as starlark-go)
            n["fn"] = x
            n["args"] = parse_args(p)
            expect(p, ")")
            x = n
        elif k == "[":
            advance(p)
            x = parse_subscript(p, x, t)
            expect(p, "]")
        else:
            return x

def parse_args(p):
    args = []
    while peek_kind(p) != ")":
        t = peek(p)
        if accept(p, "*"):
            args.append({"name": None, "star": "*", "value": parse_test(p), "pos": pos(t)})
        elif accept(p, "**"):
            args.append({"name": None, "star": "**", "value": parse_test(p), "pos": pos(t)})
        elif t["kind"] == "name" and peek2_kind(p) == "=":
            advance(p)
            advance(p)
            args.append({"name": t["val"], "star": "", "value": parse_test(p), "pos": pos(t)})
        else:
            args.append({"name": None, "star": "", "value": parse_test(p), "pos": pos(t)})
        if not accept(p, ","):
            break
    return args

def parse_subscript(p, x, t):
    lo = None
    if peek_kind(p) != ":":
        lo = parse_test(p)
        if peek_kind(p) != ":":
            if peek_kind(p) == ",":  # x[a, b] indexes with a tuple
                elems = [lo]
                while accept(p, ","):
                    if peek_kind(p) == "]":
                        break
                    elems.append(parse_test(p))
                lo = node("tuple", t)
                lo["elems"] = elems
            n = node("index", t)
            n["x"] = x
            n["i"] = lo
            return n
    n = node("slice", t)
    n["x"] = x
    n["lo"] = lo
    n["hi"] = None
    n["step"] = None
    expect(p, ":")
    if peek_kind(p) != ":" and peek_kind(p) != "]":
        n["hi"] = parse_test(p)
    if accept(p, ":"):
        if peek_kind(p) != "]":
            n["step"] = parse_test(p)
    return n

def parse_operand(p):
    t = peek(p)
    k = t["kind"]
    if k == "name":
        advance(p)
        n = node("name", t)
        n["id"] = t["val"]
        return n
    if k == "int" or k == "float" or k == "string" or k == "bytes":
        advance(p)
        n = node(k, t)
        n["val"] = t["val"]
        return n
    if k == "(":
        advance(p)
        if accept(p, ")"):
            n = node("tuple", t)
            n["elems"] = []
            return n
        x = parse_test(p)
        if peek_kind(p) == ",":
            elems = [x]
            while accept(p, ","):
                if peek_kind(p) == ")":
                    break
                elems.append(parse_test(p))
            x = node("tuple", t)
            x["elems"] = elems
        expect(p, ")")
        return x
    if k == "[":
        advance(p)
        if accept(p, "]"):
            n = node("list", t)
            n["elems"] = []
            return n
        x = parse_test(p)
        if peek_kind(p) == "for":
            n = node("comp", t)
            n["comp"] = "list"
            n["body"] = x
            n["clauses"] = parse_comp_clauses(p)
            expect(p, "]")
            return n
        elems = [x]
        while accept(p, ","):
            if peek_kind(p) == "]":
                break
            elems.append(parse_test(p))
        expect(p, "]")
        n = node("list", t)
        n["elems"] = elems
        return n
    if k == "{":
        advance(p)
        if accept(p, "}"):
            n = node("dict", t)
            n["entries"] = []
            n["colons"] = []
            return n
        key = parse_test(p)
        colon = expect(p, ":")
        val = parse_test(p)
        if peek_kind(p) == "for":
            n = node("comp", t)
            n["comp"] = "dict"
            n["body"] = (key, val)
            n["clauses"] = parse_comp_clauses(p)
            expect(p, "}")
            return n
        entries = [(key, val)]
        colons = [pos(colon)]  # runtime errors for an entry point at its ":"
        while accept(p, ","):
            if peek_kind(p) == "}":
                break
            k2 = parse_test(p)
            colons.append(pos(expect(p, ":")))
            entries.append((k2, parse_test(p)))
        expect(p, "}")
        n = node("dict", t)
        n["entries"] = entries
        n["colons"] = colons
        return n
    error_at(p, t, "got " + describe(t) + ", want primary expression")

def parse_comp_clauses(p):
    clauses = []
    while True:
        t = peek(p)
        if accept(p, "for"):
            target = parse_loop_vars(p)
            expect(p, "in")
            clauses.append({"kind": "for", "target": target, "iter": parse_binary(p, 1), "pos": pos(t)})
        elif accept(p, "if"):
            clauses.append({"kind": "if", "test": parse_binary(p, 1), "pos": pos(t)})
        else:
            return clauses
