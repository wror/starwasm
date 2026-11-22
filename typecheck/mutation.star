# mutation.star — reactive definitions may not mutate what they didn't
# create (EXTENSIONS.md, "Reactive variables", "Mutation").
#
# A reactive definition is recomputed on every update, so it must be a
# function of what it reads: it may build and fill collections of its
# own, but not mutate a collection that existed before it ran (a global,
# a loaded module's value, another reactive variable's value, a default
# value of a parameter, a variable a closure captured), neither directly
# (`log.append(x)`) nor through any function it calls, transitively, nor
# by passing to a function a collection that the function mutates.
#
# The analysis is flow-insensitive and over-approximates: every
# expression has an abstract value, the sources of the objects it may be
# (V["t"]) and of the objects inside them, at any depth (V["e"]). A
# source is
#   "f:<frame>"           a collection made in that frame's run (fresh)
#   "p:<frame>:<param>"   what a function's caller passed it
#   "d:<frame>:<param>"   a parameter's default value (made once, kept)
#   "g:<name>"            a global, loaded or reactive variable's value
#   "?"                   unknown (an unknown function's result)
# A frame is a def, a lambda, a reactive definition, or the module's top
# level. Each def and lambda gets a summary: which of its parameters it
# mutates, whether it mutates anything else ("nonlocal"), which captured
# objects of its enclosing functions it mutates, and what it returns (in
# terms of its parameters). Summaries are solved by iterating to a fixed
# point over the whole module; loaded modules' summaries are used as they
# are. Function values: referring to a function that mutates anything
# other than its own fresh objects, other than to call it (passing it,
# storing it, returning it), counts as mutating what it mutates, as it
# may be called with anything; and a top-level variable that holds such a
# function (`bump = make_counter()`) is one too.

load("../compiler/resolve.star", "target_names")
load("types.star", "resolve")

SCALARS = {"int": True, "float": True, "str": True, "bool": True, "bytes": True, "None": True}

# the methods of list, dict and set that mutate their receiver
MUTATORS = {
    "append": True,
    "clear": True,
    "extend": True,
    "insert": True,
    "pop": True,
    "remove": True,
    "popitem": True,
    "setdefault": True,
    "update": True,
    "add": True,
    "discard": True,
}

# builtin methods that return (part of) their receiver's contents
ELEMENT_METHODS = {"get": True, "pop": True, "setdefault": True, "popitem": True}

# builtin methods (prelude.star's tables), whose results are fresh
BUILTIN_METHODS = {m: True for m in [
    "capitalize", "codepoint_ords", "codepoints", "count", "elem_ords", "elems", "endswith",
    "find", "format", "index", "isalnum", "isalpha", "isdigit", "islower", "isspace", "istitle",
    "isupper", "join", "lower", "lstrip", "partition", "removeprefix", "removesuffix",
    "replace", "rfind", "rindex", "rpartition", "rsplit", "rstrip", "split", "splitlines",
    "startswith", "strip", "title", "upper", "items", "keys", "values", "difference",
    "intersection", "issubset", "issuperset", "symmetric_difference", "union", "get",
]}

# builtins whose result may be one of their arguments' elements
ELEMENT_BUILTINS = {"min": True, "max": True, "getattr": True, "next": True}

def _v(t = None, e = None):
    return {"t": t or {}, "e": e or {}}

EMPTY = _v()

def _join(a, b):
    t = dict(a["t"])
    t.update(b["t"])
    e = dict(a["e"])
    e.update(b["e"])
    return {"t": t, "e": e}

def _all(v):
    """Every source in v, at any depth."""
    s = dict(v["t"])
    s.update(v["e"])
    return s

def _deep(v):
    """A value that is (or holds) any of v's objects."""
    s = _all(v)
    return {"t": s, "e": s}

def _grow(cx, into, more):
    """into |= more (dicts as sets), counting a change."""
    for k in more:
        if k not in into:
            into[k] = True
            cx["changes"] += 1

