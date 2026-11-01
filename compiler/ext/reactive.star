# ext/reactive.star — reactive variables (EXTENSIONS.md).
#
#   x : 1                 # a reactive variable (top level of the main file)
#   y : x * 10            # recomputed whenever x changes
#   print("y is", y)      # re-run whenever y changes
#
# A program with reactive variables doesn't exit at the end of its top
# level: it reads lines like `x = 5` or `x = f(4)` from standard input, sets the
# variables, and recomputes everything that depends on them, transitively.
#
# Almost all of it is Starlark: the checks and the rewriting of the program
# are done here, on the AST, before anything is compiled, and the loop that
# reads standard input, parses and evaluates the new values and propagates
# changes is the Starlark in RUNTIME below, added to the prelude. The Wasm part is three
# small primitives: read a line, write to stderr, and call a function so
# that a Starlark error is reported without stopping the program.
#
# The rewriting (transform), on the main module:
#   - reactive values live in a dict, the module variable "%reactive" ("%"
#     names can't be written in source), created by a first statement;
#   - every read of a reactive variable becomes %reactive["x"];
#   - `x : e` becomes `%reactive["x"] = e`, in place, so the first run is
#     the program as written (same order, same tracebacks);
#   - each reactive definition, and each top-level expression statement
#     that reads reactive variables (an "observer", e.g. print(y)), also
#     gets a function "%r.<n>" evaluating a copy of its expression
#     (displayed as <toplevel> in tracebacks), defined right after it and appended to "%nodes" as (name or None,
#     function, names of the reactive variables it reads), so %nodes lists
#     what the top level has run so far, in source order;
#   - a last statement calls the prelude's _reactive_input(..., 0) (as
#     "%prelude._reactive_input"), which
#     applies input lines until the end of standard input;
#   - sync points: every top-level statement after the first reactive
#     definition is preceded by _reactive_input(..., L), L being its line,
#     which applies the input lines the host says are due before line L.
#     host/run.mjs has none (standard input applies after the top level);
#     the REPL (host/repl.mjs) replays a session's updates this way, each
#     right after the input it followed.
# A reactive variable may only be read after its definition (or in it, as
# its previous value: see "self-reference" below), so source
# order is a topological order of the dependencies, and an update is one
# pass over %nodes.

load("../../lib/dsl.star", "arr_len", "arr_new_default", "arr_set", "as_", "call", "drop", "field", "get", "gget", "gset", "i32", "if_", "new", "null", "op", "ret", "set", "while_")
load("../../lib/runtime.star", "S")
load("../../lib/wasm.star", "EQREF", "I32", "add_func", "import_func", "ref")
load("../parser.star", "parse_file")
load("../resolve.star", "collect_bindings", "target_names")

V = EQREF
U8A = ref("U8")
STR = ref("Str")

# Primitives for RUNTIME (see EXT_INTRINSICS in compiler/extensions.star):
#   _read_line(before)   the next line of standard input (without the line
#                  end), or None: at its end if before is 0, else if the
#                  host has no line due before source line `before`
#   _eprint(s)     write str(s) and a newline to standard error
#   _try(f)        call f(); if it fails, print the traceback to standard
#                  error and return False (else True)
INTRINSICS = {
    "_read_line": ("rt_read_line", 1, 1),
    "_eprint": ("rt_eprint", 1, 1),
    "_try": ("rt_try", 1, 1),
}

VALUES = "%reactive"  # module variable holding the reactive values
NODES = "%nodes"  # module variable listing what to recompute
STATE = "%rstate"  # module variable: {"lineno": input lines read}
NAMES = "%rnames"  # module variable: what input expressions can use

# Builtins that expressions on standard input may use (struct only in
# programs that mention it: it makes method calls check for structs).
INPUT_BUILTINS = ["abs", "all", "any", "bool", "bytes", "chr", "dict", "enumerate", "fail", "float", "getattr",
                  "hasattr", "hash", "int", "len", "list", "max", "min", "ord", "print", "range", "repr",
                  "reversed", "set", "sorted", "str", "tuple", "type", "zip"]

# ---------------------------------------------------------------- checks

def _err(mod, posn, msg):
    """A compile error, in the compiler's format."""
    fail(mod["path"] + ":" + str(posn[0]) + ":" + str(posn[1]) + ": " + msg)

def _nested_reactive(stmts):
    """The first `name : expr` statement inside a block of stmts, or None."""
    for s in stmts:
        k = s["kind"]
        blocks = []
        if k == "reactive":
            return s
        elif k == "def" or k == "for" or k == "while":
            blocks = [s["body"]]
        elif k == "if":
            blocks = [s["body"], s["else_"]]
        for b in blocks:
            r = _nested_reactive(b)
            if r != None:
                return r
    return None

def _fn(cx, fname, params, body, bound, is_lambda):
    """Check a function's body: it may not read a reactive variable (a
    name not bound by a parameter or local of it or an enclosing
    function)."""
    inner = dict(bound)
    for p in params:
        if p["name"] != None:
            inner[p["name"]] = True
    if is_lambda:
        _expr(cx, body, inner, fname)
        return
    b = {}
    collect_bindings(body, b)
    for n in b:
        inner[n] = True
    _stmts(cx, body, inner, fname)

def _expr(cx, e, bound, fn):
    """Walk expression e. Reads of reactive variables are errors inside
    functions (fn: the innermost function's name, "lambda", or None at top
    level), else appended to cx["uses"]. bound: names of enclosing
    functions and comprehensions, which hide module variables."""
    if e == None:
        return
    k = e["kind"]
    if k == "name":
        n = e["id"]
        if cx["reactive"].get(n) != None and not bound.get(n, False):
            if fn != None:
                what = "lambda" if fn == "lambda" else "function " + fn
                _err(cx["mod"], e["pos"], what + " refers to reactive variable " + n + " (pass it as an argument instead)")
            cx["uses"].append(e)
    elif k == "list" or k == "tuple":
        for x in e["elems"]:
            _expr(cx, x, bound, fn)
    elif k == "dict":
        for key, val in e["entries"]:
            _expr(cx, key, bound, fn)
            _expr(cx, val, bound, fn)
    elif k == "binop":
        _expr(cx, e["x"], bound, fn)
        _expr(cx, e["y"], bound, fn)
    elif k == "unop" or k == "dot":
        _expr(cx, e["x"], bound, fn)
    elif k == "cond":
        _expr(cx, e["test"], bound, fn)
        _expr(cx, e["then"], bound, fn)
        _expr(cx, e["else_"], bound, fn)
    elif k == "call":
        _expr(cx, e["fn"], bound, fn)
        for a in e["args"]:
            _expr(cx, a["value"], bound, fn)
    elif k == "index":
        _expr(cx, e["x"], bound, fn)
        _expr(cx, e["i"], bound, fn)
    elif k == "slice":
        for part in [e["x"], e["lo"], e["hi"], e["step"]]:
            _expr(cx, part, bound, fn)
    elif k == "lambda":
        for p in e["params"]:
            _expr(cx, p["default"], bound, fn)  # evaluated where the lambda is
        _fn(cx, "lambda", e["params"], e["body"], bound, True)
    elif k == "comp":
        inner = dict(bound)
        for c in e["clauses"]:
            if c["kind"] == "for":
                names = []
                target_names(c["target"], names)
                for n in names:
                    inner[n] = True
        first = True
        for c in e["clauses"]:
            if c["kind"] == "for":
                # the first iterable is evaluated in the enclosing scope
                _expr(cx, c["iter"], bound if first else inner, fn)
                _target(cx, c["target"], inner, fn)
                first = False
            else:
                _expr(cx, c["test"], inner, fn)
        if e["comp"] == "dict":
            _expr(cx, e["body"][0], inner, fn)
            _expr(cx, e["body"][1], inner, fn)
        else:
            _expr(cx, e["body"], inner, fn)

