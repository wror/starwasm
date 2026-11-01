# resolve.star — scope analysis before codegen.
#
# Annotates every def, lambda and comprehension node with node["scope"]:
#
#   {"kind": "function" | "comp" | "module",
#    "parent": enclosing scope,
#    "bindings": {name: {"cell": bool, "param": bool}},
#    "free": [names used here but bound in an enclosing function],
#    "free_index": {name: position in free},
#    "wasm": {}}   (filled in by codegen for comprehensions)
#
# A binding is a "cell" when some inner function (def or lambda) refers to
# it: the variable then lives in a heap cell shared with the closure, which
# gives Starlark's late binding. Every function between the use and the
# binding gets the name in its free list, so cells are handed down through
# intermediate closures. Comprehension scopes are compiled into the same
# Wasm function as their parent, so crossing them needs no capture.
#
# Module-level names (globals, top-level defs, builtins) are never captured.

def target_names(t, out):
    """Names bound by assignment target t, appended to out."""
    k = t["kind"]
    if k == "name":
        out.append(t["id"])
    elif k == "tuple" or k == "list":
        for e in t["elems"]:
            target_names(e, out)

def collect_bindings(stmts, out):
    """Names bound anywhere in stmts (not inside nested defs, lambdas or
    comprehensions): out[name] = position of first binding."""
    for s in stmts:
        k = s["kind"]
        names = []
        if k == "assign":
            target_names(s["lhs"], names)
        elif k == "for":
            target_names(s["target"], names)
            collect_bindings(s["body"], out)
        elif k == "if":
            collect_bindings(s["body"], out)
            collect_bindings(s["else_"], out)
        elif k == "while":
            collect_bindings(s["body"], out)
        elif k == "def":
            names.append(s["name"])
        for n in names:
            if n not in out:
                out[n] = s["pos"]

def new_scope(kind, parent):
    return {"kind": kind, "parent": parent, "bindings": {}, "free": [], "free_index": {}, "wasm": {}}

def bind(sc, name, is_param):
    if sc["bindings"].get(name) == None:
        sc["bindings"][name] = {"cell": False, "param": is_param}

def resolve_ref(sc, name):
    crossed = []  # function scopes between the use and the binding
    s = sc
    for _ in range(100000):
        if s == None or s["kind"] == "module":
            break
        b = s["bindings"].get(name)
        if b != None:
            if crossed:
                b["cell"] = True
                for f in crossed:
                    if f["free_index"].get(name) == None:
                        f["free_index"][name] = len(f["free"])
                        f["free"].append(name)
            return
        if s["kind"] == "function":
            crossed.append(s)
        s = s["parent"]

def resolve_module(stmts, filename, reassign = False, repl = False):
    """reassign: the compiler's --globalreassign, starlark-go's
    AllowGlobalReassign: the options GlobalReassign, While and
    TopLevelControl. Without it (the default, as in starlark-go) a
    top-level name may be bound only once, a top-level use of it refers to
    the module's variable even before its binding (a run-time error if not
    yet assigned), and there are no while loops and no if/for at top level. repl (the compiler's --repl, which
    host/repl.mjs passes): `_`, the REPL's last value, may be rebound even
    so."""
    sc = new_scope("module", None)
    sc["file"] = filename  # for errors (rerr)
    sc["reassign"] = reassign
    sc["repl"] = repl
    # first binding of each top-level name: (kind, pos), kind "global" or
    # "local" (a load), for "cannot reassign" (without reassign only)
    sc["first"] = {}
    # names bound by load statements (without reassign: a top-level use
    # before the load fails, see walk_expr)
    sc["loaded"] = {}
    for s in stmts:
        if s["kind"] == "load":
            for local, _ in s["names"]:
                sc["loaded"][local] = True
    # Top-level names bound so far, in source order. With GlobalReassign:
    # a top-level use (outside functions and comprehensions) of a name not
    # bound yet refers to the builtin of that name, or is "undefined"
    # (codegen sees e["early"]).
    sc["seen"] = {}
    sc["order"] = []  # the same names, in order (for spelling hints)
    walk_stmts(stmts, sc)

