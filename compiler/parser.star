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
#   def {name, params, body}   params: list of {name, default (or None), star,
#                              pos, eqpos (a default's "=")}
#   if {test, body, else_}     (elif becomes a nested if in else_)
#   for {target, iter, body}   while {test, body}
#   return {value}  break  continue  pass
#   assign {op, lhs, rhs}      op: "=" "+=" "-=" ...
#   expr {x}   load {module, names}

# A port of starlark-go's parser (go.starlark.net/syntax/parse.go): the same
# grammar, error messages and positions. Assignment targets and parameter
# lists are checked by resolve.star, as starlark-go's resolver does.

load("lexer.star", "lex")

# Binary operator precedence levels, as starlark-go's preclevels (2 is
# unary "not").
PREC = {
    "or": 0,
    "and": 1,
    "==": 3,
    "!=": 3,
    "<": 3,
    ">": 3,
    "<=": 3,
    ">=": 3,
    "in": 3,
    "not in": 3,
    "|": 4,
    "^": 5,
    "&": 6,
    "<<": 7,
    ">>": 7,
    "-": 8,
    "+": 8,
    "*": 9,
    "%": 9,
    "/": 9,
    "//": 9,
}
NUM_PREC = 10

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

# How starlark-go's errors name a token (Token.GoString): punctuation is
# quoted, keywords are bare, and a bytes literal has no name at all.
TOKEN_NAMES = {
    "name": "identifier",
    "int": "int literal",
    "float": "float literal",
    "string": "string literal",
    "bytes": "",
    "newline": "newline",
    "indent": "indent",
    "dedent": "outdent",
    "eof": "end of file",
}

def token_name(kind):
    n = TOKEN_NAMES.get(kind)
    if n != None:
        return n
    if kind[0] >= "a" and kind[0] <= "z":
        return kind  # a keyword (or "not in")
    return "'" + kind + "'"

# Tokens that end a comma-separated list of expressions (terminatesExprList).
EXPR_LIST_END = {"eof": True, "newline": True, "=": True, "}": True, "]": True, ")": True, ";": True}

# ---------------------------------------------------------------- token stream

def peek(p):
    return p["toks"][p["i"]]

def tok(p):
    return p["toks"][p["i"]]["kind"]

def advance(p):
    """Consume the lookahead token; returns it."""
    t = p["toks"][p["i"]]
    if t["kind"] != "eof":
        p["i"] += 1
    return t

def fail_at(p, line, col, msg):
    fail(p["file"] + ":" + str(line) + ":" + str(col) + ": " + msg)

def error_here(p, msg):
    """An error where starlark-go's scanner stands: just after the
    lookahead token (p.in.pos)."""
    t = peek(p)
    fail_at(p, t["eline"], t["ecol"], msg)

def error_at(p, t, msg):
    """An error at the start of token t."""
    fail_at(p, t["line"], t["col"], msg)

def consume(p, kind):
    if tok(p) != kind:
        error_here(p, "got " + token_name(tok(p)) + ", want " + token_name(kind))
    return advance(p)

def pos(t):
    return (t["line"], t["col"])

def node(kind, t):
    return {"kind": kind, "pos": pos(t)}

# ---------------------------------------------------------------- statements

def parse_file(src, filename):
    p = {"toks": lex(src, filename), "i": 0, "file": filename}
    stmts = []
    for _ in range(len(p["toks"]) + 1):
        if tok(p) == "eof":
            break
        if tok(p) == "newline":
            advance(p)
            continue
        parse_stmt(p, stmts)
    return stmts

def parse_stmt(p, out):
    k = tok(p)
    if k == "def":
        out.append(parse_def(p))
    elif k == "if":
        out.append(parse_if(p))
    elif k == "for":
        t = advance(p)
        n = node("for", t)
        n["target"] = parse_for_loop_vars(p)
        consume(p, "in")
        n["iter"] = parse_expr(p, False)
        consume(p, ":")
        n["body"] = parse_suite(p)
        out.append(n)
    elif k == "while":
        t = advance(p)
        n = node("while", t)
        n["test"] = parse_test(p)
        consume(p, ":")
        n["body"] = parse_suite(p)
        out.append(n)
    else:
        parse_simple_stmt(p, out, True)

def parse_def(p):
    t = advance(p)
    n = node("def", t)
    n["name"] = parse_ident(p)["val"]
    consume(p, "(")
    n["params"] = parse_params(p)
    consume(p, ")")
    consume(p, ":")
    n["body"] = parse_suite(p)
    return n

