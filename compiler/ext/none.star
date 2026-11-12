# ext/none.star — contagious None, with provenance (EXTENSIONS.md).
#
#   x = None
#   x + 1, x.foo, x[0], x > 2, x == x, abs(x), x.upper()    # all None
#   x == None, x != None                                    # True, False
#   provenance(x)      # [("literal", "None", "prog.star", 1), ...]
#
# On by default in programs with reactive variables (ext/reactive.star),
# else off; the compiler options --contagiousnone and --nocontagiousnone
# say otherwise (mc["contagious_none"]: True, False, or None for the
# default).
#
# Two things, both only in the user's modules (the prelude is compiled as
# ever, so builtins written in Starlark keep their meaning):
#
# 1. Contagion. Every operation gets a test of its operands in front: if
#    one is None, the result is that None, and the operation doesn't
#    happen. The hooks expr, cond, assign and stmt (extensions.star) do it:
#    they evaluate the operands into Wasm locals, test them, and hand the
#    node back to codegen with the operands replaced by "%code" nodes
#    reading the locals, marked "%core" so that the hooks pass it. So the
#    operation itself, its errors and their positions are codegen's.
#
# 2. Provenance. A None is a $NoneType struct {via, prev} (lib/runtime.star):
#    `via` is an entry (kind, id, file, line), a tuple, and `prev` the None
#    it was before. transform marks the places a None passes through
#    ("%via": a function's return values and a reactive definition's value;
#    "%site": a return without a value), and the expr hook wraps them in
#    rt_none_via(value, entry), which, if the value is None, gives a new
#    None with one more entry (unless it has that entry already: a None
#    going round a loop doesn't grow). Entries are created once per place,
#    in a global, on first use (_lazy).
#
# Marks on AST nodes (set by transform, read by the hooks):
#   "%via": (kind, id, line)   wrap the value: it passes through this
#   "%site": (kind, id, line)  (on a None name) the None that starts here
#   "%iter": True              a loop's iterable: None iterates as ()
#   "%discard": True           a call whose result is dropped
#   "%core": True              already guarded: the hooks pass

load(
    "../../lib/dsl.star",
    "and_",
    "arr_fixed",
    "arr_get",
    "arr_len",
    "arr_new",
    "as_",
    "call",
    "eqz",
    "field",
    "for_i32",
    "get",
    "gget",
    "gset",
    "i32",
    "if_",
    "is_",
    "is_null",
    "new",
    "non_null",
    "null",
    "op",
    "or_",
    "ret",
    "set",
    "while_",
)
load("../../lib/builtins.star", "METHODS")
load("../../lib/runtime.star", "S", "vi")
load("../../lib/wasm.star", "EQREF", "I32", "add_func", "add_global", "ref")
load("../parser.star", "parse_file")

V = EQREF
NONE = gget("None")
NONET = ref("NoneType", True)

# Primitives for RUNTIME below and for ext/reactive.star's (EXT_INTRINSICS
# in compiler/extensions.star):
#   _none_via(v, entry)       v; if it is None, with entry added to its trace
#   _none_trace(v)            the entries of v's trace, newest first ([] if
#                             v is not None)
#   _none_skip(f, pos, kw)    calling f(*pos, **kw) is an operation on None
#                             (f is a builtin and an argument it doesn't
#                             just store is None): that None; else False
INTRINSICS = {
    "_none_via": ("rt_none_via", 2, 2),
    "_none_trace": ("rt_none_trace", 1, 1),
    "_none_skip": ("rt_none_skip_v", 3, 3),
}