def bind_top(sc, name, posn, kind):
    """A top-level binding of name at posn (kind "global", or "local" for a
    load): without GlobalReassign, an error if it is already bound (as
    starlark-go's resolver: bind, and bindLocal for loads)."""
    if sc["reassign"] or (sc["repl"] and name == "_"):
        return
    prev = sc["first"].get(name)
    if kind == "local":
        if prev != None and prev[0] == "local":
            rerr(sc, posn, "cannot reassign top-level " + name)
        if prev == None:
            sc["first"][name] = (kind, posn)
        return
    if prev != None:
        rerr(sc, posn, "cannot reassign " + prev[0] + " " + name + " declared at " +
             sc["file"] + ":" + str(prev[1][0]) + ":" + str(prev[1][1]))
    sc["first"][name] = (kind, posn)

def check_control(sc, s, what):
    """starlark-go's TopLevelControl (on with --globalreassign): if, for
    and while only in functions."""
    if not module_of(sc)["reassign"] and runs_at_top(sc):
        rerr(sc, s["pos"], what + " not within a function")

def module_of(sc):
    for _ in range(100000):
        if sc["parent"] == None:
            break
        sc = sc["parent"]
    return sc

def runs_at_top(sc):
    """Whether code in scope sc runs as part of the top level (the module
    or a comprehension in it), not in a function."""
    for _ in range(100000):
        if sc["kind"] == "function":
            return False
        if sc["parent"] == None:
            return True
        sc = sc["parent"]
    return True

def see(sc, name):
    if not sc["seen"].get(name, False):
        sc["seen"][name] = True
        sc["order"].append(name)

def rerr(sc, posn, msg):
    """A static error at posn, as the compiler reports them."""
    for _ in range(100000):
        if sc["parent"] == None:
            break
        sc = sc["parent"]
    fail(sc["file"] + ":" + str(posn[0]) + ":" + str(posn[1]) + ": " + msg)

def check_call_args(sc, e):
    """The order of a call's arguments, as starlark-go's resolver: positional,
    then named (each name once), then *args, then **kwargs."""
    seen_varargs = False
    seen_kwargs = False
    seen = {}
    for a in e["args"]:
        if a["star"] == "**":
            if seen_kwargs:
                rerr(sc, a["pos"], "multiple **kwargs not allowed")
            seen_kwargs = True
        elif a["star"] == "*":
            if seen_kwargs:
                rerr(sc, a["pos"], "*args may not follow **kwargs")
            elif seen_varargs:
                rerr(sc, a["pos"], "multiple *args not allowed")
            seen_varargs = True
        elif a["name"] != None:
            if seen_kwargs:
                rerr(sc, a["pos"], "keyword argument may not follow **kwargs")
            elif seen_varargs:
                rerr(sc, a["pos"], "keyword argument may not follow *args")
            if seen.get(a["name"], False):
                rerr(sc, a["pos"], "keyword argument \"" + a["name"] + "\" is repeated")
            seen[a["name"]] = True
        elif seen_varargs:
            rerr(sc, a["pos"], "positional argument may not follow *args")
        elif seen_kwargs:
            rerr(sc, a["pos"], "positional argument may not follow **kwargs")
        elif seen:
            rerr(sc, a["pos"], "positional argument may not follow named")

def walk_stmts(stmts, sc):
    for s in stmts:
        walk_stmt(s, sc)