def _grow_v(cx, into, v):
    _grow(cx, into["t"], v["t"])
    _grow(cx, into["e"], v["e"])

# ---------------------------------------------------------------- frames

def _frame(cx, kind, name, node, parent, params):
    fid = cx["path"] + "@" + str(node["pos"][0]) + ":" + str(node["pos"][1]) + ":" + kind
    anc = {}
    if parent != None:
        anc = dict(parent["anc"])
        anc[parent["id"]] = True
    pnames = {}
    for p in params:
        if p["name"] != None:
            pnames[p["name"]] = p
    fr = {
        "id": fid,
        "kind": kind,  # "def", "lambda", "reactive", "module"
        "name": name,
        "node": node,
        "parent": parent,
        "anc": anc,
        "params": params,
        "pnames": pnames,
        "locals": {},  # name -> True (bound in the body)
        "defs": {},  # nested def name -> frame
        "env": {},  # local name -> V
        "ret": _v(),
        # the summary: param name -> witness, and witnesses (or None)
        "mut_params": {},
        "nonlocal": None,
        "escape": None,  # (a witness of a mutating function value let out)
        "captured": {},  # source -> witness: enclosing frames' objects it mutates
        "path": cx["path"],
    }
    cx["frames"].append(fr)
    cx["by_id"][fid] = fr
    cx["changes"] += 1
    return fr

def _show(fr):
    if fr["kind"] == "def":
        return fr["name"] + "()"
    if fr["kind"] == "lambda":
        return "a lambda"
    return fr["name"]

def _collect(cx, fr, stmts):
    """Bindings and nested functions of frame fr's body (not descending
    into nested defs, whose bodies are frames of their own)."""
    for s in stmts:
        k = s["kind"]
        if k == "assign":
            names = []
            target_names(s["lhs"], names)
            for n in names:
                if n not in fr["pnames"]:
                    fr["locals"][n] = True
        elif k == "for":
            names = []
            target_names(s["target"], names)
            for n in names:
                if n not in fr["pnames"]:
                    fr["locals"][n] = True
            _collect(cx, fr, s["body"])
        elif k == "def":
            fr["locals"][s["name"]] = True
            sub = _frame(cx, "def", s["name"], s, fr, s["params"])
            fr["defs"][s["name"]] = sub
            _collect(cx, sub, s["body"])
        elif k == "if":
            _collect(cx, fr, s["body"])
            _collect(cx, fr, s["else_"] or [])
        elif k == "while":
            _collect(cx, fr, s["body"])

def _lambda_frame(cx, fr, e):
    fid = cx["path"] + "@" + str(e["pos"][0]) + ":" + str(e["pos"][1]) + ":lambda"
    lf = cx["by_id"].get(fid)
    if lf == None:
        lf = _frame(cx, "lambda", "lambda", e, fr, e["params"])
    return lf

# ---------------------------------------------------------------- witnesses

def _set(cx, fr, key, w):
    """fr[key] = w, the first time. (The module frame's are reset for
    each top-level statement: no change to count.)"""
    if fr[key] == None:
        fr[key] = w
        if fr["kind"] != "module":
            cx["changes"] += 1

def _text(e):
    k = e["kind"]
    if k == "name":
        return e["id"]
    if k == "dot":
        return _text(e["x"]) + "." + e["name"]
    if k == "index":
        return _text(e["x"]) + "[...]"
    if k == "call":
        return _text(e["fn"]) + "(...)"
    return "(...)"

def _scalar(cx, name):
    """Does global `name` hold a number, string, bool or None (which
    can't be mutated), as the types inferred say?"""
    scope = cx["scope"]
    if scope == None:
        return False
    b = scope["vars"].get(name)
    for _ in range(10):
        if b == None or b.get("kind") != "alias":
            break
        b = b["to"]
    if b == None or b.get("kind") != "var":
        return False
    t = resolve(b["type"])
    if t["k"] == "con" and t["name"] == "opt":
        t = resolve(t["args"][0])
    if t["k"] == "var":
        return t.get("num", False)
    return t["k"] == "con" and t["name"] in SCALARS