def _target(cx, t, bound, fn):
    """The expressions read by an assignment target (a[i] = ..., a.f = ...)."""
    k = t["kind"]
    if k == "tuple" or k == "list":
        for e in t["elems"]:
            _target(cx, e, bound, fn)
    elif k == "index":
        _expr(cx, t["x"], bound, fn)
        _expr(cx, t["i"], bound, fn)
    elif k == "dot":
        _expr(cx, t["x"], bound, fn)

def _stmts(cx, stmts, bound, fn):
    for s in stmts:
        k = s["kind"]
        if k == "def":
            for p in s["params"]:
                _expr(cx, p["default"], bound, fn)  # evaluated where the def is
            _fn(cx, s["name"], s["params"], s["body"], bound, False)
        elif k == "assign":
            _expr(cx, s["rhs"], bound, fn)
            _target(cx, s["lhs"], bound, fn)
        elif k == "expr":
            _expr(cx, s["x"], bound, fn)
        elif k == "if":
            _expr(cx, s["test"], bound, fn)
            _stmts(cx, s["body"], bound, fn)
            _stmts(cx, s["else_"], bound, fn)
        elif k == "for":
            _expr(cx, s["iter"], bound, fn)
            _target(cx, s["target"], bound, fn)
            _stmts(cx, s["body"], bound, fn)
        elif k == "while":
            _expr(cx, s["test"], bound, fn)
            _stmts(cx, s["body"], bound, fn)
        elif k == "return":
            _expr(cx, s["value"], bound, fn)

def _top_uses(cx, defined, e, self = None):
    """The reactive variables top-level expression e reads, checked to be
    defined already; each read is rewritten to %reactive["x"]. Returns the
    names, in order of first use, and whether e reads `self` (the variable
    e defines): such reads become %prelude._r_self(%reactive, "self"), its
    previous value or, the first time, the identity element (see
    _in_context)."""
    cx["uses"] = []
    _expr(cx, e, {}, None)
    deps = []
    has_self = False
    for u in cx["uses"]:
        n = u["id"]
        posn = u["pos"]
        if n == self:
            has_self = True
            u.clear()
            u.update(_prelude_call("_r_self", [_name(VALUES, posn), _str(n, posn)], posn))
            continue
        if not defined.get(n, False):
            _err(cx["mod"], u["pos"], "reactive variable " + n + " used before its definition")
        if n not in deps:
            deps.append(n)
        u.clear()
        u.update(_value_ref(n, posn))
    return deps, has_self

# ---------------------------------------------------------------- self-reference
#
# In `a : struct(x = a.x + 1, ...)`, a is its value from when it was last
# computed; the first time it has none, and reads as the prelude's
# _identity: a value that acts as the identity element of whatever it is
# combined with (0 in a.x + 1, 1 in a.x * 10, "" in a.y + "foo", and so
# on). That is done without touching the core: in such a definition every
# operation is rewritten to a call of a prelude function (_r_binop,
# _r_attr, ...) that handles _identity and otherwise does the operation.

# conversions of one argument that give the identity of their type
CONVERSIONS = {"str": True, "int": True, "float": True, "bool": True, "len": True, "list": True, "tuple": True, "dict": True, "repr": True}

def _in_context(e):
    """e, with its operations rewritten as calls of the prelude's _r_*
    functions (nodes are replaced in place)."""
    if e == None:
        return e
    k = e["kind"]
    posn = e["pos"]
    new = None
    if e.get("gen", False):
        return e
    if k == "binop" and e["op"] != "and" and e["op"] != "or":
        new = _prelude_call("_r_binop", [_str(e["op"], posn), _in_context(e["x"]), _in_context(e["y"])], posn)
    elif k == "binop":
        _in_context(e["x"])
        _in_context(e["y"])
    elif k == "unop":
        new = _prelude_call("_r_not" if e["op"] == "not" else "_r_unop", ([] if e["op"] == "not" else [_str(e["op"], posn)]) + [_in_context(e["x"])], posn)
    elif k == "dot":
        new = _prelude_call("_r_attr", [_in_context(e["x"]), _str(e["name"], posn)], posn)
    elif k == "index":
        new = _prelude_call("_r_index", [_in_context(e["x"]), _in_context(e["i"])], posn)
    elif k == "slice":
        parts = [_in_context(e[p]) if e[p] != None else _name("None", posn) for p in ["lo", "hi", "step"]]
        new = _prelude_call("_r_slice", [_in_context(e["x"])] + parts, posn)
    elif k == "cond":
        e["test"] = _prelude_call("_r_truth", [_in_context(e["test"])], e["test"]["pos"])
        _in_context(e["then"])
        _in_context(e["else_"])
    elif k == "call":
        fn = e["fn"]
        plain = len([a for a in e["args"] if a["name"] != None or a["star"] != ""]) == 0
        if fn["kind"] == "dot":
            # x.m(args), evaluating x once: [_identity if _is_id(%m) else
            # %m.m(args) for %m in [x]][0] (a method value from _attr would
            # need the method in main's method table)
            for a in e["args"]:
                _in_context(a["value"])
            recv = _in_context(fn["x"])
            fn["x"] = _name("%m", fn["pos"])
            call = dict(e)
            test = _prelude_call("_is_id", [_name("%m", posn)], posn)
            body = {"kind": "cond", "test": test, "then": _name("%prelude._identity", posn), "else_": call, "pos": posn}
            clause = {"kind": "for", "target": _name("%m", posn), "iter": {"kind": "list", "elems": [recv], "pos": posn}, "pos": posn}
            comp = {"kind": "comp", "comp": "list", "body": body, "clauses": [clause], "pos": posn}
            new = {"kind": "index", "x": comp, "i": {"kind": "int", "val": 0, "pos": posn}, "pos": posn, "gen": True}
        elif fn["kind"] == "name" and CONVERSIONS.get(fn["id"], False) and plain and len(e["args"]) == 1:
            new = _prelude_call("_r_conv", [_str(fn["id"], posn), _in_context(e["args"][0]["value"])], e["lparen"])
        else:
            if fn["kind"] != "name":
                _in_context(fn)
            for a in e["args"]:
                _in_context(a["value"])
    elif k == "list" or k == "tuple":
        for x in e["elems"]:
            _in_context(x)
    elif k == "dict":
        for key, val in e["entries"]:
            _in_context(key)
            _in_context(val)
    elif k == "comp":
        for c in e["clauses"]:
            if c["kind"] == "for":
                c["iter"] = _prelude_call("_r_iter", [_in_context(c["iter"])], c["iter"]["pos"])
            else:
                c["test"] = _prelude_call("_r_truth", [_in_context(c["test"])], c["test"]["pos"])
        if e["comp"] == "dict":
            _in_context(e["body"][0])
            _in_context(e["body"][1])
        else:
            _in_context(e["body"])
    # names, literals, lambdas (which can't read reactive variables): as is
    if new != None:
        e.clear()
        e.update(new)
    return e

