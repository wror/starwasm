# ext/reactive.star — reactive variables (EXTENSIONS.md).
#
#   x : 1                 # a reactive variable (top level of the main file)
#   y : x * 10            # recomputed whenever x changes
#   print("y is", y)      # re-run whenever y changes
#
# A program with reactive variables doesn't exit at the end of its top
# level: it reads lines like `x : 5` or `x : f(4)` from standard input, sets the
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
#     function, names of the reactive variables it reads, those of them
#     that must be set for it to run: see relations), so %nodes lists
#     what the top level has run so far, in source order;
#   - then the main module is frozen, as a loaded module is once its top
#     level has run (%prelude._r_freeze(), compiled by direct_call): its
#     values are deep-frozen, so what updates run (definitions, observers
#     and the functions they call) can't mutate non-reactive variables;
#     the "%" variables (the runtime's state) stay mutable;
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
load("../resolve.star", "called_names", "collect_bindings", "dotted_names", "free_names", "read_fields", "target_names")

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
ERRORS = "Error"  # relation x's implicit relation of errors is xError

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

def _top_uses(cx, defined, e, self = None, observer = False, reader = None):
    """The reactive variables top-level expression e reads, checked to be
    defined already; each read is rewritten to %reactive["x"] (for a
    relation, its current member; in an observer, %reactive["x[]"], the
    list of its members). Returns the names, in order of first use, and
    whether e reads `self` (the variable e defines): such reads become
    %prelude._r_self(%reactive, "self"), its previous value or, the first
    time, the identity element (see _in_context); in a relation,
    _r_rel_self(%reactive, %rstate, "self"), the member being replaced.
    In a definition, a relation is read by _r_read: reader is the relation
    being defined (one without a condition), whose update's key picks the
    member read (see _r_read), or None."""
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
            if cx["relations"].get(n, False):
                u.update(_prelude_call("_r_rel_self", [_name(VALUES, posn), _name(STATE, posn), _str(n, posn)], posn))
            else:
                u.update(_prelude_call("_r_self", [_name(VALUES, posn), _str(n, posn)], posn))
            continue
        if not defined.get(n, False):
            _err(cx["mod"], u["pos"], "reactive variable " + n + " used before its definition")
        if n not in deps:
            deps.append(n)
        u.clear()
        if cx["relations"].get(n, False) and not observer:
            args = [_name(VALUES, posn), _name(STATE, posn), _str(n, posn), _str(reader, posn) if reader != None else _none(posn),
                    _str(cx["mod"]["path"], posn), {"kind": "int", "val": posn[0], "pos": posn}]
            u.update(_prelude_call("_r_read", args, posn))
        else:
            u.update(_value_ref(n + "[]" if observer and cx["relations"].get(n, False) else n, posn))
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
    if k == "binop" and e["op"] != "and" and e["op"] != "or" and e["op"] != "??":
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
        parts = [_in_context(e[p]) if e[p] != None else _none(posn) for p in ["lo", "hi", "step"]]
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

def _none(posn):
    """None, generated (not written by the user: "gen")."""
    return {"kind": "name", "id": "None", "pos": posn, "gen": True}

def _defines(e, name):
    """Note that expression e is the value of reactive variable `name`
    (for a struct block, of its fields too: "name.field"), for extensions
    that track where values come from (ext/none.star)."""
    e["defines"] = (name, e["pos"][0])
    if e.get("block", False):
        for a in e["args"]:
            if a["name"] != None:
                _defines(a["value"], name + "." + a["name"])

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