# Builtin functions and methods that take None for what it is, by name:
# the positional arguments (bit i: argument i, not counting a method's
# receiver) and keyword arguments (KW) that they only store, print or give
# back, so a None there is no operation on None. Anything else that is
# None makes the call's result None, uncalled.
KW = 1 << 20
ALL = KW | 0xffff
TOLERANT = {
    "print": ALL,
    "fail": ALL,  # asked for: it ends the program whatever its arguments
    "struct": ALL,
    "provenance": ALL,
    "getattr": 1 << 2,  # the default
    "dict": KW,
    "update": KW,
    "append": 1 << 0,
    "add": 1 << 0,
    "insert": 1 << 1,
    "get": 1 << 1,  # the default
    "setdefault": 1 << 1,
    "pop": 1 << 1,
}

# The prelude functions ext/reactive.star turns operations into in a
# self-referencing definition (its _in_context): the arguments that are
# the operation's operands.
REACTIVE_OPS = {
    "_r_binop": [1, 2],
    "_r_unop": [1],
    "_r_not": [0],
    "_r_attr": [0],
    "_r_index": [0, 1],
    "_r_slice": [0, 1, 2, 3],
    "_r_conv": [1],
}

EQUALITY = {"==": True, "!=": True}
COMPARE = {"==": True, "!=": True, "<": True, ">": True, "<=": True, ">=": True, "in": True, "not in": True}

def _active(mc):
    return mc["ext"].get("none", False) and not mc["mod"].get("prelude", False)

def _present(mc):
    """Is the runtime needed: the extension is on, or the program has
    reactive variables, whose runtime calls it (to no effect when off)."""
    return mc["ext"].get("none", False) or mc["ext"].get("reactive", False)

# ---------------------------------------------------------------- transform

def transform(cg, mc):
    """Decide whether the extension is on, and if so mark the user's
    modules (see the top of the file)."""
    on = mc.get("contagious_none")
    if on == None:
        on = mc["ext"].get("reactive", False)
    mc["ext"]["none"] = on
    mc["ext"]["none_lazy"] = {}
    if on:
        for mod in mc["mods"]:
            _mark_stmts(mod["stmts"], None)

def _site(kind, name, posn):
    return {"kind": "name", "id": "None", "pos": posn, "%site": (kind, name, posn[0])}

def _mark_stmts(stmts, fname):
    """fname: the function whose body stmts is in (its return values get
    its entry), or None."""
    for s in stmts:
        k = s["kind"]
        if k == "def":
            _mark(s["params"], None)
            if s["name"].startswith("%"):
                # generated (a reactive definition's function): its value
                # is marked as the variable's, not as a function's
                _mark_stmts(s["body"], None)
                continue
            _mark_stmts(s["body"], s["name"])
            if not s["body"] or s["body"][-1]["kind"] != "return":
                s["body"].append({"kind": "return", "pos": s["pos"], "value": _site("function", s["name"], s["pos"])})
        elif k == "return":
            if fname == None:
                _mark(s["value"], None)
            elif s["value"] == None:
                s["value"] = _site("function", fname, s["pos"])
            else:
                _mark(s["value"], None)
                _via(s["value"], ("function", fname, s["pos"][0]))
        elif k == "if":
            _mark(s["test"], None)
            _mark_stmts(s["body"], fname)
            _mark_stmts(s["else_"], fname)
        elif k == "while":
            _mark(s["test"], None)
            _mark_stmts(s["body"], fname)
        elif k == "for":
            _mark(s["target"], None)
            _mark(s["iter"], None)
            _mark_iter(s["iter"])
            _mark_stmts(s["body"], fname)
        elif k == "expr":
            _mark(s["x"], None)
            if s["x"]["kind"] == "call":
                s["x"]["%discard"] = True
        elif k == "assign":
            if s["lhs"]["kind"] == "name" and s["lhs"]["id"].startswith("%"):
                continue  # generated (the reactive runtime's state)
            _mark(s["lhs"], None)
            _mark(s["rhs"], None)
        elif k == "reactive":
            _mark(s["value"], None)  # (not reached: reactive.star rewrites them)

def _via(e, entry):
    """Mark e: its value passes through entry. (Innermost first, if it
    already passes through another.)"""
    e["%via"] = e.get("%via", ()) + (entry,)