def parse_params(p):
    params = []
    for _ in range(len(p["toks"])):
        k = tok(p)
        if k == ")" or k == ":" or k == "eof":
            break
        if params:
            consume(p, ",")
        if tok(p) == ")":
            break
        t = peek(p)
        if t["kind"] == "*" or t["kind"] == "**":
            advance(p)
            name = None
            namepos = None
            if t["kind"] == "**" or tok(p) == "name":
                nt = parse_ident(p)
                name = nt["val"]
                namepos = pos(nt)
            params.append({"name": name, "default": None, "star": t["kind"], "pos": pos(t), "namepos": namepos})
            continue
        name = parse_ident(p)["val"]
        if tok(p) == "=":
            eq = advance(p)
            params.append({"name": name, "default": parse_test(p), "star": "", "pos": pos(t), "eqpos": pos(eq)})
            continue
        params.append({"name": name, "default": None, "star": "", "pos": pos(t)})
    return params

def parse_if(p):
    t = advance(p)  # "if" or "elif"
    n = node("if", t)
    n["test"] = parse_test(p)
    consume(p, ":")
    n["body"] = parse_suite(p)
    n["else_"] = []
    if tok(p) == "elif":
        n["else_"] = [parse_if(p)]
    elif tok(p) == "else":
        advance(p)
        consume(p, ":")
        n["else_"] = parse_suite(p)
    return n

def parse_suite(p):
    body = []
    if tok(p) == "newline":
        advance(p)
        consume(p, "indent")
        for _ in range(len(p["toks"])):
            if tok(p) == "dedent" or tok(p) == "eof":
                break
            parse_stmt(p, body)
        consume(p, "dedent")
        return body
    parse_simple_stmt(p, body, True)
    return body

def parse_for_loop_vars(p):
    """for x, y in ...: primary expressions separated by commas."""
    t = peek(p)
    first = parse_primary_with_suffix(p)
    if tok(p) != ",":
        return first
    elems = [first]
    for _ in range(len(p["toks"])):
        if tok(p) != ",":
            break
        advance(p)
        if EXPR_LIST_END.get(tok(p), False):
            break
        elems.append(parse_primary_with_suffix(p))
    n = node("tuple", t)
    n["elems"] = elems
    return n

def parse_simple_stmt(p, out, consume_nl):
    for _ in range(len(p["toks"])):
        out.append(parse_small_stmt(p))
        if tok(p) != ";":
            break
        advance(p)
        if tok(p) == "newline" or tok(p) == "eof":
            break
    if tok(p) != "eof" and consume_nl:
        consume(p, "newline")

def parse_small_stmt(p):
    t = peek(p)
    k = t["kind"]
    if k == "return":
        advance(p)
        n = node("return", t)
        n["value"] = None
        if tok(p) != "eof" and tok(p) != "newline" and tok(p) != ";":
            n["value"] = parse_expr(p, False)
        return n
    if k == "break" or k == "continue" or k == "pass":
        advance(p)
        return node(k, t)
    if k == "load":
        return parse_load(p)
    x = parse_expr(p, False)
    op = tok(p)
    if AUG_OPS.get(op, False):
        optok = advance(p)
        n = node("assign", t)
        n["op"] = op
        n["oppos"] = pos(optok)
        n["lhs"] = x
        n["rhs"] = parse_expr(p, False)
        return n
    n = node("expr", t)
    n["x"] = x
    return n

def parse_load(p):
    t = advance(p)
    n = node("load", t)
    lparen = consume(p, "(")
    if tok(p) != "string":
        error_here(p, "first operand of load statement must be a string literal")
    n["module"] = advance(p)["val"]
    names = []
    namepos = []  # of each original name, just inside its quote (as starlark-go)
    for _ in range(len(p["toks"])):
        if tok(p) == ")" or tok(p) == "eof":
            break
        consume(p, ",")
        if tok(p) == ")":
            break  # trailing comma
        k = tok(p)
        if k == "string":
            st = advance(p)
            names.append((st["val"], st["val"]))
            namepos.append((st["line"], st["col"] + 1))
        elif k == "name":
            local = parse_ident(p)["val"]
            if tok(p) != "=":
                error_here(p, "load operand must be \"" + local + "\" or " + local + "=\"originalname\" (want '=' after " + local + ")")
            consume(p, "=")
            if tok(p) != "string":
                error_here(p, "original name of loaded symbol must be quoted: " + local + "=\"originalname\"")
            st = advance(p)
            names.append((local, st["val"]))
            namepos.append((st["line"], st["col"] + 1))
        else:
            error_here(p, "load operand must be \"name\" or localname=\"name\" (got " + token_name(k) + ")")
    consume(p, ")")
    if not names:
        error_at(p, lparen, "load statement must import at least 1 symbol")
    n["names"] = names
    n["namepos"] = namepos
    return n