def _tid_stmt(name, deps, relation, posn):
    """%rstate["tid"] = _r_tid(%reactive, %rstate, name, deps, relation):
    the id of the change that triggers the evaluation of name's definition
    (see _r_tid), set before evaluating it."""
    target = {"kind": "index", "x": _name(STATE, posn), "i": _str("tid", posn), "pos": posn, "gen": True}
    names = {"kind": "tuple", "pos": posn, "elems": [_str(d, posn) for d in deps]}
    args = [_name(VALUES, posn), _name(STATE, posn), _str(name, posn), names, _name("True" if relation else "False", posn)]
    return _assign(target, _prelude_call("_r_tid", args, posn), posn)

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
    reactive = {}  # name -> its (last) definition
    redefined = {}  # name -> True, for a name defined more than once (--globalreassign)
    relations = {}  # name -> True, for relations (`a name:`)
    for s in stmts:
        if s["kind"] == "reactive":
            prev = reactive.get(s["name"])
            if prev != None:
                # with --globalreassign, a later definition replaces it
                # (see "redefinitions" below); it must be of the same kind
                if not mc["globalreassign"]:
                    _err(main, s["pos"], "reactive variable " + s["name"] + " defined twice")
                if prev.get("relation", False) != s.get("relation", False):
                    what = "a relation" if s.get("relation", False) else "a lone variable (not a relation)"
                    _err(main, s["pos"], "reactive variable " + s["name"] + " can't be redefined as " + what +
                                         " (defined at " + str(prev["pos"][0]) + ":" + str(prev["pos"][1]) + ")")
                redefined[s["name"]] = True
            reactive[s["name"]] = s
            if s.get("relation", False):
                relations[s["name"]] = True
    if not reactive:
        return
    mc["ext"]["reactive"] = True

    # what else is bound at top level
    bound = {}
    collect_bindings([s for s in stmts if s["kind"] != "reactive"], bound)
    for s in stmts:
        if s["kind"] == "load":
            for i, (local, _) in enumerate(s["names"]):
                if local not in bound:
                    bound[local] = s["namepos"][i]
    # implicit relations: a name that a relation's definition reads and
    # that nothing defines (no reactive definition, no other top-level
    # binding, no builtin) is a relation too, with no definition of its
    # own: it is empty until standard input assigns it members. (In a
    # REPL session, --repl, what is bound only after the relation doesn't
    # count: there, the relation was accepted before that binding was
    # typed, which is then an error, "cannot assign to reactive
    # variable", as for any other one.)
    implicit = []
    for s in stmts:
        if s["kind"] != "reactive" or not s.get("relation", False):
            continue
        uses = []
        free_names(s.get("when"), {}, uses)
        free_names(s["value"], {}, uses)
        # only a name whose fields are read (`name.field`) and that isn't
        # called: any other is "undefined" (a misspelling, a missing def)
        called = {}
        called_names([s.get("when"), s["value"]], called)
        dotted = {}
        dotted_names([s.get("when"), s["value"]], dotted)
        for u in uses:
            n = u["id"]
            r = reactive.get(n)
            if r != None and mc["repl"] and r["pos"] > s["pos"] and not r.get("relation", False) and dotted.get(n, False) and not called.get(n, False):
                # In a REPL session, `request : value` typed after a
                # relation that made request implicit gives it a new value,
                # as `request = value` does: the REPL sends it as standard
                # input when the compiler says so (host/repl_core.mjs).
                _err(main, r["pos"], "cannot assign to reactive variable " + n + " (only standard input changes it: " + n + " : value)")
            if r != None or n.startswith("%") or called.get(n, False) or not dotted.get(n, False):
                continue
            if bound.get(n) != None and not (mc["repl"] and bound[n] > s["pos"]):
                continue
            if cg["is_builtin"](mc, n):
                continue
            reactive[n] = {"kind": "reactive", "name": n, "relation": True, "pos": u["pos"], "value": {"args": []}}
            relations[n] = True
            implicit.append(n)
    # each relation has an implicit one, <name>Error (see _r_reject): a
    # definition with no fields, which is never evaluated; with contagious
    # None, so does every lone variable (a None it may not hold makes an
    # update fail: _r_transact)
    errored = list(relations) if mc["contagious_none"] == False else list(reactive)
    for name in errored:
        ename = name + ERRORS
        if reactive.get(ename) != None:
            what = "relation " if relations.get(name, False) else ""
            _err(main, reactive[ename]["pos"], "reactive variable " + ename + " defined twice (" + what + name + " defines it: its errors)")
        r = reactive[name]
        reactive[ename] = {"kind": "reactive", "name": ename, "relation": True, "pos": r["pos"], "value": {"args": []}}
        relations[ename] = True

    # nothing else may bind a reactive variable at top level
    for n in bound:
        r = reactive.get(n)
        if r != None:
            if bound[n] < r["pos"]:
                # bound first: the reactive definition is what's wrong
                _err(main, r["pos"], "cannot define reactive variable " + n + ": " + n + " is already bound")
            _err(main, bound[n], "cannot assign to reactive variable " + n + " (only standard input changes it: " + n + " : value)")

    cx = {"mod": main, "reactive": reactive, "relations": relations, "uses": []}
    defined = {}
    first = stmts[0]["pos"]
    out = [
        _assign(_name(VALUES, first), {"kind": "dict", "entries": [], "colons": [], "pos": first}, first),
        _assign(_name(NODES, first), {"kind": "list", "elems": [], "pos": first}, first),
        _assign(_name(STATE, first), _state_dict(reactive, relations, [n for n in relations if reactive[n].get("when") != None], _needed(stmts, implicit), first), first),
    ]
    # implicit relations are there from the start, empty (and so are
    # their relations of errors)
    for name in implicit:
        posn = reactive[name]["pos"]
        for i, n in enumerate([name, name + ERRORS]):
            init = _prelude_call("_r_relation", [_name(VALUES, posn), _str(n, posn)], (posn[0], posn[1] + i))
            out.append({"kind": "expr", "pos": posn, "x": init})
            defined[n] = True
    # Redefinitions (--globalreassign): every definition of x assigns it
    # in place on the first run, as written; once a later one has run, its
    # node replaces the earlier one's in %nodes (_r_add_node), which puts
    # %nodes back in an order where each node comes after the variables it
    # reads (not source order: a definition between the two that reads x
    # now runs after x's new one). The redefinition's value counts as a
    # change of x (_r_redefine): what reads x is recomputed. The active
    # definitions may not form a cycle (checked below, as each is added).
    active = {}  # name -> the variables its active definition reads
    seen_def = {}  # names whose first definition was seen
    nthunks = 0
    # what may be unset (relations' current members, and lone variables
    # computed from them, until a relation has a member). With contagious
    # None (the default here), nothing: a relation with no member for an
    # update reads as None (_r_read).
    unset = {} if mc["contagious_none"] != False else dict(relations)
    # with contagious None, a definition may be None only where it says so
    # (`... ?? None`): any other None makes an update fail as a whole
    # (_r_transact), and on the first run leaves the variable unset (_r_init)
    strict = mc["contagious_none"] != False
    for s in stmts:
        k = s["kind"]
        if defined:
            out.append(_input_call(s["pos"][0], s["pos"]))  # a sync point
        thunk = None
        if k == "reactive":
            name = s["name"]
            posn = s["pos"]
            relation = relations.get(name, False)
            redef = seen_def.get(name, False)  # a later definition of it (--globalreassign)
            seen_def[name] = True
            cond = s.get("when")  # `a name when cond:`
            cdeps = []
            reader = name if relation and cond == None else None
            if cond != None:
                cdeps, cond_self = _top_uses(cx, defined, cond, name)
                if cond_self:
                    _in_context(cond)
            if s["value"].get("block", False):
                _field_deps(s["value"], name, cx["reactive"])  # (before reads are rewritten)
            deps, has_self = _top_uses(cx, defined, s["value"], name, reader = reader)
            if has_self:
                _in_context(s["value"])
            deps = cdeps + [d for d in deps if d not in cdeps]
            # a struct block that reads no reactive variable is the
            # constructor of the values standard input gives it (_r_ctor):
            # its fields, in order, and their values as defaults
            ctor = None
            if not deps and not has_self and cond == None and s["value"].get("block", False):
                ctor = [_shape(s["value"], posn), _copy(s["value"])]
            if ctor != None or redefined.get(name, False):
                cargs = [_name(STATE, posn), _str(name, posn)] + (ctor if ctor != None else [_none(posn), _none(posn)])
                out.append({"kind": "expr", "pos": posn, "x": _prelude_call("_r_ctor", cargs, posn)})
            # the triggering change's id: for a relation, which member it
            # adds or replaces; for a lone struct read from relations, its id
            from_rel = len([d for d in deps if relations.get(d, False)]) > 0
            implicit = s.get("implicit_id", False)
            keyed = relation or (from_rel and implicit)
            if implicit:
                if relation:
                    idv = _prelude_call("_r_rel_id", [_name(VALUES, posn), _name(STATE, posn), _str(name, posn)], posn)
                elif from_rel:
                    idv = _prelude_call("_r_lone_id", [_name(VALUES, posn), _name(STATE, posn), _str(name, posn)], posn)
                else:
                    idv = _next_id(name, posn)
                s["value"]["args"].append({"name": "id", "star": "", "value": idv, "pos": posn})
            defined[name] = True
            _defines(s["value"], name)
            # computed only once what it reads is set
            required = [d for d in deps if unset.get(d, False)]
            if required:
                unset[name] = True
            if redefined.get(name, False):
                # its kind, field shapes and condition are this definition's
                # (_r_apply, _r_reject)
                block = s["value"].get("block", False)
                args = [_name(STATE, posn), _str(name, posn), _shape(s["value"], posn) if relation else _none(posn),
                        _name("True" if cond != None else "False", posn),
                        _shape(s["value"], posn) if block else {"kind": "tuple", "pos": posn, "elems": []},
                        _nullable_tuple(s["value"], posn)]
                out.append({"kind": "expr", "pos": posn, "x": _prelude_call("_r_meta", args, posn)})
            redef_value = None
            if relation and redef:
                pass  # a redefined relation keeps its members
            elif relation:
                # it starts empty (its definition is evaluated only on updates)
                # (and so does its implicit relation of errors)
                for i, n in enumerate([name, name + ERRORS]):
                    init = _prelude_call("_r_relation", [_name(VALUES, posn), _str(n, posn)], (s["colon"][0], s["colon"][1] + i))
                    out.append({"kind": "expr", "pos": posn, "x": init})
                defined[name + ERRORS] = True
            else:
                if strict and not redef:
                    # its relation of errors (with contagious None)
                    init = _prelude_call("_r_relation", [_name(VALUES, posn), _str(name + ERRORS, posn)], posn)
                    out.append({"kind": "expr", "pos": posn, "x": init})
                    defined[name + ERRORS] = True
                if keyed:
                    out.append(_tid_stmt(name, deps, False, posn))
                value = s["value"]
                if required:
                    value = _if_ready(value, required, _name("%prelude._unset", posn))
                if strict:
                    # what it reads may be unset (a None it may not hold
                    # left it so): then it isn't computed, and is unset too
                    # (_r_skip); else a None its definition doesn't allow
                    # leaves it unset
                    lone = [d for d in deps if d != name and not relations.get(d, False)]
                    if lone:
                        names = {"kind": "tuple", "pos": posn, "elems": [_str(d, posn) for d in lone]}
                        test = _prelude_call("_r_set", [_name(STATE, posn), names], posn)
                        skip = _prelude_call("_r_skip", [_name(STATE, posn), _str(name, posn)], posn)
                        value = {"kind": "cond", "test": test, "then": value, "else_": skip, "pos": posn}
                    value = _prelude_call("_r_init", [_name(STATE, posn), _str(name, posn), value], posn)
                if redef:
                    redef_value = value  # assigned once its node is in place
                else:
                    out.append(_assign(_value_ref(name, posn), value, s["colon"]))
            if redefined:
                active[name] = [d for d in deps if d != name]
                cyc = _cycle(active, name)
                if cyc:
                    _err(main, posn, "reactive variable " + name + " would depend on itself: " + " -> ".join(cyc) +
                                     " (a redefinition replaces the earlier definition everywhere)")
            if cond != None:
                # %r.<n>() = _r_when(%reactive, %rstate, name, %r.<n>.when,
                # %r.<n>.value): the condition and the definition are
                # evaluated per member, by _r_when
                fname = "%r." + str(nthunks)
                fns = []
                for suffix, e in [(".when", cond), (".value", s["value"])]:
                    e = _copy(e)
                    if suffix == ".value":
                        e = _partial(e, name, True)
                    out.append({"kind": "def", "name": fname + suffix, "params": [], "pos": posn, "display": "<toplevel>",
                                "body": [{"kind": "return", "value": e, "pos": posn}]})
                    fns.append(_name(fname + suffix, posn))
                call = _prelude_call("_r_when", [_name(VALUES, posn), _name(STATE, posn), _str(name, posn)] + fns, posn)
                thunk = ([{"kind": "return", "value": call, "pos": posn}], _str(name, posn))
            elif deps or relation:
                body = [{"kind": "return", "value": _partial(_copy(s["value"]), name, relation), "pos": posn}]
                if keyed:
                    body = [_tid_stmt(name, deps, relation, posn)] + body
                thunk = (body, _str(name, posn))
        elif k == "expr":
            deps, _ = _top_uses(cx, defined, s["x"], observer = True)
            # observers read relations' lists, which are always set
            required = [d for d in deps if unset.get(d, False) and not relations.get(d, False)]
            lone = [d for d in deps if not relations.get(d, False)]
            if required:
                out.append({"kind": "expr", "pos": s["pos"], "x": _if_ready(s["x"], required, _none(s["pos"]))})
            elif strict and lone:
                # (not run while a variable it reads is unset: _r_init)
                p = s["pos"]
                names = {"kind": "tuple", "pos": p, "elems": [_str(d, p) for d in lone]}
                test = _prelude_call("_r_set", [_name(STATE, p), names], p)
                out.append({"kind": "expr", "pos": p, "x": {"kind": "cond", "test": test, "then": s["x"], "else_": _none(p), "pos": p}})
            else:
                out.append(s)
            if deps:
                thunk = ([{"kind": "expr", "x": _copy(s["x"]), "pos": s["pos"]}], _none(s["pos"]))
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
                {"kind": "tuple", "pos": p, "elems": [_str(d, p) for d in required]},
            ]}
            if redefined.get(s.get("name"), False) and k == "reactive":
                # (replacing an earlier definition's node)
                out.append({"kind": "expr", "pos": p, "x": _prelude_call("_r_add_node", [_name(NODES, p), entry], p)})
            else:
                out.append({"kind": "expr", "pos": p, "x": _call({"kind": "dot", "x": _name(NODES, p), "name": "append", "pos": p}, [entry], p)})
            if k == "reactive" and redef_value != None:
                # x's new value, as a change of x: what reads it is recomputed
                args = [_name(VALUES, p), _name(NODES, p), _name(STATE, p), _str(s["name"], p), redef_value]
                out.append({"kind": "expr", "pos": p, "x": _prelude_call("_r_redefine", args, s["colon"])})
        elif k == "reactive" and redef_value != None:
            # a redefinition that reads no reactive variable: x is now a
            # source, which nothing recomputes (its earlier node goes)
            p = s["pos"]
            out.append({"kind": "expr", "pos": p, "x": _prelude_call("_r_drop_node", [_name(NODES, p), _str(s["name"], p)], p)})
            args = [_name(VALUES, p), _name(NODES, p), _name(STATE, p), _str(s["name"], p), redef_value]
            out.append({"kind": "expr", "pos": p, "x": _prelude_call("_r_redefine", args, s["colon"])})
    p = stmts[-1]["pos"]
    out.append({"kind": "expr", "pos": p, "x": _prelude_call("_r_freeze", [], p)})
    out.append(_input_call(0, p))
    main["stmts"] = out