def _mark_iter(e):
    """A loop's iterable: None iterates as (). A range of int literals
    can't be None, and stays codegen's counted loop."""
    if e["kind"] == "call" and e["fn"]["kind"] == "name" and e["fn"]["id"] == "range":
        lit = True
        for a in e["args"]:
            v = a["value"]
            if v["kind"] == "unop" and v["op"] == "-":
                v = v["x"]
            if v["kind"] != "int" or a["name"] != None or a["star"] != "":
                lit = False
        if lit:
            return
    e["%iter"] = True
    e["hooked"] = True  # codegen: no shortcut past the expr hook

def _mark(x, _):
    """Mark the expressions in x (an expression, or lists and tuples of
    them): lambdas' bodies, comprehensions' iterables, and the values
    reactive.star says are a reactive variable's ("defines")."""
    t = type(x)
    if t == "list" or t == "tuple":
        for y in x:
            _mark(y, None)
        return
    if t != "dict":
        return
    k = x.get("kind")
    for key in x:
        if key != "scope" and key != "pos" and not key.startswith("%"):
            _mark(x[key], None)
    if k == "lambda":
        _via(x["body"], ("function", "lambda", x["pos"][0]))
    elif k == "comp":
        for c in x["clauses"]:
            if c["kind"] == "for":
                _mark_iter(c["iter"])
    d = x.get("defines")
    if d != None:
        _via(x, ("reactive", d[0], d[1]))

# ---------------------------------------------------------------- code pieces

def _is_none(t):
    return is_("NoneType", get(t))

def _lazy(mc, key, init):
    """Code for a value created once, by init, the first time it is needed."""
    m = mc["m"]
    st = mc["ext"]["none_lazy"]
    fn = st.get(key)
    if fn == None:
        g = "none_g" + str(len(st))
        fn = "none_c" + str(len(st))
        add_global(m, g, V, True, [null("eq")])
        add_func(m, fn, [], [V], [if_(is_null(gget(g)), gset(g, init)), gget(g)])
        st[key] = fn
    return call(fn)

def _entry(mc, entry):
    """Code for the tuple (kind, id, file, line) of entry (kind, id, line),
    a place in the module being compiled."""
    m = mc["m"]
    kind, name, line = entry
    key = "e:" + kind + ":" + name + ":" + mc["file"] + ":" + str(line)
    return _lazy(mc, key, new("Tuple", arr_fixed("Vals", S(m, kind), S(m, name), S(m, mc["file"]), vi(line))))

def _origin(mc, entry):
    """Code for the None that starts at entry."""
    kind, name, line = entry
    key = "n:" + kind + ":" + name + ":" + mc["file"] + ":" + str(line)
    return _lazy(mc, key, call("rt_none_via", NONE, _entry(mc, entry)))

def _code(t, e):
    """The node standing for e once it is evaluated into local t."""
    return {"kind": "%code", "code": get(t), "pos": e["pos"], "orig": e}

def _core(e, **changes):
    """A copy of e for codegen itself, with some children replaced."""
    e2 = dict(e)
    e2.update(changes)
    e2["%core"] = True
    for k in ["%via", "%iter", "%discard", "hooked"]:
        if k in e2:
            e2.pop(k)
    return e2

def _first_none(temps, otherwise):
    """The first of the locals temps that is None, else `otherwise`."""
    code = otherwise
    for t in reversed(temps):
        code = if_(_is_none(t), get(t), code, result = V)
    return code

def _any_none(temps):
    code = _is_none(temps[0])
    for t in temps[1:]:
        code = or_(code, _is_none(t))
    return code

def _literal_none(cg, mc, fc, e):
    return e["kind"] == "name" and e["id"] == "None" and cg["lookup"](mc, fc, "None", e["pos"])[0] == "const"