def _w(fr, pos, text, nxt = None):
    return {"file": fr["path"], "pos": pos, "text": text, "next": nxt}

def _describe(cx, src):
    if src == "?":
        return "a value from an unknown source"
    if src.startswith("g:"):
        name = src[2:]
        if name in cx["reactive"]:
            return "the value of reactive variable '" + name + "'"
        return "global variable '" + name + "'"
    if src.startswith("d:"):
        fid, _, p = src[2:].rpartition(":")
        f = cx["by_id"].get(fid)
        return "the default value of parameter '" + p + "'" + (" of " + _show(f) if f != None else "")
    if src.startswith("p:"):
        return "parameter '" + src.rpartition(":")[2] + "'"
    f = cx["by_id"].get(src[2:])
    if f != None and f["kind"] == "def":
        return "a collection that " + _show(f) + " made, and a function it made keeps"
    return "a collection"

def _origin(fid, src):
    """The frame a "f:" or "p:" source belongs to (else None)."""
    if src.startswith("f:"):
        return src[2:]
    if src.startswith("p:"):
        return src[2:].rpartition(":")[0]
    return None

def _record(cx, fr, src, w):
    """Frame fr mutates (an object from) source src: witness w."""
    o = _origin(fr["id"], src)
    if o == fr["id"]:
        if src.startswith("p:"):
            p = src.rpartition(":")[2]
            if p not in fr["mut_params"]:
                fr["mut_params"][p] = w
                cx["changes"] += 1
        return  # (a fresh object of its own)
    if o != None and o in fr["anc"]:
        # an enclosing function's object, captured: its mutation, and ours
        # if we are let out
        if src not in fr["captured"]:
            fr["captured"][src] = w
            cx["changes"] += 1
        if src.startswith("p:"):
            g = cx["by_id"][o]
            p = src.rpartition(":")[2]
            if p not in g["mut_params"]:
                g["mut_params"][p] = w
                cx["changes"] += 1
        return
    if o != None:
        return  # (another frame's fresh object: can't be reached here)
    if src.startswith("g:") and _scalar(cx, src[2:]):
        return
    _set(cx, fr, "nonlocal", w)

def _mutates(cx, fr, v, pos, what):
    """fr mutates the objects of v (the receiver of `what`)."""
    for src in v["t"]:
        _record(cx, fr, src, _w(fr, pos, what + " mutates " + _describe(cx, src)))

def _effects(f):
    """A witness of anything function frame f mutates other than its own
    fresh objects, or None."""
    if f["nonlocal"] != None:
        return f["nonlocal"]
    for p in f["params"]:
        if p["name"] != None and p["name"] in f["mut_params"]:
            return f["mut_params"][p["name"]]
    for src in f["captured"]:
        return f["captured"][src]
    return None

def _function_value(cx, fr, f, pos, what):
    """Function f is referred to other than in a call: it may be called
    with anything, from anywhere."""
    w = _effects(f)
    if w == None:
        return
    w = _w(fr, pos, what + ", which mutates what it is given or keeps, is used as a value here", w)
    _set(cx, fr, "nonlocal", w)
    _set(cx, fr, "escape", w)

# ---------------------------------------------------------------- names

def _resolve(cx, fr, name):
    """("param", frame) | ("local", frame) | ("def", frame) | ("module", None)."""
    f = fr
    for _ in range(100):
        if f == None or f["kind"] == "reactive" or f["kind"] == "module":
            return ("module", None)
        if name in f["pnames"]:
            return ("param", f)
        if name in f["defs"]:
            return ("def", f["defs"][name])
        if name in f["locals"]:
            return ("local", f)
        f = f["parent"]
    return ("module", None)

def _param_v(f, name):
    src = {"p:" + f["id"] + ":" + name: True}
    if f["pnames"][name]["default"] != None:
        src["d:" + f["id"] + ":" + name] = True
    return {"t": src, "e": src}