# ---- partial updates: in an update, a struct block's field that reads
# other reactive variables is recomputed only if one of them changed in
# the update; else it keeps its value from the previous one (for a
# relation, the member being replaced). A field that reads none (a
# constant, or a counter reading only the variable's own previous value,
# `n: x.n + 1`) is always recomputed. Fields of nested blocks likewise, each on its own. A new
# member, or a previous value without the field, gets every field computed.

def _field_deps(block, self, reactive):
    """Mark each field of struct block `block` (of variable self) with the
    reactive variables it reads ("%deps", self excluded); nested blocks'
    fields too. (The block's implicit id isn't one of its fields here.)"""
    for a in block["args"]:
        if a["name"] == None or a["name"] == "id":
            continue
        v = a["value"]
        if v.get("block", False):
            _field_deps(v, self, reactive)
            continue
        uses = []
        free_names(v, {}, uses)
        deps = []
        for u in uses:
            n = u["id"]
            if n != self and reactive.get(n) != None and n not in deps:
                deps.append(n)
        a["%deps"] = deps

def _partial(block, name, relation, prev = None):
    """block, a copy of variable name's struct block for an update, with
    each field marked by _field_deps that reads other reactive variables
    becoming `value if _r_fresh(%rstate, prev, field, deps) else
    _r_sub(prev, field)`; prev: the previous value (for a relation, the member being
    replaced), or for a nested block, its field of that."""
    if not block.get("block", False):
        return block
    posn = block["pos"]
    if prev == None:
        if relation:
            prev = _prelude_call("_r_rel_self", [_name(VALUES, posn), _name(STATE, posn), _str(name, posn)], posn)
        else:
            prev = _prelude_call("_r_self", [_name(VALUES, posn), _str(name, posn)], posn)
    for a in block["args"]:
        if a["name"] == None or a["name"] == "id":
            continue
        v = a["value"]
        p = v["pos"]
        if v.get("block", False):
            _partial(v, name, relation, _prelude_call("_r_sub", [_copy(prev), _str(a["name"], p)], p))
            continue
        if not a.get("%deps"):
            continue  # (none: always recomputed)
        names = {"kind": "tuple", "pos": p, "elems": [_str(d, p) for d in a["%deps"]]}
        test = _prelude_call("_r_fresh", [_name(STATE, p), _copy(prev), _str(a["name"], p), names], p)
        old = _prelude_call("_r_sub", [_copy(prev), _str(a["name"], p)], p)
        a["value"] = {"kind": "cond", "test": test, "then": v, "else_": old, "pos": p}
    return block

def _cycle(active, name):
    """A path name -> ... -> name through the variables the active
    definitions read, or None."""
    path = [name]
    seen = {}
    stack = [(name, 0)]
    for _ in range(1 << 30):
        if not stack:
            return None
        n, i = stack[-1]
        deps = active.get(n, [])
        if i >= len(deps):
            stack.pop()
            path.pop()
            continue
        stack[-1] = (n, i + 1)
        d = deps[i]
        if d == name:
            return path + [name]
        if d in active and not seen.get(d, False):
            seen[d] = True
            stack.append((d, 0))
            path.append(d)
    return None

def _if_ready(e, required, otherwise):
    """`e if %prelude._r_ready(%reactive, required) else otherwise`."""
    posn = e["pos"]
    names = {"kind": "tuple", "pos": posn, "elems": [_str(d, posn) for d in required]}
    test = _prelude_call("_r_ready", [_name(VALUES, posn), names], posn)
    return {"kind": "cond", "test": test, "then": e, "else_": otherwise, "pos": posn}