def _guard(cg, mc, fc, e, keys):
    """e, a node whose operands are e[key] for key in keys (those that
    are there), as a value: the first operand that is None, else the
    operation."""
    setup = []
    temps = []
    changes = {}
    for key in keys:
        if e[key] == None:
            continue
        t = cg["temp"](fc, V)
        setup.append(set(t, cg["gen"](mc, fc, e[key])))
        temps.append(t)
        changes[key] = _code(t, e[key])
    return [setup, _first_none(temps, cg["gen"](mc, fc, _core(e, **changes)))]

def _plain(cg, mc, fc, e, sides):
    """An == or != with None written out: the comparison as ever (the None
    is the plain one: it is no origin)."""
    changes = {}
    for key in sides:
        if _literal_none(cg, mc, fc, e[key]):
            changes[key] = _core(e[key])
    return _core(e, **changes)

# ---------------------------------------------------------------- hooks

def expr(cg, mc, fc, e):
    if not _active(mc) or e.get("%core", False):
        return None
    k = e["kind"]
    if k == "%code":
        return None
    if e.get("%site") != None:
        return _origin(mc, e["%site"])
    vias = e.get("%via")
    if vias:
        e2 = dict(e)
        e2.pop("%via")
        code = cg["gen"](mc, fc, e2)
        for entry in vias:
            code = call("rt_none_via", code, _entry(mc, entry))
        return code
    if e.get("%iter", False):
        e2 = dict(e)
        e2.pop("%iter")
        t = cg["temp"](fc, V)
        return [set(t, cg["gen"](mc, fc, e2)), if_(_is_none(t), new("Tuple", arr_fixed("Vals")), get(t), result = V)]
    if k == "name":
        if e.get("gen", False) or not _literal_none(cg, mc, fc, e):
            return None
        return _origin(mc, ("literal", "None", e["pos"][0]))
    if k == "binop":
        op_ = e["op"]
        if op_ == "and" or op_ == "or":
            return None  # they choose an operand; None is false
        if EQUALITY.get(op_, False) and (_literal_none(cg, mc, fc, e["x"]) or _literal_none(cg, mc, fc, e["y"])):
            return cg["gen"](mc, fc, _plain(cg, mc, fc, e, ["x", "y"]))
        return _guard(cg, mc, fc, e, ["x", "y"])
    if k == "unop":
        return _guard(cg, mc, fc, e, ["x"])
    if k == "dot":
        return _guard(cg, mc, fc, e, ["x"])
    if k == "index":
        if e.get("gen", False):
            return None  # generated (%reactive["x"])
        return _guard(cg, mc, fc, e, ["x", "i"])
    if k == "slice":
        return _guard(cg, mc, fc, e, ["x", "lo", "hi", "step"])
    if k == "call":
        return _call(cg, mc, fc, e)
    return None

def cond(cg, mc, fc, e):
    """e as an i32 truth value: an operation on None is None, so false."""
    if not _active(mc) or e.get("%core", False):
        return None
    k = e["kind"]
    if k == "binop" and COMPARE.get(e["op"], False):
        if EQUALITY.get(e["op"], False) and (_literal_none(cg, mc, fc, e["x"]) or _literal_none(cg, mc, fc, e["y"])):
            return cg["gen_cond"](mc, fc, _plain(cg, mc, fc, e, ["x", "y"]))
        tx = cg["temp"](fc, V)
        ty = cg["temp"](fc, V)
        e2 = _core(e, x = _code(tx, e["x"]), y = _code(ty, e["y"]))
        return [
            set(tx, cg["gen"](mc, fc, e["x"])),
            set(ty, cg["gen"](mc, fc, e["y"])),
            if_(or_(_is_none(tx), _is_none(ty)), i32(0), cg["gen_cond"](mc, fc, e2), result = I32),
        ]
    if k == "unop" and e["op"] == "not":
        t = cg["temp"](fc, V)
        return [set(t, cg["gen"](mc, fc, e["x"])), if_(_is_none(t), i32(0), eqz(call("rt_truth", get(t))), result = I32)]
    return None