# ---------------------------------------------------------------- AST builders

def _name(n, posn):
    return {"kind": "name", "id": n, "pos": posn}

def _str(s, posn):
    return {"kind": "string", "val": s, "pos": posn}

def _value_ref(n, posn):
    """%reactive["n"]"""
    return {"kind": "index", "x": _name(VALUES, posn), "i": _str(n, posn), "pos": posn, "gen": True}

def _next_id(name, posn):
    """The implicit field of a struct block `name:` without a field id: the
    previous value's id + 1, read as in a self-reference (the first time,
    the identity, so 1), i.e. _r_binop("+", _r_attr(_r_self(%reactive,
    "name"), "id"), 1). Only this field is in the self-reference context:
    the block's own fields are compiled as they would be without it."""
    prev = _prelude_call("_r_self", [_name(VALUES, posn), _str(name, posn)], posn)
    pid = _prelude_call("_r_attr", [prev, _str("id", posn)], posn)
    return _prelude_call("_r_binop", [_str("+", posn), pid, {"kind": "int", "val": 1, "pos": posn}], posn)

def _prelude_call(fname, args, posn):
    """%prelude.<fname>(args...): a call of a prelude function."""
    c = _call(_name("%prelude." + fname, posn), args, posn)
    c["gen"] = True
    return c

def _assign(lhs, rhs, posn):
    return {"kind": "assign", "op": "=", "lhs": lhs, "rhs": rhs, "pos": posn, "oppos": posn}

def _copy(x):
    """A deep copy of an AST (codegen annotates nodes, so a node can't be
    compiled twice)."""
    t = type(x)
    if t == "dict":
        return {k: _copy(v) for k, v in x.items()}
    if t == "list":
        return [_copy(v) for v in x]
    if t == "tuple":
        return tuple([_copy(v) for v in x])  # positions, dict entries
    return x

# ---------------------------------------------------------------- hooks

def transform(cg, mc):
    """Check where reactive variables are defined and used, and rewrite the
    main module as described at the top."""
    main = mc["mods"][0]
    for mod in mc["mods"]:
        for s in mod["stmts"]:
            if s["kind"] == "reactive" and mod["id"] != 0:
                _err(mod, s["pos"], "reactive variables can only be defined in the main file, not in a loaded module")
            r = _nested_reactive([s]) if s["kind"] != "reactive" else None
            if r != None:
                _err(mod, r["pos"], "reactive variable " + r["name"] + " must be defined at top level")
    stmts = main["stmts"]
    reactive = {}  # name -> its definition
    for s in stmts:
        if s["kind"] == "reactive":
            if reactive.get(s["name"]) != None:
                _err(main, s["pos"], "reactive variable " + s["name"] + " defined twice")
            reactive[s["name"]] = s
    if not reactive:
        return
    mc["ext"]["reactive"] = True

    # nothing else may bind a reactive variable at top level
    bound = {}
    collect_bindings([s for s in stmts if s["kind"] != "reactive"], bound)
    for s in stmts:
        if s["kind"] == "load":
            for i, (local, _) in enumerate(s["names"]):
                if local not in bound:
                    bound[local] = s["namepos"][i]
    for n in bound:
        r = reactive.get(n)
        if r != None:
            if bound[n] < r["pos"]:
                # bound first: the reactive definition is what's wrong
                _err(main, r["pos"], "cannot define reactive variable " + n + ": " + n + " is already bound")
            _err(main, bound[n], "cannot assign to reactive variable " + n + " (only standard input changes it)")

    cx = {"mod": main, "reactive": reactive, "uses": []}
    defined = {}
    first = stmts[0]["pos"]
    out = [
        _assign(_name(VALUES, first), {"kind": "dict", "entries": [], "colons": [], "pos": first}, first),
        _assign(_name(NODES, first), {"kind": "list", "elems": [], "pos": first}, first),
        _assign(_name(STATE, first), {"kind": "dict", "entries": [(_str("lineno", first), {"kind": "int", "val": 0, "pos": first})], "colons": [first], "pos": first}, first),
        _assign(_name(NAMES, first), _names_table(stmts, bound, reactive, first), first),
    ]
    nthunks = 0
    for s in stmts:
        k = s["kind"]
        if defined:
            out.append(_input_call(s["pos"][0], s["pos"]))  # a sync point
        thunk = None
        if k == "reactive":
            deps, has_self = _top_uses(cx, defined, s["value"], s["name"])
            if has_self:
                _in_context(s["value"])
            if s.get("implicit_id", False):
                s["value"]["args"].append({"name": "id", "star": "", "value": _next_id(s["name"], s["pos"]), "pos": s["pos"]})
            defined[s["name"]] = True
            out.append(_assign(_value_ref(s["name"], s["pos"]), s["value"], s["colon"]))
            if deps:
                thunk = ([{"kind": "return", "value": _copy(s["value"]), "pos": s["pos"]}], _str(s["name"], s["pos"]))
        elif k == "expr":
            deps, _ = _top_uses(cx, defined, s["x"])
            out.append(s)
            if deps:
                thunk = ([{"kind": "expr", "x": _copy(s["x"]), "pos": s["pos"]}], _name("None", s["pos"]))
        else:
            cx["uses"] = []
            _stmts(cx, [s], {}, None)
            if cx["uses"]:
                u = cx["uses"][0]
                _err(main, u["pos"], "reactive variable " + u["id"] + " can only be used in a reactive definition " +
                                     "(name : expr) or a top-level expression statement")
            out.append(s)
        if thunk != None:
            body, label = thunk
            p = s["pos"]
            fname = "%r." + str(nthunks)
            nthunks += 1
            out.append({"kind": "def", "name": fname, "params": [], "body": body, "pos": p, "display": "<toplevel>"})
            entry = {"kind": "tuple", "pos": p, "elems": [
                label,
                _name(fname, p),
                {"kind": "tuple", "pos": p, "elems": [_str(d, p) for d in deps]},
            ]}
            out.append({"kind": "expr", "pos": p, "x": _call({"kind": "dot", "x": _name(NODES, p), "name": "append", "pos": p}, [entry], p)})
    out.append(_input_call(0, stmts[-1]["pos"]))
    main["stmts"] = out