def parse_ident(p):
    if tok(p) != "name":
        error_here(p, "not an identifier")
    return advance(p)

# ---------------------------------------------------------------- expressions

def parse_expr(p, in_parens):
    """Test {',' Test}: a tuple if there are commas; a trailing comma only
    in parentheses."""
    t = peek(p)
    x = parse_test(p)
    if tok(p) != ",":
        return x
    n = node("tuple", t)
    n["elems"] = parse_exprs(p, [x], in_parens)
    return n

def parse_exprs(p, elems, allow_trailing_comma):
    for _ in range(len(p["toks"])):
        if tok(p) != ",":
            break
        comma = advance(p)
        if EXPR_LIST_END.get(tok(p), False):
            if not allow_trailing_comma:
                error_at(p, comma, "unparenthesized tuple with trailing comma")
            break
        elems.append(parse_test(p))
    return elems

def parse_test(p):
    t = peek(p)
    if t["kind"] == "lambda":
        return parse_lambda(p, True)
    x = parse_test_prec(p, 0)
    if tok(p) == "if":
        iftok = advance(p)
        test = parse_test_prec(p, 0)
        if tok(p) != "else":
            error_at(p, iftok, "conditional expression without else clause")
        advance(p)
        n = node("cond", t)
        n["then"] = x
        n["test"] = test
        n["else_"] = parse_test(p)
        return n
    return x

def parse_test_nocond(p):
    """A test without an unparenthesized conditional (parseTestNoCond), as
    after a comprehension's "if"."""
    if tok(p) == "lambda":
        return parse_lambda(p, False)
    return parse_test_prec(p, 0)

def parse_lambda(p, allow_cond):
    """lambda params: body; without allow_cond the body may not be an
    unparenthesized conditional."""
    t = advance(p)
    n = node("lambda", t)
    n["params"] = [] if tok(p) == ":" else parse_params(p)
    consume(p, ":")
    n["body"] = parse_test(p) if allow_cond else parse_test_nocond(p)
    return n

def parse_test_prec(p, prec):
    if prec >= NUM_PREC:
        return parse_primary_with_suffix(p)
    t = peek(p)
    if t["kind"] == "not" and prec == 2:
        advance(p)
        n = node("unop", t)
        n["op"] = "not"
        n["x"] = parse_test_prec(p, prec)
        return n
    return parse_binop_expr(p, prec)

def parse_binop_expr(p, prec):
    x = parse_test_prec(p, prec + 1)
    first = True
    for _ in range(len(p["toks"])):
        if tok(p) == "not":
            advance(p)
            if tok(p) != "in":
                error_here(p, "got " + token_name(tok(p)) + ", want in")
            peek(p)["kind"] = "not in"  # the "in" is the operator "not in" now
        op = tok(p)
        opprec = PREC.get(op, -1)
        if opprec < prec:
            return x
        if not first and opprec == 3:
            error_here(p, x["op"] + " does not associate with " + op + " (use parens)")
        optok = advance(p)
        n = node("binop", optok)  # at the operator ("in" of "not in"), as starlark-go
        n["op"] = op
        n["x"] = x
        n["y"] = parse_test_prec(p, opprec + 1)
        x = n
        first = False
    return x

def parse_primary_with_suffix(p):
    x = parse_primary(p)
    for _ in range(len(p["toks"])):
        t = peek(p)
        k = t["kind"]
        if k == ".":
            advance(p)
            n = node("dot", t)
            n["x"] = x
            n["name"] = parse_ident(p)["val"]
            x = n
        elif k == "[":
            x = parse_slice_suffix(p, x)
        elif k == "(":
            advance(p)
            n = node("call", t)
            n["pos"] = x["pos"]  # compile errors point at the callee...
            n["lparen"] = pos(t)  # ...runtime errors at the "(" (as starlark-go)
            n["fn"] = x
            n["args"] = []
            if tok(p) == ")":
                advance(p)
            else:
                n["args"] = parse_args(p)
                consume(p, ")")
            x = n
        else:
            return x
    return x