def assign(cg, mc, fc, t, value, posn):
    """x[i] = v and x.name = v do nothing if x is None (or i is, unless x
    is a dict: None is a key like any other); unpacking None gives every
    target that None."""
    if not _active(mc) or t.get("%core", False):
        return None
    k = t["kind"]
    if k == "index" and not t.get("gen", False):
        tv = cg["temp"](fc, V)
        tx = cg["temp"](fc, V)
        ti = cg["temp"](fc, V)
        t2 = _core(t, x = _code(tx, t["x"]), i = _code(ti, t["i"]))
        return [
            set(tv, value),
            set(tx, cg["gen"](mc, fc, t["x"])),
            set(ti, cg["gen"](mc, fc, t["i"])),
            if_(or_(_is_none(tx), and_(_is_none(ti), eqz(is_("Dict", get(tx))))), [], cg["gen_assign"](mc, fc, t2, get(tv), posn)),
        ]
    if k == "dot":
        tv = cg["temp"](fc, V)
        tx = cg["temp"](fc, V)
        t2 = _core(t, x = _code(tx, t["x"]))
        return [
            set(tv, value),
            set(tx, cg["gen"](mc, fc, t["x"])),
            if_(_is_none(tx), [], cg["gen_assign"](mc, fc, t2, get(tv), posn)),
        ]
    if k == "tuple" or k == "list":
        return cg["gen_assign"](mc, fc, _core(t), call("rt_none_spread", value, i32(len(t["elems"]))), posn)
    return None

def stmt(cg, mc, fc, s):
    """x op= y: None if x or y is (and then x[i] op= y, x.name op= y store
    as assign has it)."""
    if not _active(mc) or s["kind"] != "assign" or s["op"] == "=":
        return None
    t = s["lhs"]
    k = t["kind"]
    setup = []
    if k == "name":
        target = t
        cur = cg["gen"](mc, fc, _core(t))
    elif k == "index":
        tx = cg["temp"](fc, V)
        ti = cg["temp"](fc, V)
        setup = [set(tx, cg["gen"](mc, fc, t["x"])), set(ti, cg["gen"](mc, fc, t["i"]))]
        target = dict(t)
        target.update({"x": _code(tx, t["x"]), "i": _code(ti, t["i"])})
        cur = cg["gen"](mc, fc, dict(target))
    elif k == "dot":
        tx = cg["temp"](fc, V)
        setup = [set(tx, cg["gen"](mc, fc, t["x"]))]
        target = dict(t)
        target["x"] = _code(tx, t["x"])
        cur = cg["gen"](mc, fc, dict(target))
    else:
        return None  # codegen reports it
    a = cg["temp"](fc, V)
    b = cg["temp"](fc, V)
    value = [
        set(a, cur),
        set(b, cg["gen"](mc, fc, s["rhs"])),
        _first_none([a, b], cg["callat"](mc, s["oppos"], cg["aug_fn"](s["op"]), get(a), get(b))),
    ]
    return [setup, cg["gen_assign"](mc, fc, target, value, s["oppos"])]

# ---------------------------------------------------------------- calls

def _tolerant(name, a, i):
    """Is argument a (the i-th positional one, if it is positional) of
    builtin `name` one it only stores?"""
    mask = TOLERANT.get(name, 0)
    if a["star"] != "":
        return False
    if a["name"] != None:
        return mask & KW != 0
    return i < 16 and mask & (1 << i) != 0

def _args(cg, mc, fc, e):
    """Evaluate e's arguments into locals. Returns (code, the call's
    arguments reading them, [(argument, local)])."""
    setup = []
    args2 = []
    pairs = []
    for a in e["args"]:
        t = cg["temp"](fc, V)
        setup.append(set(t, cg["gen"](mc, fc, a["value"])))
        a2 = dict(a)
        a2["value"] = _code(t, a["value"])
        args2.append(a2)
        pairs.append((a, t))
    return setup, args2, pairs