def _mentions(x, name):
    """Does AST x have a name node for name?"""
    t = type(x)
    if t == "dict":
        if x.get("kind") == "name" and x.get("id") == name:
            return True
        return any([_mentions(v, name) for k, v in x.items() if k != "pos"])
    if t == "list" or t == "tuple":
        return any([_mentions(v, name) for v in x])
    return False

def _names_table(stmts, bound, reactive, posn):
    """{name: lambda: name}, for every top-level name (not a reactive
    variable) and the INPUT_BUILTINS not shadowed by one: input expressions
    read the current values through these. (It mentions getattr, so every
    method can be called on values, as with getattr(x, any_name).)"""
    names = {}
    for n in bound:
        if reactive.get(n) == None and not n.startswith("%"):
            names[n] = True
    for n in INPUT_BUILTINS + (["struct"] if _mentions(stmts, "struct") else []):
        names[n] = True
    entries = []
    for i, n in enumerate(sorted(names)):
        p = (posn[0], posn[1] + i)
        entries.append((_str(n, p), {"kind": "lambda", "params": [], "body": _name(n, p), "pos": p}))
    return {"kind": "dict", "entries": entries, "colons": [e[0]["pos"] for e in entries], "pos": posn}

def _call(fn, args, posn):
    # codegen tells a call's arguments apart by position (id_of), so each
    # gets its own column
    args = [{"name": None, "star": "", "value": a, "pos": (posn[0], posn[1] + i)} for i, a in enumerate(args)]
    return {"kind": "call", "fn": fn, "args": args, "pos": posn, "lparen": posn}

def _input_call(before, posn):
    """_reactive_input(%reactive, %nodes, %rstate, %rnames, before) as a
    statement."""
    args = [_name(VALUES, posn), _name(NODES, posn), _name(STATE, posn), _name(NAMES, posn), {"kind": "int", "val": before, "pos": posn}]
    return {"kind": "expr", "pos": posn, "x": _call(_name("%prelude._reactive_input", posn), args, posn)}

def imports(mc, m):
    if not mc["ext"].get("reactive", False):
        return
    # read_line(before) -> length of the next line of standard input
    #     (fetched with file_chunk, like a file), or -1: at its end if
    #     before is 0, else if no line is due before source line `before`
    # try_call(f) -> 0 if f() (called via the reactive_call0 export)
    #     succeeded, else 1 after printing its error with a traceback
    import_func(m, "host", "read_line", [I32], [I32], as_name = "host_read_line")
    import_func(m, "host", "try_call", [V], [I32], as_name = "host_try_call")

def runtime(mc, m):
    if not mc["ext"].get("reactive", False):
        return
    add_func(m, "rt_read_line", [("before", V)], [V], locals = [
        ("size", I32),
        ("off", I32),
        ("k", I32),
        ("a", U8A),
        ("i", I32),
    ], body = [
        set("size", call("host_read_line", op("i31.get_s", as_("i31", get("before"))))),
        if_(op("i32.lt_s", get("size"), i32(0)), ret(gget("None"))),
        set("a", arr_new_default("U8", get("size"))),
        set("off", i32(0)),
        while_(op("i32.lt_s", get("off"), get("size")), [
            set("k", op("i32.sub", get("size"), get("off"))),
            if_(op("i32.gt_s", get("k"), i32(65536)), set("k", i32(65536))),
            call("host_file_chunk", get("off"), i32(0), get("k")),
            _copy_chunk(),
            set("off", op("i32.add", get("off"), get("k"))),
        ]),
        new("Str", i32(0), get("a")),
    ])
    add_func(m, "rt_eprint", [("v", V)], [V], locals = [("b", U8A)], body = [
        set("b", field("Str", "b", call("rt_str", get("v")))),
        call("rt_write_bytes", get("b"), arr_len(get("b")), i32(2)),
        set("b", field("Str", "b", S(m, "\n"))),
        call("rt_write_bytes", get("b"), i32(1), i32(2)),
        gget("None"),
    ])
    add_func(m, "rt_try", [("f", V)], [V], locals = [("depth", I32), ("n", I32)], body = [
        # an error skips the uncounting of the calls it unwinds
        set("depth", gget("call_depth")),
        set("n", call("host_try_call", get("f"))),
        gset("call_depth", get("depth")),
        if_(get("n"), ret(gget("False"))),
        gget("True"),
    ])
    add_func(m, "rt_reactive_call0", [("f", V)], [], [
        drop(call("rt_call", get("f"), arr_new_default("Vals", i32(0)), null("eq"))),
    ], export = "reactive_call0")

def _copy_chunk():
    """a[off + i] = memory[i] for i in range(k)."""
    return [
        set("i", i32(0)),
        while_(op("i32.lt_s", get("i"), get("k")), [
            arr_set("U8", get("a"), op("i32.add", get("off"), get("i")), [get("i"), ("i32.load8_u", 0)]),
            set("i", op("i32.add", get("i"), i32(1))),
        ], label = "copy"),
    ]

def prelude(mc):
    if not mc["ext"].get("reactive", False):
        return [], []
    return parse_file(RUNTIME, "compiler/ext/reactive.star"), ["_reactive_input"]

# ---------------------------------------------------------------- runtime