def _marked_none(e):
    """Does definition (or field) e allow None: is it `... ?? None`, or
    None itself? (With contagious None, any other one that is None makes
    its update fail as a whole: _r_bad.)"""
    if e["kind"] == "binop" and e["op"] == "??":
        e = e["y"]
    return e["kind"] == "name" and e["id"] == "None"

def _nullable(value, prefix, out):
    """Append to out the paths ("" for the value itself, "f" for a field
    of a struct block, "f.g" in a nested one) of value, a definition, that
    may be None (_marked_none)."""
    if not value.get("block", False):
        if _marked_none(value):
            out.append(prefix)
        return
    for a in value["args"]:
        if a["name"] != None and a["name"] != "id":
            _nullable(a["value"], prefix + "." + a["name"] if prefix else a["name"], out)

def _nullable_tuple(value, posn):
    out = []
    if value.get("kind") != None:
        _nullable(value, "", out)
        if _none_inside(value):
            out.append("*")
    return {"kind": "tuple", "pos": posn, "elems": [_str(p, posn) for p in out]}

def _shape(block, posn):
    """The fields of a struct block, as a tuple of (name, shape of the
    field's own block: () unless it is a nested one)."""
    elems = []
    for a in block["args"]:
        if a["name"] != None:
            sub = _shape(a["value"], posn) if a["value"].get("block", False) else {"kind": "tuple", "pos": posn, "elems": []}
            elems.append({"kind": "tuple", "pos": posn, "elems": [_str(a["name"], posn), sub]})
    return {"kind": "tuple", "pos": posn, "elems": elems}

def _needed(stmts, implicit):
    """{implicit relation: the fields its members must have}: those the
    relations' definitions read other than in the left operand of a `??`
    (read_fields: where a missing field just gives the default)."""
    out = {}
    for n in implicit:
        fields = {}
        for s in stmts:
            if s["kind"] == "reactive" and s.get("relation", False):
                read_fields([s.get("when"), s["value"]], n, fields)
        out[n] = sorted([f for f, guarded in fields.items() if not guarded])
    return out

def _none_inside(x):
    """Does AST x write None other than as the `?? None` that lets a
    definition (or field) be None?"""
    t = type(x)
    if t == "list" or t == "tuple":
        return len([v for v in x if _none_inside(v)]) > 0
    if t != "dict":
        return False
    if x.get("kind") == "name" and x.get("id") == "None":
        return True
    if x.get("kind") == "binop" and x.get("op") == "??" and type(x.get("y")) == "dict" and x["y"].get("kind") == "name" and x["y"].get("id") == "None":
        return _none_inside(x["x"])
    return len([v for k, v in x.items() if k != "pos" and _none_inside(v)]) > 0

def _state_dict(reactive, relations, whens, need, posn):
    """{"lineno": 0, "relations": {name: shape, ...}, "whens": {name: True,
    ...}, "tid": None, "wself": None, "trigger": None, "changed": {}}: the
    runtime's state
    (see _reactive_input); a relation's shape is its block's fields
    (_shape; the implicit id isn't one: it is never None), for
    _r_nones; whens are the relations with a condition (`a name when
    cond:`). (A relation of errors, xError, has no fields here: its members
    hold a None, and always apply.) Also "shapes": every reactive
    variable's shape (() for one that isn't a struct block), "nullable":
    the paths in each that may be None (_nullable), "unset": the variables
    not computed yet (_r_init), "abort": the Nones that make the update
    under way fail (_r_bad, _r_transact), "need": the fields each member of
    an implicit relation must have (_needed). (A nullable "*": the
    definition writes a None somewhere in its value, _none_inside, which a
    value from standard input may then hold anywhere: _r_input_bad.)"""
    def table(names, what):
        es = []
        for i, n in enumerate(sorted(names)):
            p = (posn[0], posn[1] + i)
            v = reactive[n]["value"]
            if what == "shape":
                x = _shape(v, p) if v.get("block", False) or v.get("kind") == None else {"kind": "tuple", "pos": p, "elems": []}
            elif what == "nullable":
                x = _nullable_tuple(v, p)
            else:
                x = _name("True", p)
            es.append((_str(n, p), x))
        return {"kind": "dict", "entries": es, "colons": [e[0]["pos"] for e in es], "pos": posn}
    entries = [
        (_str("lineno", posn), {"kind": "int", "val": 0, "pos": posn}),
        (_str("relations", posn), table(relations, "shape")),
        (_str("whens", posn), table(whens, None)),
        (_str("shapes", posn), table(reactive, "shape")),
        (_str("nullable", posn), table(reactive, "nullable")),
        (_str("unset", posn), {"kind": "dict", "entries": [], "colons": [], "pos": posn}),
        (_str("abort", posn), {"kind": "list", "elems": [], "pos": posn}),
        (_str("tid", posn), _none(posn)),
        (_str("wself", posn), _none(posn)),
        (_str("trigger", posn), _none(posn)),
        (_str("changed", posn), {"kind": "dict", "entries": [], "colons": [], "pos": posn}),
        (_str("ctors", posn), {"kind": "dict", "entries": [], "colons": [], "pos": posn}),
        (_str("need", posn), {"kind": "dict", "pos": posn, "colons": [posn for _ in need],
                              "entries": [(_str(n, posn), {"kind": "tuple", "pos": posn, "elems": [_str(f, posn) for f in fs]}) for n, fs in sorted(need.items())]}),
    ]
    return {"kind": "dict", "entries": entries, "colons": [posn for _ in entries], "pos": posn}

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

def _call(fn, args, posn):
    # codegen tells a call's arguments apart by position (id_of), so each
    # gets its own column
    args = [{"name": None, "star": "", "value": a, "pos": (posn[0], posn[1] + i)} for i, a in enumerate(args)]
    return {"kind": "call", "fn": fn, "args": args, "pos": posn, "lparen": posn}

def _input_call(before, posn):
    """_reactive_input(%reactive, %nodes, %rstate, before) as a
    statement."""
    args = [_name(VALUES, posn), _name(NODES, posn), _name(STATE, posn), {"kind": "int", "val": before, "pos": posn}]
    return {"kind": "expr", "pos": posn, "x": _call(_name("%prelude._reactive_input", posn), args, posn)}