def _builtin_guards(name, pairs):
    """The locals whose being None makes a call of builtin `name` None."""
    out = []
    i = 0
    for a, t in pairs:
        if not _tolerant(name, a, i):
            out.append(t)
        if a["name"] == None and a["star"] == "":
            i += 1
    return out

def _result(mc, e, name, code):
    """The result of a call of builtin `name`: if it is None, it passed
    through here."""
    if e.get("%discard", False) or name == "provenance":
        return code
    return call("rt_none_via", code, _entry(mc, ("builtin", name, e["lparen"][0])))

def _dynamic(cg, mc, fc, e, f, args2, pairs):
    """A call through the value in local f (not None), its arguments
    evaluated (_args): None if a *args or **kwargs is, or if f turns out
    to be a builtin and an argument it doesn't just store is None
    (rt_none_skip); else the call."""
    fn = {"kind": "%code", "code": get(f), "pos": e["fn"]["pos"]}
    code = cg["gen"](mc, fc, _core(e, fn = fn, args = [dict(a) for a in args2]))
    stars = [t for a, t in pairs if a["star"] != ""]
    pos = [get(t) for a, t in pairs if a["star"] == "" and a["name"] == None]
    named = [get(t) for a, t in pairs if a["star"] == "" and a["name"] != None]
    if pos or named:
        r = cg["temp"](fc, V)
        skip = call("rt_none_skip", get(f), arr_fixed("Vals", *pos), arr_fixed("Vals", *named))
        code = [set(r, skip), if_(is_null(get(r)), code, get(r), result = V)]
    if stars:
        code = _first_none(stars, code)
    return code

def _call(cg, mc, fc, e):
    fn = e["fn"]
    if fn["kind"] == "dot":
        return _method_call(cg, mc, fc, e)
    builtin = None
    if fn["kind"] == "name":
        name = fn["id"]
        if name.startswith("%prelude."):
            return _reactive_op(cg, mc, fc, e, name[len("%prelude."):])
        kind, w = cg["lookup"](mc, fc, name, fn["pos"])
        if kind == "protomod":
            return None
        if kind == "builtin":
            builtin = name
        elif kind == "func":
            if mc["allfuncs"][w].get("prelude", False):
                builtin = name
            else:
                # a def: None is an argument like any other (but not *None)
                if len([a for a in e["args"] if a["star"] != ""]) == 0:
                    return None
                setup, args2, pairs = _args(cg, mc, fc, e)
                return [setup, _first_none([t for a, t in pairs if a["star"] != ""], cg["gen"](mc, fc, _core(e, args = args2)))]
    if builtin != None:
        setup, args2, pairs = _args(cg, mc, fc, e)
        code = _result(mc, e, builtin, cg["gen"](mc, fc, _core(e, args = args2)))
        return [setup, _first_none(_builtin_guards(builtin, pairs), code)]

    # through a value
    f = cg["temp"](fc, V)
    setup, args2, pairs = _args(cg, mc, fc, e)
    return [set(f, cg["gen"](mc, fc, fn)), setup, if_(_is_none(f), get(f), _dynamic(cg, mc, fc, e, f, args2, pairs), result = V)]