def walk_stmt(s, sc):
    k = s["kind"]
    if k == "def":
        if sc["kind"] == "module":
            bind_top(sc, s["name"], s.get("namepos", s["pos"]), "global")
            see(sc, s["name"])
        walk_function(s, sc, s["params"], s["body"], False)
    elif k == "load":
        if sc["kind"] == "module":
            for i, (local, _) in enumerate(s["names"]):
                bind_top(sc, local, s["localpos"][i], "local")
                see(sc, local)
    elif k == "assign":
        walk_expr(s["rhs"], sc)
        check_target(sc, s["lhs"], s["op"] != "=")
        walk_target(s["lhs"], sc)
    elif k == "expr":
        walk_expr(s["x"], sc)
    elif k == "if":
        check_control(sc, s, "if statement")
        walk_expr(s["test"], sc)
        walk_stmts(s["body"], sc)
        walk_stmts(s["else_"], sc)
    elif k == "for":
        check_control(sc, s, "for loop")
        walk_expr(s["iter"], sc)
        check_target(sc, s["target"], False)
        walk_target(s["target"], sc)
        walk_stmts(s["body"], sc)
    elif k == "while":
        if not module_of(sc)["reassign"]:
            rerr(sc, s["pos"], "this Starlark dialect does not support while loops")
        check_control(sc, s, "while loop")
        walk_expr(s["test"], sc)
        walk_stmts(s["body"], sc)
    elif k == "return":
        if s["value"] != None:
            walk_expr(s["value"], sc)

# starlark-go's names for expressions that can't be assigned to
# ("can't assign to callexpr"): its syntax node types, lowercased.
NODE_TYPES = {
    "int": "literal",
    "float": "literal",
    "string": "literal",
    "bytes": "literal",
    "binop": "binaryexpr",
    "unop": "unaryexpr",
    "call": "callexpr",
    "cond": "condexpr",
    "dict": "dictexpr",
    "comp": "comprehension",
    "lambda": "lambdaexpr",
    "slice": "sliceexpr",
}

def start_of(e):
    """Where an expression starts (syntax.Start): its leftmost token."""
    for _ in range(100000):
        k = e["kind"]
        if k == "binop" or k == "index" or k == "slice" or k == "dot":
            e = e["x"]
        elif k == "call":
            e = e["fn"]
        elif k == "cond":
            e = e["then"]
        elif k == "tuple" and e["elems"] and not e.get("paren", False):
            e = e["elems"][0]
        else:
            return e["pos"]
    return e["pos"]

def check_target(sc, t, augmented):
    """An assignment target, as starlark-go's resolver checks it."""
    k = t["kind"]
    if k == "name" or k == "index" or k == "dot":
        return
    if k == "tuple" or k == "list":
        if augmented:
            # a parenthesized tuple starts at its first element (the
            # parentheses are a separate node in starlark-go)
            p = start_of(t["elems"][0]) if k == "tuple" and t["elems"] else t["pos"]
            rerr(sc, p, "can't use " + k + " expression in augmented assignment")
        for e in t["elems"]:
            check_target(sc, e, augmented)
        return
    rerr(sc, start_of(t), "can't assign to " + NODE_TYPES.get(k, k))

def check_params(sc, params):
    """A parameter list, as starlark-go's resolver checks it (messages and
    positions: a name, a default's "=", a "*")."""
    seen = {}
    seen_optional = False
    star = None  # the * or *args parameter
    starstar = None  # the name of **kwargs
    kwonly = 0
    for p in params:
        if p["star"] == "*":
            if starstar != None:
                rerr(sc, p["pos"], "* parameter may not follow **" + starstar)
            elif star != None:
                rerr(sc, p["pos"], "multiple * parameters not allowed")
            else:
                star = p
        elif p["star"] == "**":
            if starstar != None:
                rerr(sc, p["pos"], "multiple ** parameters not allowed")
            starstar = p["name"]
        elif p["default"] != None:
            if starstar != None:
                rerr(sc, p["eqpos"], "optional parameter may not follow **" + starstar)
            elif star != None:
                kwonly += 1
            if seen.get(p["name"], False):
                rerr(sc, p["eqpos"], "duplicate parameter: " + p["name"])
            seen[p["name"]] = True
            seen_optional = True
        else:
            if starstar != None:
                rerr(sc, p["pos"], "required parameter may not follow **" + starstar)
            elif star != None:
                kwonly += 1
            elif seen_optional:
                rerr(sc, p["pos"], "required parameter may not follow optional")
            if seen.get(p["name"], False):
                rerr(sc, p["pos"], "duplicate parameter: " + p["name"])
            seen[p["name"]] = True
    # *args and **kwargs are bound last (starlark-go's order of checks)
    if star != None:
        if star["name"] != None:
            if seen.get(star["name"], False):
                rerr(sc, star["namepos"], "duplicate parameter: " + star["name"])
            seen[star["name"]] = True
        elif kwonly == 0:
            rerr(sc, star["pos"], "bare * must be followed by keyword-only parameters")
    if starstar != None:
        for p in params:
            if p["star"] == "**":
                if seen.get(starstar, False):
                    rerr(sc, p["namepos"], "duplicate parameter: " + starstar)
                seen[starstar] = True