def _module_function(cx, name):
    """The frame of a top-level or loaded function `name`, or None."""
    f = cx["defs"].get(name)
    if f != None:
        return f
    ld = cx["loaded"].get(name)
    if ld != None:
        m = cx["st"]["modules"].get(ld[0])
        if m != None and m.get("mutation") != None:
            return m["mutation"]["defs"].get(ld[1])
    return None

def _tainted(cx, name):
    w = cx["tainted"].get(name)
    if w != None:
        return w
    ld = cx["loaded"].get(name)
    if ld != None:
        m = cx["st"]["modules"].get(ld[0])
        if m != None and m.get("mutation") != None:
            return m["mutation"]["tainted"].get(ld[1])
    return None

def _name(cx, fr, e, cenv):
    name = e["id"]
    if name in cenv:
        return cenv[name]
    kind, f = _resolve(cx, fr, name)
    if kind == "param":
        return _param_v(f, name)
    if kind == "local":
        return f["env"].get(name, EMPTY)
    if kind == "def":
        _function_value(cx, fr, f, e["pos"], name + "()")
        return EMPTY
    mf = _module_function(cx, name)
    if mf != None:
        _function_value(cx, fr, mf, e["pos"], name + "()")
        return EMPTY
    w = _tainted(cx, name)
    if w != None:
        _uses_tainted(cx, fr, name, e["pos"], w)
    if name in cx["globals"] or name in cx["loaded"]:
        src = {"g:" + name: True}
        return {"t": src, "e": src}
    return EMPTY  # a builtin

def _uses_tainted(cx, fr, name, pos, w):
    w = _w(fr, pos, "'" + name + "' holds a function that mutates what it is given or keeps", w)
    _set(cx, fr, "nonlocal", w)
    _set(cx, fr, "escape", w)

def _root(e):
    """The name node at the root of x[i].f... (or None)."""
    for _ in range(1000):
        if e["kind"] in ("index", "dot", "slice"):
            e = e["x"]
        else:
            break
    return e if e["kind"] == "name" else None

def _store(cx, fr, target, v, cenv):
    """v is stored into the object that `target` (x[i], x.f, x.m(v)'s
    receiver x) is in: the objects of its root local now hold v's."""
    r = _root(target)
    if r == None or r["id"] in cenv:
        return
    kind, f = _resolve(cx, fr, r["id"])
    if kind == "local":
        cur = f["env"].get(r["id"])
        if cur == None:
            cur = _v()
            f["env"][r["id"]] = cur
        _grow(cx, cur["e"], _all(v))

def _bind(cx, fr, target, v, cenv):
    k = target["kind"]
    if k == "name":
        if target["id"] in cenv:
            return
        kind, f = _resolve(cx, fr, target["id"])
        if kind == "local":
            cur = f["env"].get(target["id"])
            if cur == None:
                cur = _v()
                f["env"][target["id"]] = cur
            _grow_v(cx, cur, v)
    elif k == "tuple" or k == "list":
        for x in target["elems"]:
            _bind(cx, fr, x, {"t": v["e"], "e": v["e"]}, cenv)
    elif k == "index" or k == "dot":
        rv = _expr(cx, fr, target["x"], cenv)
        if k == "index":
            _expr(cx, fr, target["i"], cenv)
        _mutates(cx, fr, rv, target["pos"], "assigning to " + _text(target))
        _store(cx, fr, target, v, cenv)

# ---------------------------------------------------------------- expressions

def _fresh(fr):
    return {"f:" + fr["id"]: True}