def _method_call(cg, mc, fc, e):
    """x.name(args): None if x is. If name is a method of a builtin type,
    None if an argument it doesn't just store is None; but x may be a
    struct (or a library object) whose field `name` is being called, and
    so, as when name is no method at all, a call through a value."""
    fn = e["fn"]
    x = fn["x"]
    name = fn["name"]
    if x["kind"] == "name":
        if x["id"].startswith("%"):
            return None  # generated (%nodes.append(...))
        if cg["lookup"](mc, fc, x["id"], x["pos"])[0] == "protomod":
            return None
    recv = cg["temp"](fc, V)
    setup, args2, pairs = _args(cg, mc, fc, e)
    fn2 = dict(fn)
    fn2["x"] = _code(recv, x)
    known = METHODS.get(name) != None or mc["prelude"]["funcs"].get("_m_" + name) != None

    def through_value():
        f = cg["temp"](fc, V)
        return [set(f, cg["gen"](mc, fc, _core(fn2))), if_(_is_none(f), get(f), _dynamic(cg, mc, fc, e, f, args2, pairs), result = V)]

    if not known:
        code = through_value()
    else:
        code = _result(mc, e, name, cg["gen"](mc, fc, _core(e, fn = fn2, args = [dict(a) for a in args2])))
        guards = _builtin_guards(name, pairs)
        if guards:
            code = _first_none(guards, code)
        holder = None  # i32: x holds its own fields
        if mc["has_struct"]:
            holder = is_("Struct", get(recv))
        if mc["has_obj"]:
            holder = is_("Obj", get(recv)) if holder == None else or_(holder, is_("Obj", get(recv)))
        if holder != None:
            code = if_(holder, through_value(), code, result = V)
    return [set(recv, cg["gen"](mc, fc, x)), setup, if_(_is_none(recv), get(recv), code, result = V)]

def _reactive_op(cg, mc, fc, e, name):
    """A call of a prelude function generated by another extension: only
    those that stand for an operation (REACTIVE_OPS) are guarded."""
    idxs = REACTIVE_OPS.get(name)
    if idxs == None:
        return None
    args = e["args"]
    if name == "_r_binop" and EQUALITY.get(args[0]["value"].get("val"), False) and \
       (_literal_none(cg, mc, fc, args[1]["value"]) or _literal_none(cg, mc, fc, args[2]["value"])):
        idxs = []
    setup = []
    temps = []
    args2 = []
    for i, a in enumerate(args):
        v = a["value"]
        a2 = dict(a)
        if _literal_none(cg, mc, fc, v):
            a2["value"] = _core(v)  # written out, or a missing slice bound
        else:
            t = cg["temp"](fc, V)
            setup.append(set(t, cg["gen"](mc, fc, v)))
            a2["value"] = _code(t, v)
            if i in idxs:
                temps.append(t)
        args2.append(a2)
    return [setup, _first_none(temps, cg["gen"](mc, fc, _core(e, args = args2)))]

# ---------------------------------------------------------------- runtime