def direct_call(cg, mc, fc, e, kind, w):
    """%prelude._r_freeze() (generated, at the end of the main module's
    top level): deep-freeze the main module's values, as codegen does for
    a loaded module once it has run: every module variable and function
    value, except the "%" ones (the runtime's state: %reactive, %nodes,
    ...). Unbound variables (null) are skipped by rt_freeze."""
    fn = e["fn"]
    if not mc["ext"].get("reactive", False) or fn["kind"] != "name" or fn["id"] != "%prelude._r_freeze":
        return None
    mod = mc["mod"]
    code = [call("rt_freeze", gget(mod["globals"][n])) for n in sorted(mod["globals"]) if not n.startswith("%")]
    code += [call("rt_freeze", gget("fv_" + mod["funcs"][n])) for n in sorted(mod["funcs"]) if not n.startswith("%")]
    return code + [gget("None")]

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
    """Read lines of assignments `x : value`, separated by ";", set those
    reactive variables, and recompute what depends on them
    (_reactive_update). A value is a literal (_r_value), given to x's
    constructor if it has one (_r_construct). Until the end
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
        p = {"s": line, "i": 0, "err": None, "depth": 0, "lineno": state["lineno"]}
        assigns = _r_line(p, values, nodes, state)
        if p["err"] != None:
            _eprint("<stdin>:" + str(state["lineno"]) + ":" + str(p["errpos"] + 1) + ": " + p["err"])
            continue
        if not assigns:
            continue
        # (_n_tag, _n_none, _n_skip: ext/none.star; a None assigned here
        # passed through the variable, at this line)
        _r_transact(values, nodes, state, [
            (n, _n_tag(v, "reactive", n, "<stdin>", state["lineno"]))
            for n, v in assigns
        ], 0)

def _r_transact(values, nodes, state, assigns, depth):
    """Apply assigns and recompute what depends on them (_reactive_update),
    as a whole or not at all. If it fails (an error that isn't caught, or
    with --rollback any error), every reactive variable gets its value
    back. With contagious None, if a variable gets a None its definition
    doesn't allow (_r_bad), the update stops there and is undone too; then
    the variable's relation of errors, xError, gets a member for each such
    None, as an update of its own (depth 1), and what reads it is
    recomputed. (If that one fails as well, nothing more is done: it is
    reported on standard error.) Observers run only once an update has
    succeeded, each with the values it left."""
    saved = dict(values)
    saved_unset = dict(state["unset"])
    state["abort"] = []
    errors = _n_errors()  # (ext/none.star: with --rollback, caught errors undo the update)
    observers = []
    ok = _try(lambda: _reactive_update(values, nodes, state, assigns, observers))
    aborted = state["abort"]
    state["abort"] = []
    state["changed"] = {}
    state["tid"] = None
    state["wself"] = None
    state["trigger"] = None
    if not ok or aborted or _n_failed(errors):
        values.clear()
        values.update(saved)
        state["unset"].clear()
        state["unset"].update(saved_unset)
    if not ok or _n_failed(errors):
        return
    if aborted:
        if depth > 0:
            for name, _, _, f, _ in aborted:
                _eprint("update of " + name + "'s errors not applied: " + (f or name) + " is None")
            return
        _r_transact(values, nodes, state, [
            (name + "Error", struct(**{name + "_id": mid, "trigger": trigger, "field": f, "value": x}))
            for name, mid, trigger, f, x in aborted
        ], depth + 1)
        return
    # (an observer that fails undoes the update, as an error in the update
    # does: without contagious None, or with --rollback)
    if not _try(lambda: [_n_try(f) for f in observers]) or _n_failed(errors):
        values.clear()
        values.update(saved)
        state["unset"].clear()
        state["unset"].update(saved_unset)

def _r_freeze():
    """A placeholder: a call of it in the main module is compiled to code
    that freezes the module (direct_call in compiler/ext/reactive.star)."""
    pass

def _reactive_update(values, nodes, state, assigns, observers):
    """Set the assigned variables, then go through nodes (source order is
    a topological order) recomputing each variable that reads a changed
    one, and appending to observers each observer that does (to be run
    once the update is done: _r_transact). A recomputed variable
    counts as changed only if its new value differs (!=) from the old (or,
    with ext/none.star, is a None that came another way than the old). A
    relation's new value is a member, added to its list or replacing the
    one with the same id (_r_upsert); it always counts as changed: an
    update removes a member and adds one. With contagious None, a value
    that is None, or has a None field, where its definition doesn't allow
    it (_r_bad, _r_reject) stops the update: _r_transact undoes it. A node
    that reads a variable not
    set yet (without contagious None: a relation with no member, or a lone
    variable computed from one) is skipped; an observer that reads a
    variable left unset (_r_init) too."""
    rels = state["relations"]
    changed = {}
    state["changed"] = changed  # for _r_tid
    for name, v in assigns:
        v = _r_with_id(values, name, v, name in rels)
        state["trigger"] = name
        if _r_input_bad(values, state, name, v):
            return
        if name in rels:
            if _r_reject(values, state, name, [v]):
                return
            _r_upsert(values, name, v)
        else:
            if _r_bad(values, state, name, v):
                return
            values[name] = v
            state["unset"].pop(name, None)
        changed[name] = True
    for name, f, deps, required in nodes[:]:  # a copy: an error would leave nodes marked as iterated
        hit = False
        for d in deps:
            if changed.get(d, False):
                hit = True
                break
        if not hit or not _r_ready(values, required):
            continue
        # (_n_try: with contagious None, an error in f is printed and gives
        # None; without, it is plain f(), and the error ends the update)
        if name == None:
            if _r_set(state, deps):
                observers.append(f)
            continue
        if not _r_set(state, [d for d in deps if d != name]):
            # (with contagious None: what it reads isn't set yet, so it
            # isn't computed: it would read a None its type doesn't have)
            continue
        state["trigger"] = [d for d in deps if changed.get(d, False)][0]  # for _r_reject
        if name in rels and not _n_on() and _r_unmatched(values, state, name, deps):
            continue  # (without contagious None) what it reads has no member for this update
        v = _n_try(f)
        if name in rels:
            _r_apply(values, state, name, v, changed)
            if state["abort"]:
                return
            continue
        if _r_bad(values, state, name, v):
            return
        if v != values[name] or _n_changed(values[name], v):
            changed[name] = True
        values[name] = v
        state["unset"].pop(name, None)

def _r_bad(values, state, name, v):
    """With contagious None: does v, lone variable name's new value, have a
    None where its definition doesn't allow it (that isn't `... ?? None`)?
    Then the update fails: each such None is noted in state["abort"], as
    (name, the id of v if it has one, the trigger, the field, the None)."""
    nones = []
    _r_nones(v, state["shapes"].get(name, ()), "", state["nullable"].get(name, ()), nones)
    if not nones:
        return False
    mid = getattr(v, "id", None) if type(v) == "struct" else None
    state["abort"] += [(name, mid, state["trigger"], f, x) for f, x in nones]
    return True

def _r_skip(state, name):
    """Lone variable name's value on the first run when a variable its
    definition reads is unset: name is unset too, and its definition isn't
    evaluated (_r_init)."""
    state["unset"][name] = True
    return None

def _r_input_bad(values, state, name, v):
    """With contagious None: is v, given to reactive variable name on
    standard input, unfit for it? It is if it has a None inside (an
    element, a field, at any depth) where the definition doesn't allow one
    (its nullable paths; anywhere, "*", if the definition writes a None in
    its value), if it is of another type than the value it replaces (for a
    relation, its members: _r_mismatch), or if a member of an implicit
    relation lacks a field the program reads from it (state["need"]). Then
    the update fails, as for a None (_r_bad): each fault is noted in
    state["abort"], with a None that carries the reason. (Not for a
    relation of errors, whose members hold a None.)"""
    if not _n_on() or _n_none(v) or (name.endswith("Error") and name[:-5] in state["shapes"]):
        return False
    nullable = state["nullable"].get(name, ())
    found = []
    if "*" not in nullable:
        _r_inner_nones(v, "", nullable, found)
    why = ""
    if name in state["relations"]:
        members = values[name + "[]"]
        old = members[0] if members else None
        if type(v) != "struct":
            why = "it is " + _r_a(type(v)) + ", not a struct (a member of relation " + name + ")"
        for f in state["need"].get(name, ()):
            if not why and not hasattr(v, f):
                why = "it has no field " + f + ", which the program reads"
    else:
        old = values[name]
    if not why and old != None and not _is_unset(old) and not _is_id(old):
        why = _r_mismatch(old, v, "")
    if why:
        _eprint("<stdin>:" + str(state["lineno"]) + ": " + name + ": " + why)
        found.append(("", _n_tag(None, "error", why, "<stdin>", state["lineno"])))
    if not found:
        return False
    mid = getattr(v, "id", None) if type(v) == "struct" else None
    state["abort"] += [(name, mid, state["trigger"], f, x) for f, x in found]
    return True

def _r_inner_nones(v, path, nullable, out):
    """Append to out (path, the None) for each None inside v (not v itself)
    at a path not in nullable: "f" for a field (a nested one "f.g"), "[i]"
    for an element, a dict's value or key."""
    t = type(v)
    parts = []
    if t == "struct":
        parts = [(path + "." + f if path else f, getattr(v, f)) for f in dir(v)]
    elif t == "list" or t == "tuple":
        parts = [(path + "[" + str(i) + "]", x) for i, x in enumerate(v)]
    elif t == "dict":
        for k, x in v.items():
            parts.append((path + "[" + repr(k) + "]", k))
            parts.append((path + "[" + repr(k) + "]", x))
    for p, x in parts:
        if _n_none(x):
            if p not in nullable:
                out.append((p, x))
        else:
            _r_inner_nones(x, p, nullable, out)