def parse_slice_suffix(p, x):
    t = advance(p)  # "["
    lo = None
    if tok(p) != ":":
        y = parse_expr(p, False)  # x[a, b] indexes with a tuple; x[a, b:] slices from one
        if tok(p) == "]":
            advance(p)
            n = node("index", t)
            n["x"] = x
            n["i"] = y
            return n
        lo = y
    n = node("slice", t)
    n["x"] = x
    n["lo"] = lo
    n["hi"] = None
    n["step"] = None
    if tok(p) == ":":
        advance(p)
        if tok(p) != ":" and tok(p) != "]":
            n["hi"] = parse_test(p)
    if tok(p) == ":":
        advance(p)
        if tok(p) != "]":
            n["step"] = parse_test(p)
    consume(p, "]")
    return n

def parse_args(p):
    args = []
    for _ in range(len(p["toks"])):
        if tok(p) == ")" or tok(p) == "eof":
            break
        if args:
            consume(p, ",")
        if tok(p) == ")":
            break
        t = peek(p)
        if t["kind"] == "*" or t["kind"] == "**":
            advance(p)
            args.append({"name": None, "star": t["kind"], "value": parse_test(p), "pos": pos(t)})
            continue
        x = parse_test(p)
        if tok(p) == "=":
            if x["kind"] != "name":
                error_here(p, "keyword argument must have form name=expr")
            advance(p)
            args.append({"name": x["id"], "star": "", "value": parse_test(p), "pos": pos(t)})
            continue
        args.append({"name": None, "star": "", "value": x, "pos": pos(t)})
    return args

def parse_primary(p):
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
    if k == "[":
        return parse_list(p)
    if k == "{":
        return parse_dict(p)
    if k == "(":
        advance(p)
        if tok(p) == ")":
            advance(p)
            n = node("tuple", t)
            n["elems"] = []
            return n
        x = parse_expr(p, True)
        if x["kind"] == "tuple":
            x["pos"] = pos(t)  # a parenthesized tuple is at its "("
            x["paren"] = True
        consume(p, ")")
        return x
    if k == "-" or k == "+" or k == "~":
        advance(p)
        n = node("unop", t)
        n["op"] = k
        n["x"] = parse_primary_with_suffix(p)
        return n
    error_at(p, t, "got " + token_name(k) + ", want primary expression")

def parse_list(p):
    t = advance(p)
    if tok(p) == "]":
        advance(p)
        n = node("list", t)
        n["elems"] = []
        return n
    x = parse_test(p)
    if tok(p) == "for":
        n = node("comp", t)
        n["comp"] = "list"
        n["body"] = x
        n["clauses"] = parse_comp_clauses(p, "]")
        return n
    elems = [x]
    if tok(p) == ",":
        parse_exprs(p, elems, True)
    consume(p, "]")
    n = node("list", t)
    n["elems"] = elems
    return n

def parse_dict(p):
    t = advance(p)
    if tok(p) == "}":
        advance(p)
        n = node("dict", t)
        n["entries"] = []
        n["colons"] = []
        return n
    key = parse_test(p)
    colon = consume(p, ":")
    val = parse_test(p)
    if tok(p) == "for":
        n = node("comp", t)
        n["comp"] = "dict"
        n["body"] = (key, val)
        n["colon"] = pos(colon)  # where errors setting an entry point
        n["clauses"] = parse_comp_clauses(p, "}")
        return n
    entries = [(key, val)]
    colons = [pos(colon)]  # runtime errors for an entry point at its ":"
    for _ in range(len(p["toks"])):
        if tok(p) != ",":
            break
        advance(p)
        if tok(p) == "}":
            break
        k2 = parse_test(p)
        colons.append(pos(consume(p, ":")))
        entries.append((k2, parse_test(p)))
    consume(p, "}")
    n = node("dict", t)
    n["entries"] = entries
    n["colons"] = colons
    return n

def parse_comp_clauses(p, end):
    """The for/if clauses of a comprehension, and its closing bracket."""
    clauses = []
    for _ in range(len(p["toks"])):
        t = peek(p)
        k = t["kind"]
        if k == end:
            break
        if k == "for":
            advance(p)
            target = parse_for_loop_vars(p)
            consume(p, "in")
            clauses.append({"kind": "for", "target": target, "iter": parse_test_prec(p, 0), "pos": pos(t)})
        elif k == "if":
            advance(p)
            clauses.append({"kind": "if", "test": parse_test_nocond(p), "pos": pos(t)})
        else:
            error_here(p, "got " + token_name(k) + ", want '" + end + "', for, or if")
    advance(p)
    return clauses