def _expr(cx, fr, e, cenv):
    """The abstract value of e, recording what it mutates."""
    if e == None:
        return EMPTY
    k = e["kind"]
    if k == "name":
        return _name(cx, fr, e, cenv)
    if k in ("int", "float", "string", "bytes"):
        return EMPTY
    if k == "list" or k == "tuple":
        inner = {}
        for x in e["elems"]:
            inner.update(_all(_expr(cx, fr, x, cenv)))
        return {"t": _fresh(fr), "e": inner}
    if k == "dict":
        inner = {}
        for key, val in e["entries"]:
            inner.update(_all(_expr(cx, fr, key, cenv)))
            inner.update(_all(_expr(cx, fr, val, cenv)))
        return {"t": _fresh(fr), "e": inner}
    if k == "comp":
        env = dict(cenv)
        for c in e["clauses"]:
            if c["kind"] == "for":
                it = _expr(cx, fr, c["iter"], env)
                names = []
                target_names(c["target"], names)
                for n in names:
                    env[n] = {"t": it["e"], "e": it["e"]}
            else:
                _expr(cx, fr, c["test"], env)
        inner = {}
        for x in (e["body"] if e["comp"] == "dict" else [e["body"]]):
            inner.update(_all(_expr(cx, fr, x, env)))
        return {"t": _fresh(fr), "e": inner}
    if k == "binop":
        a = _expr(cx, fr, e["x"], cenv)
        b = _expr(cx, fr, e["y"], cenv)
        if e["op"] in ("and", "or", "??"):
            return _join(a, b)
        inner = dict(a["e"])
        inner.update(b["e"])
        return {"t": _fresh(fr), "e": inner}
    if k == "unop":
        _expr(cx, fr, e["x"], cenv)
        return EMPTY
    if k == "cond":
        _expr(cx, fr, e["test"], cenv)
        return _join(_expr(cx, fr, e["then"], cenv), _expr(cx, fr, e["else_"], cenv))
    if k == "index":
        x = _expr(cx, fr, e["x"], cenv)
        _expr(cx, fr, e["i"], cenv)
        return {"t": x["e"], "e": x["e"]}
    if k == "slice":
        x = _expr(cx, fr, e["x"], cenv)
        for part in ["lo", "hi", "step"]:
            _expr(cx, fr, e[part], cenv)
        return {"t": _fresh(fr), "e": x["e"]}
    if k == "dot":
        x = _expr(cx, fr, e["x"], cenv)
        if e["name"] in MUTATORS:
            # a bound method, as a value: whoever calls it mutates x
            _mutates(cx, fr, x, e["pos"], _text(e["x"]) + "." + e["name"])
            return EMPTY
        return {"t": x["e"], "e": x["e"]}
    if k == "lambda":
        for p in e["params"]:
            _expr(cx, fr, p["default"], cenv)
        lf = _lambda_frame(cx, fr, e)
        _function_value(cx, fr, lf, e["pos"], "a lambda")
        return EMPTY
    if k == "call":
        return _call(cx, fr, e, cenv)
    return EMPTY

def _args(cx, fr, e, cenv):
    return [(a, _expr(cx, fr, a["value"], cenv)) for a in e["args"]]

def _call(cx, fr, e, cenv):
    fn = e["fn"]
    if fn["kind"] == "dot":
        x = _expr(cx, fr, fn["x"], cenv)
        args = _args(cx, fr, e, cenv)
        m = fn["name"]
        if m in MUTATORS:
            _mutates(cx, fr, x, fn["pos"], _text(fn["x"]) + "." + m + "()")
            for a, v in args:
                if m in ("extend", "update"):
                    _store(cx, fr, fn["x"], {"t": v["e"], "e": v["e"]}, cenv)
                else:
                    _store(cx, fr, fn["x"], v, cenv)
        if m in ELEMENT_METHODS:
            r = {"t": x["e"], "e": x["e"]}
            for a, v in args:
                r = _join(r, v)
            return r
        if m in BUILTIN_METHODS or m in MUTATORS:
            return {"t": _fresh(fr), "e": x["e"]}
        return {"t": {"?": True}, "e": {"?": True}}  # (a function in a field)
    if fn["kind"] == "name" and fn["id"] not in cenv:
        name = fn["id"]
        kind, f = _resolve(cx, fr, name)
        callee = None
        if kind == "def":
            callee = f
        elif kind == "module":
            callee = _module_function(cx, name)
            if callee == None:
                w = _tainted(cx, name)
                if w != None:
                    _uses_tainted(cx, fr, name, fn["pos"], w)
                args = _args(cx, fr, e, cenv)
                if name in cx["globals"] or name in cx["loaded"] or w != None:
                    return {"t": {"?": True}, "e": {"?": True}}
                # a builtin: a fresh result (or an argument's element)
                inner = {}
                for a, v in args:
                    inner.update(_all(v))
                if name in ELEMENT_BUILTINS:
                    return {"t": inner, "e": inner}
                return {"t": _fresh(fr), "e": inner}
        if callee != None:
            return _call_function(cx, fr, e, callee, _args(cx, fr, e, cenv))
    _expr(cx, fr, fn, cenv)
    _args(cx, fr, e, cenv)
    return {"t": {"?": True}, "e": {"?": True}}  # (an unknown function: see _function_value)

