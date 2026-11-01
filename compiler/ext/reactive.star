# ext/reactive.star — reactive variables (EXTENSIONS.md).
#
#   x : 1                 # a reactive variable (top level of the main file)
#   y : x * 10            # recomputed whenever x changes
#   print("y is", y)      # re-run whenever y changes
#
# A program with reactive variables doesn't exit at the end of its top
# level: it reads lines like `x = 5` from standard input, sets the
# variables, and recomputes everything that depends on them, transitively.
#
# Almost all of it is Starlark: the checks and the rewriting of the program
# are done here, on the AST, before anything is compiled, and the loop that
# reads standard input, parses the literals and propagates changes is the
# Starlark in RUNTIME below, added to the prelude. The Wasm part is three
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
        if reactive.get(n) != None:
            _err(main, bound[n], "cannot assign to reactive variable " + n + " (only standard input changes it)")

    cx = {"mod": main, "reactive": reactive, "uses": []}
    defined = {}
    first = stmts[0]["pos"]
    out = [
        _assign(_name(VALUES, first), {"kind": "dict", "entries": [], "colons": [], "pos": first}, first),
        _assign(_name(NODES, first), {"kind": "list", "elems": [], "pos": first}, first),
        _assign(_name(STATE, first), {"kind": "dict", "entries": [(_str("lineno", first), {"kind": "int", "val": 0, "pos": first})], "colons": [first], "pos": first}, first),
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

def _call(fn, args, posn):
    # codegen tells a call's arguments apart by position (id_of), so each
    # gets its own column
    args = [{"name": None, "star": "", "value": a, "pos": (posn[0], posn[1] + i)} for i, a in enumerate(args)]
    return {"kind": "call", "fn": fn, "args": args, "pos": posn, "lparen": posn}

def _input_call(before, posn):
    """_reactive_input(%reactive, %nodes, %rstate, before) as a statement."""
    args = [_name(VALUES, posn), _name(NODES, posn), _name(STATE, posn), {"kind": "int", "val": before, "pos": posn}]
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
def _reactive_input(values, nodes, state, before):
    """Read lines of assignments `x = literal` (or `x : literal`), separated
    by ";", set those reactive variables, and recompute what depends on
    them (_reactive_update): until the end of standard input if before is
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
        assigns = _r_line(p, values)
        if p["err"] != None:
            _eprint("<stdin>:" + str(state["lineno"]) + ":" + str(p["errpos"] + 1) + ": " + p["err"])
            continue
        if not assigns:
            continue
        saved = dict(values)
        if not _try(lambda: _reactive_update(values, nodes, assigns)):
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

def _r_at_end(p):
    """Only spaces or a comment left."""
    _r_space(p)
    return p["i"] >= len(p["s"]) or p["s"][p["i"]] == "#"

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

def _r_line(p, values):
    """The (name, value) pairs of a line, in order."""
    out = []
    for _ in range(len(p["s"]) + 1):
        if _r_at_end(p):
            break
        start = p["i"]
        name = _r_ident(p)
        if name == None:
            return _r_fail(p, "want a reactive variable name, then = and a literal")
        if name not in values:
            return _r_fail(p, name + " is not a reactive variable", start)
        _r_space(p)
        c = _r_peek(p)
        if c != "=" and c != ":":
            return _r_fail(p, "want = after " + name)
        p["i"] += 1
        v = _r_value(p)
        if p["err"] != None:
            return None
        out.append((name, v))
        if _r_at_end(p):
            break
        if _r_peek(p) != ";":
            return _r_fail(p, "want ; or the end of the line after a value")
        p["i"] += 1
    return out

def _r_value(p):
    """A literal: None True False, an int, float, string or bytes literal
    (a sign is allowed before a number), or a list, tuple or dict of
    literals."""
    _r_space(p)
    c = _r_peek(p)
    start = p["i"]
    if c == "":
        return _r_fail(p, "want a literal value")
    if c == "[" or c == "(" or c == "{":
        if p["depth"] >= _R_MAX_DEPTH:
            return _r_fail(p, "value nested too deeply")
        p["depth"] += 1
        v = _r_container(p, c)
        p["depth"] -= 1
        return v
    if c == "-" or c == "+":
        p["i"] += 1
        _r_space(p)
        d = _r_peek(p)
        if d == "" or (d not in _R_DIGITS and d != "."):
            return _r_fail(p, "want a number after " + c)
        v = _r_number(p)
        if p["err"] != None or c == "+":
            return v
        return -v
    if c in _R_DIGITS or (c == "." and _r_peek(p, 1) != "" and _r_peek(p, 1) in _R_DIGITS):
        return _r_number(p)
    if c == "\"" or c == "'":
        return _r_string(p, False, False)
    if c in "rb":
        d = _r_peek(p, 1)
        e = _r_peek(p, 2)
        if d == "\"" or d == "'":
            p["i"] += 1
            return _r_string(p, c == "r", c == "b")
        if (c + d == "rb" or c + d == "br") and (e == "\"" or e == "'"):
            p["i"] += 2
            return _r_string(p, True, True)
    name = _r_ident(p)
    if name == "None":
        return None
    if name == "True":
        return True
    if name == "False":
        return False
    if name != None:
        return _r_fail(p, "not a literal: " + name + " (only literal values can be assigned)", start)
    return _r_fail(p, "want a literal value")

def _r_container(p, open):
    """[a, b], (a, b), (a,), (a) (just a), {k: v}; trailing commas are fine."""
    close = {"[": "]", "(": ")", "{": "}"}[open]
    p["i"] += 1
    items = []
    commas = 0
    for _ in range(len(p["s"])):
        _r_space(p)
        if _r_peek(p) == close:
            p["i"] += 1
            break
        if items and commas < len(items):
            if _r_peek(p) == "":
                return _r_fail(p, "want " + close)
            return _r_fail(p, "want , or " + close)
        if _r_peek(p) == "" or _r_peek(p) == "#":
            return _r_fail(p, "want " + close)
        keypos = p["i"]
        v = _r_value(p)
        if p["err"] != None:
            return None
        if open == "{":
            u = _unhashable(v)
            if u != None:
                return _r_fail(p, "unhashable type: " + u, keypos)
            _r_space(p)
            if _r_peek(p) != ":":
                return _r_fail(p, "want : after a dict key")
            p["i"] += 1
            w = _r_value(p)
            if p["err"] != None:
                return None
            v = (v, w)
        items.append(v)
        _r_space(p)
        if _r_peek(p) == ",":
            p["i"] += 1
            commas += 1
    if open == "[":
        return items
    if open == "(":
        if len(items) == 1 and commas == 0:
            return items[0]
        return tuple(items)
    d = {}
    for k, v in items:
        d[k] = v
    return d

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