def walk_target(t, sc):
    k = t["kind"]
    if k == "name":
        if sc["kind"] == "module":
            bind_top(sc, t["id"], t["pos"], "global")
            see(sc, t["id"])
        resolve_ref(sc, t["id"])
    elif k == "tuple" or k == "list":
        for e in t["elems"]:
            walk_target(e, sc)
    elif k == "index":
        walk_expr(t["x"], sc)
        walk_expr(t["i"], sc)
    elif k == "dot":
        walk_expr(t["x"], sc)

def walk_function(node, sc, params, body, is_lambda):
    for p in params:
        if p["default"] != None:
            walk_expr(p["default"], sc)  # defaults evaluate in the enclosing scope
    fs = new_scope("function", sc)
    check_params(fs, params)
    for p in params:
        if p["name"] != None:
            bind(fs, p["name"], True)
    if is_lambda:
        walk_expr(body, fs)
    else:
        bound = {}
        collect_bindings(body, bound)
        for name in bound:
            bind(fs, name, False)
        walk_stmts(body, fs)
    node["scope"] = fs

def walk_expr(e, sc):
    k = e["kind"]
    if k == "name":
        if sc["kind"] == "module" and sc["reassign"] and not sc["seen"].get(e["id"], False):
            e["early"] = sc["order"][:]  # the names a hint may suggest
        elif not module_of(sc)["reassign"] and runs_at_top(sc) and module_of(sc)["loaded"].get(e["id"], False) and \
             module_of(sc)["first"].get(e["id"]) == None:
            # a top-level use of a loaded name before its load statement: as
            # starlark-go, "local variable x referenced before assignment"
            # (a load binds in the file block); codegen sees e["preload"]
            e["preload"] = True
        resolve_ref(sc, e["id"])
    elif k == "list" or k == "tuple":
        for x in e["elems"]:
            walk_expr(x, sc)
    elif k == "dict":
        for key, val in e["entries"]:
            walk_expr(key, sc)
            walk_expr(val, sc)
    elif k == "binop":
        walk_expr(e["x"], sc)
        walk_expr(e["y"], sc)
    elif k == "unop":
        walk_expr(e["x"], sc)
    elif k == "cond":
        walk_expr(e["test"], sc)
        walk_expr(e["then"], sc)
        walk_expr(e["else_"], sc)
    elif k == "call":
        walk_expr(e["fn"], sc)
        check_call_args(sc, e)
        for a in e["args"]:
            walk_expr(a["value"], sc)
    elif k == "index":
        walk_expr(e["x"], sc)
        walk_expr(e["i"], sc)
    elif k == "slice":
        walk_expr(e["x"], sc)
        for part in [e["lo"], e["hi"], e["step"]]:
            if part != None:
                walk_expr(part, sc)
    elif k == "dot":
        walk_expr(e["x"], sc)
    elif k == "lambda":
        walk_function(e, sc, e["params"], e["body"], True)
    elif k == "comp":
        cs = new_scope("comp", sc)
        for c in e["clauses"]:
            if c["kind"] == "for":
                names = []
                target_names(c["target"], names)
                for n in names:
                    bind(cs, n, False)
        first = True
        for c in e["clauses"]:
            if c["kind"] == "for":
                # the first iterable is evaluated in the enclosing scope
                walk_expr(c["iter"], sc if first else cs)
                check_target(cs, c["target"], False)
                walk_target(c["target"], cs)
                first = False
            else:
                walk_expr(c["test"], cs)
        if e["comp"] == "dict":
            walk_expr(e["body"][0], cs)
            walk_expr(e["body"][1], cs)
        else:
            walk_expr(e["body"], cs)
        e["scope"] = cs