def _bindings(callee, args):
    """param name -> V of what the call passes it."""
    out = {}
    plain = [p for p in callee["params"] if p["name"] != None and p["star"] == ""]
    star = [p for p in callee["params"] if p["name"] != None and p["star"] != ""]
    if star or [a for a, v in args if a["star"] != ""]:
        # (*args, **kwargs: anything may go anywhere)
        every = EMPTY
        for a, v in args:
            every = _join(every, v)
        for p in callee["params"]:
            if p["name"] != None:
                out[p["name"]] = every
        return out
    i = 0
    for a, v in args:
        if a["name"] == None:
            if i < len(plain):
                out[plain[i]["name"]] = v
            i += 1
        else:
            out[a["name"]] = v
    return out

def _call_function(cx, fr, e, callee, args):
    pos = e["fn"]["pos"]
    show = _show(callee)
    passed = _bindings(callee, args)
    for p, w in callee["mut_params"].items():
        v = passed.get(p)
        if v == None:
            continue
        for src in _all(v):
            _record(cx, fr, src, _w(fr, pos, show + " is called with " + _describe(cx, src) +
                                             " as its parameter '" + p + "', which it mutates", w))
    if callee["nonlocal"] != None:
        _set(cx, fr, "nonlocal", _w(fr, pos, show + " is called here", callee["nonlocal"]))
        if callee["escape"] != None:
            _set(cx, fr, "escape", _w(fr, pos, show + " is called here", callee["escape"]))
    for src, w in callee["captured"].items():
        _record(cx, fr, src, _w(fr, pos, show + " is called here", w))
    # its result, in terms of what it was passed
    out = {"t": {}, "e": {}}
    for lvl in ["t", "e"]:
        for src in callee["ret"][lvl]:
            if src.startswith("p:" + callee["id"] + ":"):
                v = passed.get(src.rpartition(":")[2])
                if v != None:
                    out[lvl].update(v["t"] if lvl == "t" else _all(v))
                    if lvl == "t":
                        out["e"].update(v["e"])
            elif src == "f:" + callee["id"]:
                out[lvl].update(_fresh(fr))
            else:
                out[lvl][src] = True
    return out

# ---------------------------------------------------------------- statements

def _stmts(cx, fr, stmts):
    for s in stmts:
        k = s["kind"]
        if k == "assign":
            v = _expr(cx, fr, s["rhs"], {})
            if s["op"] == "=":
                _bind(cx, fr, s["lhs"], v, {})
            else:
                # x op= y: in place, for a list (x += y is x.extend(y))
                t = _expr(cx, fr, s["lhs"], {})
                _mutates(cx, fr, t, s["lhs"]["pos"], _text(s["lhs"]) + " " + s["op"])
                if s["lhs"]["kind"] in ("index", "dot"):
                    _bind(cx, fr, s["lhs"], v, {})
                else:
                    _store(cx, fr, s["lhs"], {"t": v["e"], "e": v["e"]}, {})
        elif k == "expr":
            _expr(cx, fr, s["x"], {})
        elif k == "return":
            if s["value"] != None:
                _grow_v(cx, fr["ret"], _expr(cx, fr, s["value"], {}))
        elif k == "for":
            it = _expr(cx, fr, s["iter"], {})
            _bind(cx, fr, s["target"], {"t": it["e"], "e": it["e"]}, {})
            _stmts(cx, fr, s["body"])
        elif k == "if":
            _expr(cx, fr, s["test"], {})
            _stmts(cx, fr, s["body"])
            _stmts(cx, fr, s["else_"] or [])
        elif k == "while":
            _expr(cx, fr, s["test"], {})
            _stmts(cx, fr, s["body"])
        elif k == "def":
            for p in s["params"]:
                _expr(cx, fr, p["default"], {})