# Added to the prelude of programs with reactive variables (its frames are
# hidden in tracebacks, like the prelude's). Compile errors in it give
# line numbers counted from the start of the string.
RUNTIME = r'''
def _reactive_input(values, nodes, state, names, before):
    """Read lines of assignments `x = expression` (or `x : expression`),
    separated by ";", set those reactive variables, and recompute what
    depends on them (_reactive_update). An expression may use the
    program's other top-level names and builtins (names: name -> function
    returning its current value), but no reactive variable. Until the end
    of standard input if before is
    0, else while the host has lines due before source line `before` (a
    sync point; see the top of the file). A bad line is reported on stderr
    and ignored. If recomputing fails, the error is reported and every
    reactive variable gets its value back."""
    while True:
        line = _read_line(before)
        if line == None:
            return
        state["lineno"] += 1
        p = {"s": line, "i": 0, "err": None, "depth": 0}
        assigns = _r_line(p, values, names)
        if p["err"] != None:
            _eprint("<stdin>:" + str(state["lineno"]) + ":" + str(p["errpos"] + 1) + ": " + p["err"])
            continue
        if not assigns:
            continue
        saved = dict(values)
        if not _try(lambda: _reactive_update(values, nodes, [(n, _r_eval(e, {}, names)) for n, e in assigns])):
            values.clear()
            values.update(saved)

def _reactive_update(values, nodes, assigns):
    """Set the assigned variables, then go through nodes (source order is
    a topological order) recomputing each variable that reads a changed
    one, and re-running each observer that does. A recomputed variable
    counts as changed only if its new value differs (!=) from the old."""
    changed = {}
    for name, v in assigns:
        values[name] = v
        changed[name] = True
    for name, f, deps in nodes[:]:  # a copy: an error would leave nodes marked as iterated
        hit = False
        for d in deps:
            if changed.get(d, False):
                hit = True
                break
        if not hit:
            continue
        if name == None:
            f()
            continue
        v = f()
        if v != values[name]:
            changed[name] = True
        values[name] = v

# ---- self-reference (see _in_context): `a : f(a)` reads a's previous
# value, or the first time, _identity: the identity element of whatever it
# is combined with.

def _identity():
    """The identity element of any context (a unique value)."""
    pass

def _is_id(x):
    return type(x) == "builtin_function_or_method" and x == _identity

# the identity of an operator for values of each type
_R_ZERO = {"int": 0, "float": 0.0, "string": "", "bytes": b"", "list": [], "tuple": (), "dict": {}}
_R_ADDITIVE = {"+": True, "-": True, "|": True, "^": True, "<<": True, ">>": True,
               "==": True, "!=": True, "<": True, "<=": True, ">": True, ">=": True}

def _r_unit(op, other):
    """The identity element of op, combined with other."""
    t = type(other)
    if _R_ADDITIVE.get(op, False):
        if t == "set":
            return set()
        if t == "list":
            return []  # a fresh one (a + [] doesn't alias, but be safe)
        return _R_ZERO.get(t, 0)
    if op == "&":
        return other if t == "set" else -1
    return 1  # * / // %

def _r_self(values, name):
    return values[name] if name in values else _identity

def _r_binop(op, x, y):
    xi = _is_id(x)
    yi = _is_id(y)
    if xi and yi:
        return _identity
    if op == "in" or op == "not in":
        if xi or yi:
            return op == "not in"
    elif xi:
        x = _r_unit(op, y)
    elif yi:
        y = _r_unit(op, x)
    if op == "+":
        return x + y
    if op == "-":
        return x - y
    if op == "*":
        return x * y
    if op == "/":
        return x / y
    if op == "//":
        return x // y
    if op == "%":
        return x % y
    if op == "|":
        return x | y
    if op == "&":
        return x & y
    if op == "^":
        return x ^ y
    if op == "<<":
        return x << y
    if op == ">>":
        return x >> y
    if op == "==":
        return x == y
    if op == "!=":
        return x != y
    if op == "<":
        return x < y
    if op == "<=":
        return x <= y
    if op == ">":
        return x > y
    if op == ">=":
        return x >= y
    if op == "in":
        return x in y
    return x not in y

def _r_unop(op, x):
    if _is_id(x):
        return _identity
    if op == "-":
        return -x
    if op == "+":
        return +x
    return ~x

def _r_truth(x):
    return False if _is_id(x) else bool(x)

def _r_not(x):
    return not _r_truth(x)

def _r_attr(x, name):
    return _identity if _is_id(x) else _attr(x, name)

def _r_index(x, i):
    return _identity if _is_id(x) else x[i]

def _r_slice(x, lo, hi, step):
    return _identity if _is_id(x) else x[lo:hi:step]

def _r_iter(x):
    return [] if _is_id(x) else x

_R_CONV_ID = {"str": "", "repr": "", "int": 0, "float": 0.0, "bool": False, "len": 0}

def _r_conv(f, x):
    """str(x), int(x), ... of x, or of the identity: that type's."""
    if _is_id(x):
        if f == "list":
            return []
        if f == "tuple":
            return ()
        if f == "dict":
            return {}
        return _R_CONV_ID[f]
    if f == "str":
        return str(x)
    if f == "repr":
        return repr(x)
    if f == "int":
        return int(x)
    if f == "float":
        return float(x)
    if f == "bool":
        return bool(x)
    if f == "len":
        return len(x)
    if f == "list":
        return list(x)
    if f == "tuple":
        return tuple(x)
    return dict(x)

# ---- parsing a line: p = {"s": line, "i": position, "err": message or None}

_R_IDSTART = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"
_R_IDCHARS = _R_IDSTART + "0123456789"
_R_DIGITS = "0123456789"
_R_HEX = "0123456789abcdefABCDEF"
_R_ESCAPES = {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v", "\\": "\\", "'": "'", "\"": "\""}
_R_MAX_DEPTH = 100

def _r_fail(p, msg, at = None):
    if p["err"] == None:
        p["err"] = msg
        p["errpos"] = p["i"] if at == None else at
    return None

def _r_peek(p, k = 0):
    i = p["i"] + k
    return p["s"][i] if i < len(p["s"]) else ""

def _r_space(p):
    s = p["s"]
    for i in range(p["i"], len(s)):
        if s[i] != " " and s[i] != "\t":
            p["i"] = i
            return
    p["i"] = len(s)

def _r_ident(p):
    s = p["s"]
    start = p["i"]
    if start >= len(s) or s[start] not in _R_IDSTART:
        return None
    i = start + 1
    for _ in range(len(s)):
        if i >= len(s) or s[i] not in _R_IDCHARS:
            break
        i += 1
    p["i"] = i
    return s[start:i]

_R_KEYWORDS = {"and": True, "or": True, "not": True, "in": True, "if": True, "else": True,
               "for": True, "lambda": True, "None": True, "True": True, "False": True}
_R_PUNCT2 = {"//": True, "<<": True, ">>": True, "==": True, "!=": True, "<=": True, ">=": True}
_R_PUNCT1 = "+-*/%&|^~<>()[]{},:.;="
_R_COMPARE = {"==": True, "!=": True, "<": True, ">": True, "<=": True, ">=": True, "in": True}
_R_BINARY = [["|"], ["^"], ["&"], ["<<", ">>"], ["+", "-"], ["*", "/", "//", "%"]]

def _r_tokens(p):
    """The tokens of the line: {"k": "const" | "name" | "kw" | "op" | "end",
    "v": value, "pos": byte offset}."""
    s = p["s"]
    toks = []
    for _ in range(len(s) + 1):
        _r_space(p)
        i = p["i"]
        if i >= len(s) or s[i] == "#":
            break
        c = s[i]
        d = _r_peek(p, 1)
        e = _r_peek(p, 2)
        if c in _R_DIGITS or (c == "." and d != "" and d in _R_DIGITS):
            v = _r_number(p)
        elif c == "\"" or c == "'":
            v = _r_string(p, False, False)
        elif c in "rb" and (d == "\"" or d == "'"):
            p["i"] += 1
            v = _r_string(p, c == "r", c == "b")
        elif (c + d == "rb" or c + d == "br") and (e == "\"" or e == "'"):
            p["i"] += 2
            v = _r_string(p, True, True)
        elif c in _R_IDSTART:
            name = _r_ident(p)
            toks.append({"k": "kw" if name in _R_KEYWORDS else "name", "v": name, "pos": i})
            continue
        elif _R_PUNCT2.get(s[i:i + 2], False):
            toks.append({"k": "op", "v": s[i:i + 2], "pos": i})
            p["i"] = i + 2
            continue
        elif c in _R_PUNCT1:
            toks.append({"k": "op", "v": c, "pos": i})
            p["i"] = i + 1
            continue
        else:
            return _r_fail(p, "unexpected character " + repr(c))
        if p["err"] != None:
            return None
        toks.append({"k": "const", "v": v, "pos": i})
    toks.append({"k": "end", "v": "", "pos": len(s)})
    return toks

def _r_line(p, values, names):
    """The (name, expression) pairs of a line, in order; expressions are
    parsed (see _r_eval) and checked not to refer to reactive variables."""
    toks = _r_tokens(p)
    if p["err"] != None:
        return None
    p["toks"] = toks
    p["t"] = 0
    out = []
    for _ in range(len(toks)):
        if _r_tok(p)["k"] == "end":
            break
        t = _r_next(p)
        if t["k"] != "name":
            return _r_fail(p, "want a reactive variable name, then = and an expression", t["pos"])
        if t["v"] not in values:
            return _r_fail(p, t["v"] + " is not a reactive variable", t["pos"])
        if not _r_is(p, "=") and not _r_is(p, ":"):
            return _r_fail(p, "want = after " + t["v"], _r_tok(p)["pos"])
        _r_next(p)
        e = _r_exprs(p)
        if p["err"] != None:
            return None
        _r_check(p, e, {}, values, names)
        if p["err"] != None:
            return None
        out.append((t["v"], e))
        if _r_tok(p)["k"] == "end":
            break
        if not _r_is(p, ";"):
            return _r_fail(p, "want ; or the end of the line after an expression", _r_tok(p)["pos"])
        _r_next(p)
    return out

# ---- the expression parser: p["toks"], p["t"] (index of the next token).
# Nodes are tuples: ("const", v) ("name", id, pos) ("list", elems)
# ("tuple", elems) ("dict", [(k, v)]) ("unop", op, x) ("not", x)
# ("and", x, y) ("or", x, y) ("binop", op, x, y) ("cond", test, then, else)
# ("attr", x, name) ("call", f, [(name or None, star, x)]) ("index", x, i)
# ("slice", x, lo, hi, step) ("comp", "list" | "dict", body, clauses),
# clauses being ("for", [names], iterable) or ("if", test).

def _r_tok(p):
    return p["toks"][p["t"]]

def _r_next(p):
    t = p["toks"][p["t"]]
    if t["k"] != "end":
        p["t"] += 1
    return t

def _r_is(p, v):
    t = p["toks"][p["t"]]
    return (t["k"] == "op" or t["k"] == "kw") and t["v"] == v

def _r_expect(p, v):
    if not _r_is(p, v):
        t = _r_tok(p)
        return _r_fail(p, "want " + v + (" here" if t["k"] == "end" else ", got " + repr(t["v"])), t["pos"])
    return _r_next(p)

def _r_exprs(p):
    """An expression, or several separated by commas (a tuple)."""
    x = _r_test(p)
    if not _r_is(p, ","):
        return x
    elems = [x]
    for _ in range(len(p["toks"])):
        if not _r_is(p, ",") or p["err"] != None:
            break
        _r_next(p)
        if _r_tok(p)["k"] == "end" or _r_is(p, ";"):
            break
        elems.append(_r_test(p))
    return ("tuple", elems)

def _r_test(p):
    if _r_is(p, "lambda"):
        return _r_fail(p, "lambda is not supported here", _r_tok(p)["pos"])
    x = _r_por(p)
    if _r_is(p, "if"):
        _r_next(p)
        test = _r_por(p)
        _r_expect(p, "else")
        return ("cond", test, x, _r_test(p))
    return x

def _r_por(p):
    x = _r_pand(p)
    for _ in range(len(p["toks"])):
        if not _r_is(p, "or") or p["err"] != None:
            break
        _r_next(p)
        x = ("or", x, _r_pand(p))
    return x

def _r_pand(p):
    x = _r_pnot(p)
    for _ in range(len(p["toks"])):
        if not _r_is(p, "and") or p["err"] != None:
            break
        _r_next(p)
        x = ("and", x, _r_pnot(p))
    return x

def _r_pnot(p):
    if _r_is(p, "not"):
        _r_next(p)
        return ("not", _r_pnot(p))
    x = _r_binary(p, 0)
    t = _r_tok(p)
    op = t["v"] if t["k"] == "op" or t["k"] == "kw" else ""
    if op == "not" and p["toks"][p["t"] + 1]["v"] == "in":
        _r_next(p)
        op = "not in"
    elif not _R_COMPARE.get(op, False):
        return x
    _r_next(p)
    y = _r_binary(p, 0)
    t = _r_tok(p)
    if (t["k"] == "op" or t["k"] == "kw") and (_R_COMPARE.get(t["v"], False) or t["v"] == "not"):
        return _r_fail(p, "comparison operators don't chain; use parentheses", t["pos"])
    return ("binop", op, x, y)

def _r_binary(p, level):
    if level == len(_R_BINARY):
        return _r_unary(p)
    x = _r_binary(p, level + 1)
    for _ in range(len(p["toks"])):
        t = _r_tok(p)
        if t["k"] != "op" or t["v"] not in _R_BINARY[level] or p["err"] != None:
            break
        _r_next(p)
        x = ("binop", t["v"], x, _r_binary(p, level + 1))
    return x

def _r_unary(p):
    t = _r_tok(p)
    if t["k"] == "op" and t["v"] in ("-", "+", "~"):
        _r_next(p)
        return ("unop", t["v"], _r_unary(p))
    return _r_postfix(p)

def _r_postfix(p):
    x = _r_primary(p)
    for _ in range(len(p["toks"])):
        if p["err"] != None:
            break
        if _r_is(p, "."):
            _r_next(p)
            t = _r_next(p)
            if t["k"] != "name":
                return _r_fail(p, "want a name after .", t["pos"])
            x = ("attr", x, t["v"])
        elif _r_is(p, "("):
            _r_next(p)
            x = ("call", x, _r_args(p))
        elif _r_is(p, "["):
            _r_next(p)
            x = _r_subscript(p, x)
        else:
            break
    return x

def _r_args(p):
    args = []
    for _ in range(len(p["toks"])):
        if _r_is(p, ")") or p["err"] != None:
            break
        if args:
            _r_expect(p, ",")
            if _r_is(p, ")"):
                break
        if _r_is(p, "*") or _r_is(p, "**"):
            star = _r_next(p)["v"]
            args.append((None, star, _r_test(p)))
        elif _r_tok(p)["k"] == "name" and p["toks"][p["t"] + 1]["v"] == "=" and p["toks"][p["t"] + 1]["k"] == "op":
            name = _r_next(p)["v"]
            _r_next(p)
            args.append((name, "", _r_test(p)))
        else:
            args.append((None, "", _r_test(p)))
    _r_expect(p, ")")
    return args

def _r_subscript(p, x):
    lo = None
    if not _r_is(p, ":"):
        lo = _r_exprs(p)
        if _r_is(p, "]"):
            _r_next(p)
            return ("index", x, lo)
    hi = None
    step = None
    _r_expect(p, ":")
    if not _r_is(p, ":") and not _r_is(p, "]"):
        hi = _r_test(p)
    if _r_is(p, ":"):
        _r_next(p)
        if not _r_is(p, "]"):
            step = _r_test(p)
    _r_expect(p, "]")
    return ("slice", x, lo, hi, step)

def _r_primary(p):
    t = _r_tok(p)
    if p["err"] != None:
        return None
    if t["k"] == "const":
        _r_next(p)
        return ("const", t["v"])
    if t["k"] == "name":
        _r_next(p)
        return ("name", t["v"], t["pos"])
    if t["k"] == "kw" and t["v"] in ("None", "True", "False"):
        _r_next(p)
        return ("const", {"None": None, "True": True, "False": False}[t["v"]])
    if t["k"] == "op" and t["v"] in ("(", "[", "{"):
        if p["depth"] >= _R_MAX_DEPTH:
            return _r_fail(p, "expression nested too deeply", t["pos"])
        p["depth"] += 1
        _r_next(p)
        x = _r_paren(p) if t["v"] == "(" else _r_list(p) if t["v"] == "[" else _r_dict(p)
        p["depth"] -= 1
        return x
    if t["k"] == "end":
        return _r_fail(p, "want an expression here", t["pos"])
    return _r_fail(p, "want an expression, got " + repr(t["v"]), t["pos"])

def _r_paren(p):
    if _r_is(p, ")"):
        _r_next(p)
        return ("tuple", [])
    x = _r_test(p)
    if not _r_is(p, ","):
        _r_expect(p, ")")
        return x
    elems = [x]
    for _ in range(len(p["toks"])):
        if not _r_is(p, ",") or p["err"] != None:
            break
        _r_next(p)
        if _r_is(p, ")"):
            break
        elems.append(_r_test(p))
    _r_expect(p, ")")
    return ("tuple", elems)

def _r_list(p):
    if _r_is(p, "]"):
        _r_next(p)
        return ("list", [])
    x = _r_test(p)
    if _r_is(p, "for"):
        clauses = _r_clauses(p, "]")
        return ("comp", "list", x, clauses)
    elems = [x]
    for _ in range(len(p["toks"])):
        if not _r_is(p, ",") or p["err"] != None:
            break
        _r_next(p)
        if _r_is(p, "]"):
            break
        elems.append(_r_test(p))
    _r_expect(p, "]")
    return ("list", elems)

def _r_dict(p):
    if _r_is(p, "}"):
        _r_next(p)
        return ("dict", [])
    k = _r_test(p)
    _r_expect(p, ":")
    v = _r_test(p)
    if _r_is(p, "for"):
        return ("comp", "dict", (k, v), _r_clauses(p, "}"))
    entries = [(k, v)]
    for _ in range(len(p["toks"])):
        if not _r_is(p, ",") or p["err"] != None:
            break
        _r_next(p)
        if _r_is(p, "}"):
            break
        k = _r_test(p)
        _r_expect(p, ":")
        entries.append((k, _r_test(p)))
    _r_expect(p, "}")
    return ("dict", entries)

def _r_clauses(p, close):
    clauses = []
    for _ in range(len(p["toks"])):
        if p["err"] != None or _r_is(p, close):
            break
        if _r_is(p, "for"):
            _r_next(p)
            targets = []
            for _ in range(len(p["toks"])):
                t = _r_next(p)
                if t["k"] != "name":
                    return _r_fail(p, "want a variable name after for", t["pos"])
                targets.append(t["v"])
                if not _r_is(p, ","):
                    break
                _r_next(p)
            _r_expect(p, "in")
            clauses.append(("for", targets, _r_por(p)))
        elif _r_is(p, "if"):
            _r_next(p)
            clauses.append(("if", _r_por(p)))
        else:
            t = _r_tok(p)
            return _r_fail(p, "want for, if or " + close, t["pos"])
    _r_expect(p, close)
    return clauses

def _r_children(n):
    """The subexpressions of node n (for _r_check)."""
    k = n[0]
    if k == "const" or k == "name":
        return []
    if k == "list" or k == "tuple":
        return n[1]
    if k == "dict":
        return [x for kv in n[1] for x in kv]
    if k == "unop":
        return [n[2]]
    if k == "not":
        return [n[1]]
    if k == "and" or k == "or":
        return [n[1], n[2]]
    if k == "binop":
        return [n[2], n[3]]
    if k == "cond":
        return [n[1], n[2], n[3]]
    if k == "attr":
        return [n[1]]
    if k == "call":
        return [n[1]] + [a[2] for a in n[2]]
    if k == "index":
        return [n[1], n[2]]
    if k == "slice":
        return [x for x in n[1:] if x != None]
    return []

def _r_check(p, n, bound, values, names):
    """Names in n must be comprehension variables, or top-level names or
    builtins of the program (names), and not reactive variables."""
    if n == None or p["err"] != None:
        return
    if n[0] == "name":
        if bound.get(n[1], False):
            return
        if n[1] in values:
            _r_fail(p, n[1] + " is a reactive variable: a new value can't refer to one", n[2])
        elif n[1] not in names:
            _r_fail(p, "undefined: " + n[1], n[2])
        return
    if n[0] == "comp":
        inner = dict(bound)
        for c in n[3]:
            if c[0] == "for":
                for t in c[1]:
                    inner[t] = True
        for c in n[3]:
            _r_check(p, c[2] if c[0] == "for" else c[1], inner, values, names)
        for x in (n[2] if n[1] == "dict" else [n[2]]):
            _r_check(p, x, inner, values, names)
        return
    for x in _r_children(n):
        _r_check(p, x, bound, values, names)

def _r_eval(n, env, names):
    """The value of expression node n; env: comprehension variables."""
    k = n[0]
    if k == "const":
        return n[1]
    if k == "name":
        return env[n[1]] if n[1] in env else names[n[1]]()
    if k == "list":
        return [_r_eval(x, env, names) for x in n[1]]
    if k == "tuple":
        return tuple([_r_eval(x, env, names) for x in n[1]])
    if k == "dict":
        d = {}
        for key, val in n[1]:
            d[_r_eval(key, env, names)] = _r_eval(val, env, names)
        return d
    if k == "unop":
        return _r_unop(n[1], _r_eval(n[2], env, names))
    if k == "not":
        return not _r_eval(n[1], env, names)
    if k == "and":
        x = _r_eval(n[1], env, names)
        return _r_eval(n[2], env, names) if x else x
    if k == "or":
        x = _r_eval(n[1], env, names)
        return x if x else _r_eval(n[2], env, names)
    if k == "binop":
        return _r_binop(n[1], _r_eval(n[2], env, names), _r_eval(n[3], env, names))
    if k == "cond":
        return _r_eval(n[2], env, names) if _r_eval(n[1], env, names) else _r_eval(n[3], env, names)
    if k == "attr":
        return _attr(_r_eval(n[1], env, names), n[2])
    if k == "call":
        f = _r_eval(n[1], env, names)
        pos = []
        kw = {}
        for name, star, x in n[2]:
            v = _r_eval(x, env, names)
            if star == "*":
                pos.extend(v)
            elif star == "**":
                kw.update(v)
            elif name != None:
                kw[name] = v
            else:
                pos.append(v)
        return f(*pos, **kw)
    if k == "index":
        return _r_eval(n[1], env, names)[_r_eval(n[2], env, names)]
    if k == "slice":
        part = [None if x == None else _r_eval(x, env, names) for x in n[2:]]
        return _r_eval(n[1], env, names)[part[0]:part[1]:part[2]]
    out = [] if n[1] == "list" else {}
    _r_comp(n, 0, dict(env), names, out)
    return out

def _r_comp(n, i, env, names, out):
    if i == len(n[3]):
        if n[1] == "list":
            out.append(_r_eval(n[2], env, names))
        else:
            out[_r_eval(n[2][0], env, names)] = _r_eval(n[2][1], env, names)
        return
    c = n[3][i]
    if c[0] == "if":
        if _r_eval(c[1], env, names):
            _r_comp(n, i + 1, env, names, out)
        return
    for v in _r_eval(c[2], env, names):
        if len(c[1]) == 1:
            env[c[1][0]] = v
        else:
            vs = tuple(v)
            if len(vs) != len(c[1]):
                fail("got %d values to unpack, want %d" % (len(vs), len(c[1])))
            for j, t in enumerate(c[1]):
                env[t] = vs[j]
        _r_comp(n, i + 1, env, names, out)

def _r_number(p):
    """An unsigned int or float literal, as Starlark writes them."""
    s = p["s"]
    start = p["i"]
    i = start
    for _ in range(len(s)):
        if i >= len(s):
            break
        c = s[i]
        if c in _R_IDCHARS or c == ".":
            i += 1
        elif (c == "+" or c == "-") and s[i - 1] in "eE" and not s[start:i].lower().startswith("0x"):
            i += 1
        else:
            break
    p["i"] = i
    text = s[start:i]
    low = text.lower()
    if low.startswith("0x") or low.startswith("0o") or low.startswith("0b"):
        digits = {"x": _R_HEX, "o": "01234567", "b": "01"}[low[1]]
        if len(text) == 2 or [c for c in text[2:].elems() if c not in digits]:
            return _r_fail(p, "invalid int literal: " + text, start)
        return int(text, 0)
    if "." not in text and "e" not in low:
        if [c for c in text.elems() if c not in _R_DIGITS]:
            return _r_fail(p, "invalid int literal: " + text, start)
        if len(text) > 1 and text[0] == "0":
            return _r_fail(p, "invalid int literal: " + text + " (no leading zeros)", start)
        return int(text)
    return _r_float(p, text, start)

def _r_float(p, text, start):
    """digits [. digits] [e [sign] digits], with digits before or after the
    point; too large a value is an error (float() would fail)."""
    mant, e, exp = text.lower().partition("e")
    if e and (exp.lstrip("+-") == "" or len(exp) - len(exp.lstrip("+-")) > 1 or
              [c for c in exp.lstrip("+-").elems() if c not in _R_DIGITS]):
        return _r_fail(p, "invalid float literal: " + text, start)
    whole, _, frac = mant.partition(".")
    if (whole + frac) == "" or [c for c in (whole + frac).elems() if c not in _R_DIGITS] or mant.count(".") > 1:
        return _r_fail(p, "invalid float literal: " + text, start)
    # the decimal exponent of the leading digit, to reject overflow
    digits = (whole + frac).lstrip("0")
    if digits != "":
        x = int(exp) if e else 0
        if len(exp.lstrip("+-")) > 6:
            x = 1000000 if not exp.startswith("-") else -1000000
        lead = x + len(whole.lstrip("0")) - 1 if whole.lstrip("0") else x - (len(frac) - len(frac.lstrip("0"))) - 1
        if lead > 308 or (lead == 308 and (digits + "0" * 17)[:17] > "17976931348623157"):
            return _r_fail(p, "float literal too large: " + text, start)
    return float(text)

def _r_string(p, raw, is_bytes):
    """A string or bytes literal at p["i"] (after any r/b prefix), in
    single, double or triple quotes, with Starlark's escapes unless raw."""
    s = p["s"]
    q = s[p["i"]]
    start = p["i"]
    if s[p["i"]:p["i"] + 3] == q * 3:
        q = q * 3
    i = p["i"] + len(q)
    parts = []  # strings (pieces of text) and ints (bytes, for bytes literals)
    lit = i  # start of the pending literal text
    for _ in range(len(s)):
        if i >= len(s):
            return _r_fail(p, "unterminated string literal", start)
        if s[i:i + len(q)] == q:
            parts.append(s[lit:i])
            p["i"] = i + len(q)
            break
        if s[i] != "\\":
            i += 1
            continue
        if raw:
            i += 2  # a backslash keeps the next character (even a quote)
            continue
        parts.append(s[lit:i])
        c = s[i + 1] if i + 1 < len(s) else ""
        if _R_ESCAPES.get(c) != None:
            parts.append(_R_ESCAPES[c])
            i += 2
        elif c in "01234567" and c != "":
            j = i + 1
            for _ in range(3):
                if j < len(s) and s[j] in "01234567" and j < i + 4:
                    j += 1
            n = int(s[i + 1:j], 8)
            if n > 255:
                return _r_fail(p, "octal escape value > 255: " + s[i:j], i)
            if n > 127 and not is_bytes:
                return _r_fail(p, "non-ASCII octal escape \\" + s[i + 1:j] + " in a string (use \\u)", i)
            parts.append(n if is_bytes else chr(n))
            i = j
        elif c == "x":
            h = s[i + 2:i + 4]
            if len(h) < 2 or [d for d in h.elems() if d not in _R_HEX]:
                return _r_fail(p, "truncated escape sequence \\x" + h, i)
            n = int(h, 16)
            if n > 127 and not is_bytes:
                return _r_fail(p, "non-ASCII hex escape \\x" + h + " in a string (use \\u)", i)
            parts.append(n if is_bytes else chr(n))
            i += 4
        elif c == "u" or c == "U":
            k = 4 if c == "u" else 8
            h = s[i + 2:i + 2 + k]
            if len(h) < k or [d for d in h.elems() if d not in _R_HEX]:
                return _r_fail(p, "truncated escape sequence \\" + c + h, i)
            n = int(h, 16)
            if n > 0x10FFFF or (n >= 0xD800 and n < 0xE000):
                return _r_fail(p, "invalid Unicode code point \\" + c + h, i)
            parts.append(chr(n))
            i += 2 + k
        else:
            return _r_fail(p, "invalid escape sequence \\" + c, i)
        lit = i
    if not is_bytes:
        return "".join(parts)
    out = []
    for x in parts:
        if type(x) == "int":
            out.append(x)
        else:
            out.extend(list(bytes(x).elems()))
    return bytes(out)
'''