def _r_a(word):
    return ("an " if word[0] in "aeiou" else "a ") + word

def _r_mismatch(old, new, path):
    """Why new, a value from standard input, isn't of the type of old, the
    value it replaces ("" if it is, as far as old shows: an int may be
    given for a float, an empty list or dict says nothing of its elements;
    of a struct, the fields both have)."""
    if _n_none(old) or _n_none(new) or _is_id(old):
        return ""
    to = type(old)
    tn = type(new)
    where = " (" + path + ")" if path else ""
    if to != tn and not (to == "float" and tn == "int"):
        return "it is " + _r_a(tn) + where + ", not " + _r_a(to)
    if to == "list" and old:
        for i, x in enumerate(new):
            m = _r_mismatch(old[0], x, path + "[" + str(i) + "]")
            if m:
                return m
    elif to == "tuple":
        if len(old) != len(new):
            return "it is a tuple of " + str(len(new)) + where + ", not of " + str(len(old))
        for i, x in enumerate(new):
            m = _r_mismatch(old[i], x, path + "[" + str(i) + "]")
            if m:
                return m
    elif to == "dict" and old:
        k0, x0 = old.items()[0]
        for k, x in new.items():
            m = _r_mismatch(k0, k, path + "[key]") or _r_mismatch(x0, x, path + "[" + repr(k) + "]")
            if m:
                return m
    elif to == "struct":
        # (the fields of both: a member may have others, a reference; what
        # it must have, the constructor gives it, or state["need"] asks)
        for f in dir(new):
            if hasattr(old, f):
                m = _r_mismatch(getattr(old, f), getattr(new, f), path + "." + f if path else f)
                if m:
                    return m
    return ""

def _r_init(state, name, v):
    """v, the value of lone variable name's definition on the first run: if
    it has a None its definition doesn't allow (_r_bad), name is unset
    until an update computes it, and what reads it isn't run till then (it
    reads as v, the None, in the definitions computed on this run)."""
    nones = []
    _r_nones(v, state["shapes"].get(name, ()), "", state["nullable"].get(name, ()), nones)
    if nones:
        state["unset"][name] = True
    return v

def _r_set(state, names):
    """Are none of names unset (_r_init)?"""
    for n in names:
        if state["unset"].get(n, False):
            return False
    return True

# ---- relations (`a name:` / `an name:` + a struct block): a reactive list
# of structs, values[name + "[]"], which starts empty; values[name] is its
# current member, the one last added (or _unset while it has none), which is
# what definitions read (observers read the list).

def _unset():
    """The value of a variable not computed yet (a relation with no member,
    or a lone variable computed from one)."""
    pass

def _is_unset(x):
    return type(x) == "builtin_function_or_method" and x == _unset

def _r_ready(values, names):
    """Are the variables names all set?"""
    for n in names:
        if _is_unset(values[n]):
            return False
    return True

def _r_apply(values, state, name, v, changed):
    """Apply v, the value of relation name's definition: a member, added
    or replacing the one with its id (for a relation with a condition,
    whether _r_when changed it). A member that failed, or has a None
    field, isn't applied (_r_reject)."""
    if state["whens"].get(name, False):
        if _n_none(v):  # the condition or the block failed
            _r_reject(values, state, name, [v])
            state["wself"] = None
        elif v:  # _r_when updated it
            changed[name] = True
        return
    if _r_reject(values, state, name, [v]):
        return
    _r_upsert(values, name, v)
    changed[name] = True

def _r_meta(state, name, shape, when, fields, nullable):
    """Relation name's kind as its (re)definition says (--globalreassign):
    its fields' shape (or None: not a relation) and whether it has a
    condition; for any reactive variable, its block's shape (fields: ()
    if it isn't one) and the paths that may be None (_nullable)."""
    if shape != None:
        state["relations"][name] = shape
    state["whens"][name] = when
    state["shapes"][name] = fields
    state["nullable"][name] = nullable

def _r_add_node(nodes, entry):
    """Add node entry (name, function, deps, required), replacing the node
    of the same name (an earlier definition of it, --globalreassign), and
    put nodes in an order in which each comes after the nodes of the
    variables it reads (else in the order they were added)."""
    name = entry[0]
    rest = [n for n in nodes if n[0] == None or n[0] != name]
    rest.append(entry)
    producers = {}
    for n in rest:
        if n[0] != None:
            producers[n[0]] = True
    done = {}  # names whose node is placed
    placed = [False for _ in rest]
    out = []
    for _ in range(len(rest)):
        for i, n in enumerate(rest):
            if placed[i]:
                continue
            ready = True
            for d in n[2]:
                if d != n[0] and producers.get(d, False) and not done.get(d, False):
                    ready = False
                    break
            if ready:
                placed[i] = True
                out.append(n)
                if n[0] != None:
                    done[n[0]] = True
                break
    if len(out) != len(rest):
        fail("reactive variables depend on each other in a cycle")
    nodes.clear()
    nodes.extend(out)

def _r_drop_node(nodes, name):
    """Remove the node of name (redefined, --globalreassign, by a value that
    reads no reactive variable)."""
    out = [n for n in nodes if n[0] == None or n[0] != name]
    nodes.clear()
    nodes.extend(out)

def _r_redefine(values, nodes, state, name, v):
    """A redefinition of lone variable name (--globalreassign) gave value
    v: set it, and recompute what reads it, as for standard input."""
    if _n_on():
        _r_transact(values, nodes, state, [(name, v)], 0)
        return
    observers = []
    _reactive_update(values, nodes, state, [(name, v)], observers)
    for f in observers:
        f()
    state["changed"] = {}
    state["tid"] = None
    state["wself"] = None
    state["trigger"] = None

def _r_sub(x, f):
    """Field f of x, a previous value (_partial); the identity if it has
    none."""
    if type(x) == "struct" and hasattr(x, f):
        return getattr(x, f)
    return _identity

def _r_fresh(state, prev, f, deps):
    """Is field f of a struct block, which reads reactive variables deps,
    recomputed in this update (_partial)? Yes if one of them changed in
    it, or if the previous value prev has no field f (a new member)."""
    if type(prev) != "struct" or not hasattr(prev, f):
        return True
    changed = state["changed"]
    for d in deps:
        if changed.get(d, False):
            return True
    return False

def _r_shared_key(values, state, x, v):
    """The field that relation x and v, a member of another reactive
    variable, both have whose name ends in "id" (other than id itself),
    the latest alphabetically; None if there is none. x's fields are its
    block's (its shape) and its current member's."""
    if type(v) != "struct":
        return None
    fields = [f for f, _ in state["relations"].get(x, ())]
    cur = values[x]
    if type(cur) == "struct":
        fields += dir(cur)
    best = None
    for f in fields:
        if f != "id" and f.endswith("id") and hasattr(v, f) and (best == None or f > best):
            best = f
    return best

def _r_member(values, state, name, reader, tid):
    """The member of relation name for the update of reader's member tid:
    the last one whose field reader + "_id" is tid; for a member without
    that field, that has a field ending in "id" that reader has too
    (_r_shared_key), whose value of it is that of reader's member tid; for
    a member without either, whose id is tid. _unset if there is none."""
    key = reader + "_id"
    rm = None
    for m in values[reader + "[]"]:
        if hasattr(m, "id") and m.id == tid:
            rm = m
    found = _unset
    for m in values[name + "[]"]:
        if hasattr(m, key):
            hit = getattr(m, key) == tid
        else:
            f = _r_shared_key(values, state, reader, m)
            if f != None and rm != None and hasattr(rm, f):
                hit = getattr(m, f) == getattr(rm, f)
            else:
                hit = getattr(m, "id", None) == tid
        if hit:
            found = m
    return found