def _run(cx, f):
    if f["kind"] == "def":
        _stmts(cx, f, f["node"]["body"])
    elif f["kind"] == "lambda":
        _grow_v(cx, f["ret"], _expr(cx, f, f["node"]["body"], {}))

# ---------------------------------------------------------------- modules

def analyze_module(st, path, stmts, loaded, scope):
    """The summaries of module `path`'s functions, and the errors of its
    reactive definitions: (record, [(file, pos, message, notes)]).
    loaded: local name -> (module path, name); scope: the module's
    inferred bindings (for which globals hold scalars)."""
    cx = {
        "scope": scope,
        "st": st,
        "path": path,
        "frames": [],
        "by_id": {},
        "changes": 0,
        "defs": {},
        "loaded": loaded,
        "globals": {},
        "reactive": {},
        "tainted": {},
    }
    module = _frame(cx, "module", "the top level", {"pos": (0, 0)}, None, [])
    cx["module"] = module
    reactive = []
    top = []
    for s in stmts:
        k = s["kind"]
        if k == "def":
            f = _frame(cx, "def", s["name"], s, None, s["params"])
            cx["defs"][s["name"]] = f
            _collect(cx, f, s["body"])
        elif k == "reactive":
            cx["reactive"][s["name"]] = True
            cx["globals"][s["name"]] = True
            reactive.append(s)
        elif k == "load":
            pass
        else:
            names = []
            if k == "assign":
                target_names(s["lhs"], names)
            elif k == "for":
                target_names(s["target"], names)
            for n in names:
                cx["globals"][n] = True
            top.append(s)
    for s in reactive:
        rf = _frame(cx, "reactive", "reactive variable '" + s["name"] + "'", s, None, [])
        s["_frame"] = rf["id"]

    # every frame's summary, to a fixed point (lambdas are found, and get
    # frames, on the way)
    for _ in range(1000):
        cx["changes"] = 0
        for f in list(cx["frames"]):
            _run(cx, f)
        for s in reactive:
            rf = cx["by_id"][s["_frame"]]
            _expr(cx, rf, s["value"], {})
            if s.get("when") != None:
                _expr(cx, rf, s["when"], {})
        # top-level variables that end up holding a mutating function
        for s in top:
            module["escape"] = None
            _stmts(cx, module, [s])
            if module["escape"] != None:
                names = []
                if s["kind"] == "assign":
                    t = s["lhs"]
                    r = _root(t) if t["kind"] in ("index", "dot") else None
                    target_names(t, names)
                    if r != None:
                        names.append(r["id"])
                elif s["kind"] == "for":
                    target_names(s["target"], names)
                for n in names:
                    if n not in cx["tainted"]:
                        cx["tainted"][n] = module["escape"]
                        cx["changes"] += 1
        if cx["changes"] == 0:
            break

    errors = []
    for s in reactive:
        rf = cx["by_id"][s["_frame"]]
        if rf["nonlocal"] != None:
            errors.append(_error(cx, s["name"], rf["nonlocal"]))
    rec = {"defs": cx["defs"], "tainted": cx["tainted"]}
    return rec, errors

def _error(cx, name, w):
    """(file, pos, message, notes) from a witness chain."""
    notes = []
    n = w["next"]
    for _ in range(100):
        if n == None:
            break
        notes.append({"file": n["file"], "pos": n["pos"], "msg": n["text"]})
        n = n["next"]
    msg = ("reactive variable '" + name + "' may mutate a collection that existed before it was " +
           "computed: " + w["text"])
    return (w["file"], w["pos"], msg, notes)