def runtime(mc, m):
    if not _present(mc):
        return
    v = get("v")

    # v, having passed through entry (a tuple) if it is None: a new None
    # whose trace is v's and then entry, unless entry is in it already.
    add_func(m, "rt_none_via", [("v", V), ("entry", V)], [V], locals = [("p", NONET)], body = [
        if_(eqz(is_("NoneType", v)), ret(v)),
        set("p", as_("NoneType", v)),
        while_(eqz(is_null(get("p"))), [
            if_(eqz(is_null(field("NoneType", "via", non_null(get("p"))))),
                if_(call("rt_eq", field("NoneType", "via", non_null(get("p"))), get("entry")), ret(v))),
            set("p", field("NoneType", "prev", non_null(get("p")))),
        ]),
        new("NoneType", get("entry"), as_("NoneType", v)),
    ])

    # the entries of v's trace, newest first
    add_func(m, "rt_none_trace", [("v", V)], [V], locals = [("p", NONET), ("out", ref("List", True))], body = [
        set("out", call("rt_list_new", i32(4))),
        if_(is_("NoneType", v), [
            set("p", as_("NoneType", v)),
            while_(eqz(is_null(get("p"))), [
                if_(eqz(is_null(field("NoneType", "via", non_null(get("p"))))),
                    call("rt_list_append", non_null(get("out")), field("NoneType", "via", non_null(get("p"))))),
                set("p", field("NoneType", "prev", non_null(get("p")))),
            ]),
        ]),
        get("out"),
    ])

    # for unpacking v into n targets: if it is None, n of it
    add_func(m, "rt_none_spread", [("v", V), ("n", I32)], [V], [
        if_(is_("NoneType", v), ret(new("Tuple", arr_new("Vals", v, get("n"))))),
        v,
    ])

    # Is f(*pos, **named) an operation on None: f a builtin function or a
    # bound method, and an argument it doesn't just store (TOLERANT) None?
    # That None; else null.
    masks = []
    for name in sorted(TOLERANT):
        masks.append(if_(call("rt_str_eq", non_null(get("name")), as_("Str", S(m, name))), set("mask", i32(TOLERANT[name]))))
    add_func(m, "rt_none_skip", [("f", V), ("pos", ref("Vals")), ("named", ref("Vals"))], [V], locals = [
        ("name", ref("Str", True)),
        ("mask", I32),
        ("i", I32),
    ], body = [
        if_(is_("Bound", get("f")), set("name", field("Bound", "name", as_("Bound", get("f")))),
            if_(is_("Func", get("f")),
                if_(field("Sig", "kind", field("Func", "sig", as_("Func", get("f")))),
                    set("name", field("Sig", "name", field("Func", "sig", as_("Func", get("f")))))))),
        if_(is_null(get("name")), ret(null("eq"))),
        masks,
        for_i32("i", i32(0), arr_len(get("pos")), [
            if_(is_("NoneType", arr_get("Vals", get("pos"), get("i"))),
                if_(or_(op("i32.ge_u", get("i"), i32(16)), eqz(op("i32.and", op("i32.shr_u", get("mask"), get("i")), i32(1)))),
                    ret(arr_get("Vals", get("pos"), get("i"))))),
        ]),
        if_(eqz(op("i32.and", get("mask"), i32(KW))),
            for_i32("i", i32(0), arr_len(get("named")), [
                if_(is_("NoneType", arr_get("Vals", get("named"), get("i"))), ret(arr_get("Vals", get("named"), get("i")))),
            ])),
        null("eq"),
    ])

    # _none_skip(f, pos, kw) for the prelude: pos a list, kw a dict; False
    # for "call it"
    add_func(m, "rt_none_skip_v", [("f", V), ("pos", V), ("kw", V)], [V], locals = [("r", V)], body = [
        set("r", call(
            "rt_none_skip",
            get("f"),
            field("Tuple", "items", call("rt_iter", get("pos"))),
            field("Tuple", "items", call("rt_iter", call("rt_m_values", get("kw")))),
        )),
        if_(is_null(get("r")), ret(gget("False"))),
        get("r"),
    ])

def prelude(mc):
    if not _present(mc):
        return [], []
    on = mc["ext"].get("none", False)
    src = RUNTIME + (RUNTIME_ON if on else RUNTIME_OFF)
    return parse_file(src, "compiler/ext/none.star"), []

# Added to the prelude. _n_iter... are called by generated code; the
# reactive runtime (ext/reactive.star) calls _n_tag, _n_none, _n_skip and
# _n_changed, which do nothing when the extension is off (RUNTIME_OFF).
RUNTIME = r'''
def _n_tag(v, kind, name, file, line):
    """v, having passed through (kind, name, file, line) if it is None."""
    return _none_via(v, (kind, name, file, line))
'''

RUNTIME_ON = r'''
def provenance(x):
    """Where a None comes from: what it passed through, oldest first, as
    tuples (kind, id, file, line); [] for any other value."""
    return _none_trace(x)[::-1]

def _n_none(x):
    return x == None

def _n_skip(f, pos, kw):
    return _none_skip(f, pos, kw)

def _n_changed(old, new):
    """Two Nones that came different ways are different values."""
    return old == None and new == None and _none_trace(old) != _none_trace(new)
'''

RUNTIME_OFF = r'''
def _n_none(x):
    return False

def _n_skip(f, pos, kw):
    return False

def _n_changed(old, new):
    return False
'''