def _r_read(values, state, name, reader, file, line):
    """Relation name, read in a definition (at file:line): in that of
    relation reader (without a condition), its member for the update's
    key (_r_member); else, or if the update has no key, its current
    member. With contagious None, if there is none (it is empty, or no
    member matches), a None that says so (provenance: ("relation", name,
    file, line)); without, _unset (the update skips such a definition:
    _r_unmatched)."""
    v = values[name]
    tid = state["tid"]
    if reader != None and tid != None and not _is_unset(v):
        v = _r_member(values, state, name, reader, tid)
    if _is_unset(v) and _n_on():
        return _n_tag(None, "relation", name, file, line)
    return v

def _r_unmatched(values, state, name, deps):
    """Without contagious None: does a relation that relation name's
    definition reads have no member for this update (_r_read)?"""
    if state["whens"].get(name, False):
        return False
    tid = _r_tid(values, state, name, deps, True)
    if tid == None:
        return False
    for d in deps:
        if d != name and d in state["relations"] and _is_unset(_r_member(values, state, d, name, tid)):
            return True
    return False

def _r_relation(values, name):
    """Relation name, empty."""
    values[name + "[]"] = []
    values[name] = _unset

def _r_nones(v, shape, path, nullable, out):
    """Append to out (field, the None) for each None among the fields of
    v, a new value of a reactive variable (shape: its block's fields,
    ((name, shape of a nested block), ...), see _shape; a nested block's
    fields are "outer.inner"); if v itself is None, ("", v); except where
    the definition allows a None: the paths in nullable (_nullable). (Only
    with contagious None: without, _n_none is always false.)"""
    if _is_id(v):
        # a self-reference with no previous value, left as it is (`f:
        # x.f` in a new member of x): nothing computed it
        v = _n_tag(None, "self", path, "", 0) if _n_on() else v
    if _n_none(v):
        if path not in nullable:
            out.append((path, v))
        return
    for f, sub in shape:
        if hasattr(v, f):
            _r_nones(getattr(v, f), sub, path + "." + f if path else f, nullable, out)

def _r_reject(values, state, name, members):
    """Should members, the new members of relation name, not be applied,
    because one of them is None or has a None field (where its definition
    doesn't allow it)? Then the update fails (_r_transact): each of those
    Nones is noted in state["abort"], as (name, the id of the member that
    wasn't applied, the trigger: the name of the variable whose change
    caused this (the first changed one that the definition reads; the
    relation itself, if it was assigned), the field's name ("" if the
    member itself is None), the None), for relation name + "Error"."""
    shape = state["relations"][name]
    nullable = state["nullable"].get(name, ())
    found = []
    for v in members:
        nones = []
        _r_nones(v, shape, "", nullable, nones)
        mid = getattr(v, "id", None)
        if _n_none(mid):
            mid = _r_rel_id(values, state, name)
        found += [(name, mid, state["trigger"], f, x) for f, x in nones]
    state["abort"] += found
    return len(found) > 0

def _r_with_id(values, name, v, relation):
    """v, assigned to name on standard input: if it is a struct with no
    field id, with one as a struct block would have: for a relation, the
    next free one (the largest + 1: a new member); for a lone variable
    whose value has an id, that id + 1. Else v."""
    if type(v) != "struct" or hasattr(v, "id"):
        return v
    if relation:
        id = _r_rel_id(values, {"tid": None}, name)
    elif hasattr(values[name], "id") and type(values[name].id) == "int":
        id = values[name].id + 1
    else:
        return v
    fields = {k: getattr(v, k) for k in dir(v)}
    fields["id"] = id
    return struct(**fields)

def _r_upsert(values, name, v):
    """Add member v to relation name, first removing the member with v's id
    if there is one; v becomes the current member."""
    if not hasattr(v, "id"):
        fail("a member of relation " + name + " must have a field id, got " + type(v))
    out = [m for m in values[name + "[]"] if m.id != v.id]
    out.append(v)
    values[name + "[]"] = out  # a new list: an update that fails restores the old one
    values[name] = v

def _r_when(values, state, name, cond, value):
    """An update of relation name defined with a condition (`a name when
    cond:`): every member for which cond() is true is replaced by value(),
    both reading that member as the self-reference (and value() giving it
    the member's id as its implicit id). If there is none, cond() is
    evaluated once more with the self-reference reading the identity (a
    new member), and if true, value() is added as a new member (its
    implicit id one more than the largest). The replaced and new members
    go at the end, in order. If any of them has a None field, none is
    applied (_r_reject): the relation stays as it was. Returns whether the
    relation changed."""
    kept = []
    new = []
    for m in values[name + "[]"]:
        state["wself"] = m
        state["tid"] = m.id
        if _r_truth(cond()):
            new.append(value())
        else:
            kept.append(m)
    if not new:
        state["wself"] = _identity
        state["tid"] = None
        if _r_truth(cond()):
            new.append(value())
    state["wself"] = None
    state["tid"] = None
    if not new:
        return False
    if _r_reject(values, state, name, new):
        return False
    for v in new:
        if not hasattr(v, "id"):
            fail("a member of relation " + name + " must have a field id, got " + type(v))
    values[name + "[]"] = kept + new  # a new list: an update that fails restores the old one
    values[name] = new[-1]
    return True

def _r_tid(values, state, name, deps, relation):
    """The id of the change that triggers evaluating name's definition,
    reading deps: that of the first dependency that changed (else the first
    one) and has one; for a lone variable (not relation), only relations
    count. A dependency's id here is its field name + "_id" if it has one
    (a reference to a member of name, e.g. deposit.account_id for account);
    else, for a relation name and another dependency that both have a
    field ending in "id" (_r_shared_key, e.g. customer_id), the id of
    name's last member with the dependency's value of it (None, so a new
    member, if there is none); else its field id. None if there is
    none."""
    changed = state["changed"]
    rels = state["relations"]
    key = name + "_id"
    for only_changed in (True, False):
        for d in deps:
            if (relation or d in rels) and (changed.get(d, False) or not only_changed):
                v = values[d]
                if hasattr(v, key):
                    return getattr(v, key)
                f = _r_shared_key(values, state, name, v) if relation and d != name else None
                if f != None:
                    found = None
                    for m in values[name + "[]"]:
                        if hasattr(m, f) and getattr(m, f) == getattr(v, f):
                            found = m.id
                    return found
                if hasattr(v, "id"):
                    return v.id
    return None

def _r_rel_id(values, state, name):
    """The implicit id of a relation's member: the triggering change's, or,
    without one, one more than the largest id in the relation (1 if it is
    empty), so a new member."""
    if state["tid"] != None:
        return state["tid"]
    top = 0
    for m in values[name + "[]"]:
        if type(m.id) == "int" and m.id > top:
            top = m.id
    return top + 1

def _r_lone_id(values, state, name):
    """The implicit id of a lone struct read from relations: the member's
    that triggered it (else as without relations: previous id + 1)."""
    if state["tid"] != None:
        return state["tid"]
    return _r_binop("+", _r_attr(_r_self(values, name), "id"), 1)

def _r_rel_self(values, state, name):
    """A relation's self-reference: the member this evaluation replaces (the
    one with the triggering change's id), or the identity if it adds one;
    with a condition (`a name when cond:`), the member _r_when is at."""
    if state["wself"] != None:
        return state["wself"]
    tid = state["tid"]
    if tid != None:
        for m in values[name + "[]"]:
            if hasattr(m, "id") and m.id == tid:
                return m
    return _identity

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
    return values[name] if name in values and not _is_unset(values[name]) else _identity

def _r_isnone(x):
    """Is x a None, with contagious None (which passes through the
    functions below as through any operation)? (By its type: comparing
    _identity with None fails during an update.)"""
    return type(x) == "NoneType" and _n_on()

def _r_binop(op, x, y):
    if _r_isnone(x):
        return x
    if _r_isnone(y):
        return y
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
    if _r_isnone(x):
        return x
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
    return _identity if _is_id(x) else x if _r_isnone(x) else _attr(x, name)

def _r_index(x, i):
    return _identity if _is_id(x) else x if _r_isnone(x) else i if _r_isnone(i) else x[i]

def _r_slice(x, lo, hi, step):
    return _identity if _is_id(x) else x if _r_isnone(x) else x[lo:hi:step]

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
_R_PUNCT2 = {"??": True, "//": True, "<<": True, ">>": True, "==": True, "!=": True, "<=": True, ">=": True}
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

def _r_derived(nodes, name):
    """The reactive variables that name's (active) definition reads, other
    than itself: none for one defined by a value that reads none (a source,
    which standard input updates)."""
    for n, _, deps, _ in nodes:
        if n == name:
            return [d for d in deps if d != name]
    return []

def _r_line(p, values, nodes, state):
    """The (name, value) pairs of a line, in order: each value a literal
    (_r_value), given to the name's constructor if it has one
    (_r_construct). Only a variable whose definition reads no other
    (_r_derived) gets a new value: one computed from others is never
    updated."""
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
            return _r_fail(p, "want a reactive variable name, then : and a value", t["pos"])
        if t["v"] not in values:
            return _r_fail(p, t["v"] + " is not a reactive variable", t["pos"])
        ds = _r_derived(nodes, t["v"])
        if ds:
            return _r_fail(p, t["v"] + " is computed from other reactive variables (" + ", ".join(ds) +
                              "): it can't be given a new value", t["pos"])
        if _r_is(p, "="):
            return _r_fail(p, "want : after " + t["v"] + " (a new value is given as " + t["v"] + " : value)", _r_tok(p)["pos"])
        if not _r_is(p, ":"):
            return _r_fail(p, "want : after " + t["v"], _r_tok(p)["pos"])
        _r_next(p)
        start = _r_tok(p)["pos"]
        v = _r_value(p)
        if p["err"] != None:
            return None
        ctor = state["ctors"].get(t["v"])
        if ctor != None:
            v = _r_construct(p, t["v"], ctor[0], ctor[1], v, start, True)
            if p["err"] != None:
                return None
        out.append((t["v"], v))
        if _r_tok(p)["k"] == "end":
            break
        if not _r_is(p, ";"):
            return _r_fail(p, "want ; or the end of the line after a value (a value is a literal: no expressions)", _r_tok(p)["pos"])
        _r_next(p)
    return out

def _r_ctor(state, name, shape, default):
    """Record the constructor of reactive variable name (its definition, a
    struct block reading no reactive variable): its fields' shape (_shape)
    and its value as written (the defaults); None, None: it has none (a
    redefinition, --globalreassign)."""
    if shape == None:
        state["ctors"].pop(name, None)
    else:
        state["ctors"][name] = (shape, default)

def _r_construct(p, what, shape, default, v, pos, top):
    """Value v (from standard input) given to the constructor of a struct
    block (shape: its fields, in order, see _shape; default: its value as
    written): a struct gives fields by name, a list gives them in order,
    anything else is the first field. The fields not given are the
    defaults; a field that is a nested block is constructed the same way
    from what is given for it. A struct may give fields the block doesn't
    have (e.g. a reference, order_id); the block's implicit id is never a
    default (_r_with_id gives one)."""
    names = [f for f, _ in shape]
    subs = {f: sub for f, sub in shape}
    fields = {f: getattr(default, f) for f in names if hasattr(default, f)}
    if type(v) == "struct":
        given = {k: getattr(v, k) for k in dir(v)}
    else:
        vs = v if type(v) == "list" else [v]
        if len(vs) > len(names):
            return _r_fail(p, what + " takes at most " + str(len(names)) + " value" + ("" if len(names) == 1 else "s") +
                              " (" + ", ".join(names) + "), got " + str(len(vs)), pos)
        given = {names[i]: x for i, x in enumerate(vs)}
    for k, x in given.items():
        sub = subs.get(k, ())
        if sub and type(fields.get(k)) == "struct" and type(x) in ("struct", "list", "int", "float", "string", "bool"):
            x = _r_construct(p, what + "." + k, sub, fields[k], x, pos, False)
            if p["err"] != None:
                return None
        fields[k] = x
    return struct(**fields)

# ---- values: p["toks"], p["t"] (index of the next token).

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

_R_KINDS = "a number, a string, True, False, None, a list [...] or struct(name = value, ...)"

def _r_value(p):
    """A value as standard input writes it: an int or float (with a sign),
    a string, True, False, None, a list of values, or struct(name = value,
    ...). Nothing else: no expressions, names, tuples, dicts or bytes."""
    t = _r_tok(p)
    if p["err"] != None:
        return None
    if t["k"] == "const":
        if type(t["v"]) == "bytes":
            return _r_fail(p, "bytes are not a value here: want " + _R_KINDS, t["pos"])
        _r_next(p)
        return t["v"]
    if t["k"] == "op" and t["v"] in ("-", "+"):
        _r_next(p)
        n = _r_tok(p)
        if n["k"] != "const" or type(n["v"]) not in ("int", "float"):
            return _r_fail(p, "want a number after " + t["v"], n["pos"])
        _r_next(p)
        return -n["v"] if t["v"] == "-" else n["v"]
    if t["k"] == "kw" and t["v"] in ("None", "True", "False"):
        _r_next(p)
        if t["v"] == "None":
            return _n_tag(None, "literal", "None", "<stdin>", p["lineno"])
        return t["v"] == "True"
    if t["k"] == "op" and t["v"] == "[" or t["k"] == "name" and t["v"] == "struct" and p["toks"][p["t"] + 1]["v"] == "(":
        if p["depth"] >= _R_MAX_DEPTH:
            return _r_fail(p, "value nested too deeply", t["pos"])
        p["depth"] += 1
        v = _r_list(p) if t["v"] == "[" else _r_struct(p)
        p["depth"] -= 1
        return v
    if t["k"] == "end":
        return _r_fail(p, "want a value here", t["pos"])
    return _r_fail(p, "want a value (" + _R_KINDS + "), got " + repr(t["v"]), t["pos"])

def _r_list(p):
    _r_next(p)  # [
    out = []
    for _ in range(len(p["toks"])):
        if _r_is(p, "]") or p["err"] != None:
            break
        if out:
            _r_expect(p, ",")
            if _r_is(p, "]") or p["err"] != None:
                break
        out.append(_r_value(p))
    _r_expect(p, "]")
    return out

def _r_struct(p):
    _r_next(p)  # struct
    _r_next(p)  # (
    fields = {}
    for _ in range(len(p["toks"])):
        if _r_is(p, ")") or p["err"] != None:
            break
        if fields:
            _r_expect(p, ",")
            if _r_is(p, ")") or p["err"] != None:
                break
        t = _r_next(p)
        if t["k"] != "name":
            return _r_fail(p, "want a field name (struct(name = value, ...))", t["pos"])
        if t["v"] in fields:
            return _r_fail(p, "field " + t["v"] + " given twice", t["pos"])
        _r_expect(p, "=")
        if p["err"] != None:
            return None
        fields[t["v"]] = _r_value(p)
    _r_expect(p, ")")
    if p["err"] != None:
        return None
    return struct(**fields)

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
