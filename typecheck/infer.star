# infer.star — type inference over a program's AST (compiler/parser.star).
#
# Hindley-Milner with let-polymorphism for defs: every expression gets a
# type with unification variables for what is not known yet
# (typecheck/unify.star solves them), and a def's type is generalized over
# the variables that are its own, so each use of the def gets a fresh copy.
#
# Scopes. A scope is {vars: name -> binding, order, parent, level, mod}.
# The names a module or function body binds are declared before its
# statements are inferred (as Starlark resolves them), with the types
# annotated in the .start file where there are any. Bindings:
#   var       {type, pos}
#   def       {node, state, type, declared, complete, scope, ann, locals, ...}
#   relation  {type}: a reactive relation (EXTENSIONS.md): its member type
# Variables are not flow-sensitive: a name has one type in its scope. The
# exception is None: where a test shows that an optional variable is not
# None (`if x != None:`, `if x:`, `x and ...`), it has its non-None type
# (fc["narrow"]).
#
# Defs are inferred on demand: when first referred to, or at the end of
# the scope that defines them. A def referred to while it is being
# inferred (recursion) has its not yet generalized type there; defs that
# refer to each other in a cycle are generalized together, when the first
# of them is done (st["stack"], st["group"]: Tarjan's algorithm, on demand).
# A def whose annotation gives every parameter and the result a type has
# that type wherever it is used, and its body is checked against it, with
# the annotation's type parameters rigid.
#
# A function context fc is {scope, ret, narrow, mod, def, reactive, observer}.

load("../compiler/parser.star", "parse_file")
load("../compiler/spell.star", "nearest")
load(
    "stubs.star",
    "child_scope",
    "declare_tparams",
    "parse_stubs",
    "split_decls",
    "tail_check",
    "to_params",
    "to_type",
    new_conv = "new_scope",
)
load(
    "types.star",
    "GENERIC",
    "T_ANY",
    "con",
    "field",
    "flatten",
    "fn",
    "is_con",
    "lab",
    "lit",
    "mk_opt",
    "new_var",
    "param",
    "rec",
    "resolve",
    "resolve_label",
    "row",
    "show",
)
load(
    "unify.star",
    "add_pred",
    "attr_type",
    "binop_pred",
    "default_pending",
    "flow",
    "flow_report",
    "generalize",
    "head",
    "instantiate",
    "join",
    "note_at",
    "pattern",
    "pred",
    "report",
    "unify",
    "unify_report",
)

MISSING = "?"  # the name of the placeholder type of an unannotated parameter

def _missing():
    return con(MISSING)

def new_scope(parent, level, mod):
    return {"vars": {}, "order": [], "parent": parent, "level": level, "mod": mod}

def _declare(scope, name, b):
    b["name"] = name
    if name not in scope["vars"]:
        scope["order"].append(name)
    scope["vars"][name] = b

def _ctx(fc, pos, role = None):
    return {"file": fc["mod"]["path"], "pos": pos, "role": role}

def _fresh(st, fc):
    return new_var(st, "type", fc["scope"]["level"])

# ---------------------------------------------------------------- paths

def path_join(from_file, rel):
    """Path of module `rel`, loaded from file `from_file` (as the
    compiler's path_join)."""
    absolute = rel.startswith("/") or from_file.startswith("/")
    parts = rel.split("/") if rel.startswith("/") else from_file.split("/")[:-1] + rel.split("/")
    out = []
    for p in parts:
        if p == "" or p == ".":
            continue
        if p == "..":
            if out and out[-1] != "..":
                out.pop()
            elif not absolute:
                out.append("..")
            continue
        out.append(p)
    joined = "/".join(out)
    return "/" + joined if absolute else joined

def start_path(path):
    """foo.star -> foo.start"""
    return path + "t"

# ---------------------------------------------------------------- modules

def check_module(st, path, from_ctx = None):
    """Infer module `path` (once). Returns its record {path, scope, state}."""
    mod = st["modules"].get(path)
    if mod != None:
        if mod["state"] == "busy" and from_ctx != None:
            report(st, from_ctx, "cycle in load graph: " + path)
        return mod
    src = st["read"](path)
    st["sources"][path] = src
    stmts = parse_file(src, path)
    mod = {"path": path, "state": "busy", "scope": None}
    st["modules"][path] = mod
    scope = new_scope(st["builtins"], 0, mod)
    mod["scope"] = scope

    # the programmer's annotations
    spath = start_path(path)
    decls = []
    if st["has_start"](spath):
        text = st["read"](spath)
        st["sources"][spath] = text
        decls = parse_stubs(text, spath)
    cv = new_conv(st, spath, {}, 0)
    ann_vars, ann_defs, aliases = split_decls(cv, decls, "")
    cv["aliases"] = aliases
    for name, a in aliases.items():
        # check each alias once, with its parameters standing for Any
        inner = child_scope(cv)
        for tp in a["tparams"]:
            inner["tvars"][tp["name"]] = {"kind": "type", "val": T_ANY}
        inner["expanding"] = {name: True}
        to_type(inner, a["type"])

    fc = {"scope": scope, "ret": None, "narrow": {}, "mod": mod, "def": None}
    declare_scope(st, fc, stmts, cv, ann_vars, ann_defs, "")
    infer_block(st, fc, stmts)
    finish_scope(st, scope)
    default_pending(st, -1)
    mod["state"] = "done"
    return mod

# ---------------------------------------------------------------- declaring

def _targets(e, out):
    """The names bound by assignment target e."""
    k = e["kind"]
    if k == "name":
        out.append(e)
    elif k == "tuple" or k == "list":
        for x in e["elems"]:
            _targets(x, out)

def _is_none(e):
    return e != None and e["kind"] == "name" and e["id"] == "None"

def collect_bound(stmts, bound, order):
    """The names the statements bind in their scope (not those of nested
    defs): name -> {pos, none (assigned the literal None somewhere), defs,
    assigned, load, reactive}."""
    for s in stmts:
        k = s["kind"]
        if k == "def":
            _bound(bound, order, s["name"], s["namepos"])["defs"].append(s)
        elif k == "assign":
            names = []
            _targets(s["lhs"], names)
            for n in names:
                info = _bound(bound, order, n["id"], n["pos"])
                info["assigned"] = True
                if s["op"] == "=" and s["lhs"]["kind"] == "name" and _is_none(s["rhs"]):
                    info["none"] = True
        elif k == "for":
            names = []
            _targets(s["target"], names)
            for n in names:
                _bound(bound, order, n["id"], n["pos"])["assigned"] = True
            collect_bound(s["body"], bound, order)
        elif k == "if":
            collect_bound(s["body"], bound, order)
            collect_bound(s["else_"], bound, order)
        elif k == "while":
            collect_bound(s["body"], bound, order)
        elif k == "load":
            for i, (local, orig) in enumerate(s["names"]):
                info = _bound(bound, order, local, s["localpos"][i])
                info["load"] = (s, orig, s["namepos"][i])
        elif k == "reactive":
            _bound(bound, order, s["name"], s["pos"])["reactive"] = s

def _bound(bound, order, name, pos):
    info = bound.get(name)
    if info == None:
        info = {"pos": pos, "none": False, "defs": [], "assigned": False, "load": None, "reactive": None}
        bound[name] = info
        order.append(name)
    return info

def declare_scope(st, fc, stmts, cv, ann_vars, ann_defs, where):
    """Declare in fc's scope the names that stmts bind. cv: how the types
    of the annotations (ann_vars, ann_defs: name -> declaration) convert;
    where: "" or the name of the def whose body this is."""
    scope = fc["scope"]
    mod = fc["mod"]
    bound = {}
    order = []
    collect_bound(stmts, bound, order)
    for name in order:
        info = bound[name]
        pos = info["pos"]
        if info["load"] != None:
            s, orig, opos = info["load"]
            ctx = _ctx(fc, s["pos"])
            m = check_module(st, path_join(mod["path"], s["module"]), ctx)
            b = m["scope"]["vars"].get(orig) if m["scope"] != None else None
            if b == None or b.get("loaded", False):
                if m["state"] != "busy":
                    names = [n for n, x in m["scope"]["vars"].items() if not x.get("loaded", False)]
                    h = nearest(orig, names)
                    report(st, _ctx(fc, opos), "module " + s["module"] + " has no '" + orig + "'" + (" (did you mean '" + h + "'?)" if h else ""))
                b = {"kind": "var", "type": T_ANY, "pos": pos}
            # the loaded module's own binding (a def is inferred on demand)
            scope["vars"][name] = {"kind": "alias", "to": b, "loaded": True, "name": name}
            scope["order"].append(name)
            continue
        if name in scope["vars"]:
            continue  # a parameter, assigned in the body
        if info["reactive"] != None and info["reactive"].get("relation", False):
            _declare(scope, name, {"kind": "relation", "type": _fresh(st, fc), "pos": pos})
            continue
        if len(info["defs"]) == 1 and not info["assigned"] and info["reactive"] == None:
            b = {
                "kind": "def",
                "node": info["defs"][0],
                "state": "todo",
                "type": None,
                "declared": None,
                "complete": False,
                "scope": scope,
                "ann": None,
                "cv": cv,
                "locals": None,
                "pos": pos,
            }
            _declare(scope, name, b)
            d = ann_defs.get(name)
            if d != None:
                _declare_def_annotation(st, fc, b, d, cv)
            elif name in ann_vars:
                report(st, {"file": cv["file"], "pos": ann_vars[name]["pos"], "role": None},
                       "'" + name + "' is a function in " + mod["path"] + ": declare it as `def " + name + "(...) -> type`")
            continue
        d = ann_vars.get(name)
        if d != None:
            t = to_type(cv, d["type"])
        else:
            t = _fresh(st, fc)
            if info["none"]:
                t = mk_opt(t)
            if name in ann_defs:
                report(st, {"file": cv["file"], "pos": ann_defs[name]["pos"], "role": None},
                       "'" + name + "' is not (only) a function in " + mod["path"] + ": declare it as `" + name + ": type`")
        _declare(scope, name, {"kind": "var", "type": t, "pos": pos, "declared": d != None})
    for kind, anns in [("variable", ann_vars), ("function", ann_defs)]:
        for name, d in anns.items():
            if name in bound:
                continue
            ctx = {"file": cv["file"], "pos": d["pos"], "role": None}
            if name in scope["vars"]:
                report(st, ctx, "'" + name + "' is a parameter of " + where + ": its type goes in the def line, `def " + where + "(" + name + ": type, ...)`")
                continue
            h = nearest(name, order)
            report(st, ctx, mod["path"] + " has no " + kind + " '" + name + "'" + (" in " + where if where else "") +
                            (" (did you mean '" + h + "'?)" if h else ""))

def _node_params(node):
    """The def's parameters as (name, star, has default, keyword-only)."""
    out = []
    kw = False
    for p in node["params"]:
        if p["star"] == "*" and p["name"] == None:
            kw = True
            continue
        out.append((p["name"], p["star"], p["default"] != None, kw and p["star"] == "", p))
        if p["star"] == "*":
            kw = True
    return out

def _sig_text(params):
    return "(" + ", ".join([star + name for name, star in params]) + ")"

def _declare_def_annotation(st, fc, b, d, cv):
    """Attach the annotation d to def binding b: b["declared"] is its
    type as a scheme, with a placeholder type where d gives none."""
    node = b["node"]
    have = [(p[0], p[1]) for p in _node_params(node)]
    want = [(q["name"], q["star"]) for q in d["params"]]
    actx = {"file": cv["file"], "pos": d["pos"], "role": None}
    if have != want:
        report(st, actx, "'" + d["name"] + "' is declared with parameters " + _sig_text(want) + ", but defined with " + _sig_text(have),
               [note_at(_ctx(fc, node["namepos"]), "'" + d["name"] + "' is defined here")])
        return
    inner = child_scope(cv)
    inner["level"] = GENERIC
    tvars = declare_tparams(inner, d["tparams"], GENERIC)
    params = to_params(inner, d["params"], _missing())
    np = _node_params(node)
    for i, p in enumerate(params):
        p["opt"] = np[i][2]
        p["kw"] = np[i][3]
    ret = to_type(inner, d["ret"]) if d["ret"] != None else _missing()
    t = fn(params, ret, {"file": cv["file"], "pos": d["pos"], "role": "declared here"})
    tail_check(inner, d["tparams"], tvars, t)
    b["declared"] = t
    b["tvars"] = tvars
    b["ann"] = d
    b["cv"] = inner
    b["complete"] = d["ret"] != None and len([q for q in d["params"] if q["type"] == None]) == 0

def finish_scope(st, scope):
    """Infer the defs of the scope that nothing has referred to yet."""
    for name in scope["order"]:
        b = scope["vars"][name]
        if b["kind"] == "def" and b["state"] == "todo":
            infer_def(st, b)

# ---------------------------------------------------------------- defs

def _returns(stmts, out):
    """out["value"]: some `return <expr>` (not the literal None);
    out["none"]: some `return` or `return None`."""
    for s in stmts:
        k = s["kind"]
        if k == "return":
            if s["value"] == None or _is_none(s["value"]):
                out["none"] = True
            else:
                out["value"] = True
        elif k == "if":
            _returns(s["body"], out)
            _returns(s["else_"], out)
        elif k == "for" or k == "while":
            _returns(s["body"], out)

def _is_fail(s):
    return s["kind"] == "expr" and s["x"]["kind"] == "call" and s["x"]["fn"]["kind"] == "name" and s["x"]["fn"]["id"] == "fail"

def terminates(stmts):
    """Does control never reach the end of the block?"""
    for s in stmts:
        k = s["kind"]
        if k == "return" or _is_fail(s):
            return True
        if k == "if" and s["else_"] and terminates(s["body"]) and terminates(s["else_"]):
            return True
    return False

def _exits(stmts):
    """As terminates, counting break and continue: control never reaches
    the statement after the block."""
    for s in stmts:
        k = s["kind"]
        if k == "return" or k == "break" or k == "continue" or _is_fail(s):
            return True
        if k == "if" and s["else_"] and _exits(s["body"]) and _exits(s["else_"]):
            return True
    return False

def _fill_missing(st, t, level):
    """t (an instantiated annotation) with fresh variables for the
    placeholders of its unannotated parameters and result."""
    ps = []
    for p in t["params"]:
        ty = p["type"]
        if is_con(resolve(ty), MISSING):
            ty = new_var(st, "type", level)
        ps.append(param(p["name"], ty, p["opt"], p["star"], p["kw"]))
    ret = t["ret"]
    if is_con(resolve(ret), MISSING):
        ret = None
    return ps, ret

def infer_def(st, b):
    """Infer the type of def binding b from its body (checking it against
    its annotation, if any), and generalize it."""
    node = b["node"]
    outer = b["scope"]
    mod = outer["mod"]
    level = outer["level"] + 1
    name = node["name"]
    outer_fc = {"scope": outer, "ret": None, "narrow": {}, "mod": mod, "def": None}
    scope = new_scope(outer, level, mod)
    fc = {"scope": scope, "ret": None, "narrow": {}, "mod": mod, "def": b}
    at = _ctx(outer_fc, node["namepos"], "definition of " + name)

    # the signature
    nps = _node_params(node)
    ret = None
    cv = b["cv"]
    if b["declared"] != None:
        memo = {}
        sig = instantiate(st, b["declared"], level, memo)
        for v in memo.values():
            v["rigid"] = True
        params, ret = _fill_missing(st, sig, level)
        cv = child_scope(b["cv"])
        cv["level"] = level
        for tname, tv in b["cv"]["tvars"].items():
            v = tv["val"]
            if v["k"] == "var" and v["id"] in memo:
                cv["tvars"][tname] = {"kind": tv["kind"], "val": memo[v["id"]]}
    else:
        params = [param(p[0], new_var(st, "type", level), p[2], p[1], p[3]) for p in nps]
    for i, p in enumerate(params):
        pnode = nps[i][4]
        if pnode["default"] != None:
            dt = infer_expr(st, outer_fc, pnode["default"])
            if _is_none(pnode["default"]) and b["declared"] == None:
                p["type"] = mk_opt(p["type"])
            else:
                flow_report(st, dt, p["type"], _ctx(outer_fc, pnode["default"]["pos"], "default value of parameter '" + p["name"] + "'"))
        local = p["type"]
        if p["star"] == "*":
            local = con("vtuple", [p["type"]])
        elif p["star"] == "**":
            local = con("dict", [con("str"), p["type"]])
        _declare(scope, p["name"], {"kind": "var", "type": local, "pos": pnode.get("namepos") or pnode["pos"], "param": True})
    rs = {"value": False, "none": False}
    _returns(node["body"], rs)
    falls = not terminates(node["body"])
    declared_ret = ret != None
    if ret == None:
        ret = new_var(st, "type", level)
        if rs["value"] and (rs["none"] or falls):
            ret = mk_opt(ret)
    fc["ret"] = ret
    t = fn(params, ret, at)
    b["type"] = t
    b["locals"] = scope
    b["state"] = "busy"
    b["index"] = len(st["stack"])
    b["low"] = b["index"]
    gstart = len(st["group"])
    st["stack"].append(b)

    ann_vars, ann_defs = {}, {}
    if b["ann"] != None and b["ann"]["body"] != None:
        ann_vars, ann_defs, aliases = split_decls(cv, b["ann"]["body"], name)
        for a in aliases.values():
            report(st, {"file": cv["file"], "pos": a["pos"], "role": None}, "type aliases are declared at the top level of the file")
    declare_scope(st, fc, node["body"], cv, ann_vars, ann_defs, name)
    infer_block(st, fc, node["body"])
    finish_scope(st, scope)
    if falls:
        end = _ctx(fc, node["namepos"], name + "() may end without returning a value (and so return None)")
        if declared_ret or rs["value"]:
            flow_report(st, con("None", [], end), ret, end)
        else:
            unify_report(st, ret, con("None", [], end), end)

    st["stack"].pop()
    if b["low"] < b["index"]:
        # part of a cycle of defs that began earlier: generalized with it
        parent = st["stack"][-1]
        parent["low"] = min(parent["low"], b["low"])
        b["state"] = "pending"
        st["group"].append(b)
        return
    members = st["group"][gstart:]
    st["group"] = st["group"][:gstart]
    for m in members + [b]:
        generalize(st, m["type"], m["scope"]["level"], at)
        m["state"] = "done"

def _def_type(st, fc, b, pos):
    """The type of a reference to def binding b."""
    level = fc["scope"]["level"]
    if b["complete"]:
        return instantiate(st, b["declared"], level)
    if b["state"] == "todo":
        infer_def(st, b)
    if b["state"] == "done":
        return instantiate(st, b["type"], level)
    # being inferred: a recursive reference
    if st["stack"]:
        cur = st["stack"][-1]
        cur["low"] = min(cur["low"], b["low"])
    return b["type"]

# ---------------------------------------------------------------- names

def _find(scope, name):
    for _ in range(1 << 30):
        if scope == None:
            return None
        b = scope["vars"].get(name)
        if b != None:
            return b
        scope = scope["parent"]
    return None

def _all_names(scope):
    out = []
    for _ in range(1 << 30):
        if scope == None:
            break
        out += scope["vars"].keys()
        scope = scope["parent"]
    return out

def lookup(st, fc, e):
    name = e["id"]
    pos = e["pos"]
    if name == "None":
        return con("None", [], _ctx(fc, pos, "None"))
    if name == "True" or name == "False":
        return con("bool", [], _ctx(fc, pos, name))
    t = fc["narrow"].get(name)
    if t != None:
        return t
    b = _find(fc["scope"], name)
    if b == None:
        h = nearest(name, _all_names(fc["scope"]))
        report(st, _ctx(fc, pos), "undefined: " + name + (" (did you mean " + h + "?)" if h else ""))
        return T_ANY
    k = b["kind"]
    if k == "alias":
        b = b["to"]
        k = b["kind"]
    if k == "var":
        return b["type"]
    if k == "def":
        return _def_type(st, fc, b, pos)
    if k == "relation":
        # a relation reads as its list of members in an observer, and as
        # its current member in a reactive definition
        if fc.get("reactive", False):
            return b["type"]
        return con("list", [b["type"]])
    if k == "builtin":
        return instantiate(st, b["type"], fc["scope"]["level"])
    return T_ANY

def _special(fc, name):
    """Is `name` here the builtin of that name (not shadowed)?"""
    b = _find(fc["scope"], name)
    return b != None and b["kind"] == "builtin"

# ---------------------------------------------------------------- narrowing

def _strip_opt(t):
    r = resolve(t)
    return r["args"][0] if is_con(r, "opt") else None

def _narrowable(st, fc, e):
    """If e is a variable whose type is optional: (name, its type without
    None), else (None, None)."""
    if e["kind"] != "name" or e["id"] in ["None", "True", "False"]:
        return None, None
    if e["id"] in fc["narrow"]:
        return None, None
    b = _find(fc["scope"], e["id"])
    if b == None or b["kind"] != "var":
        return None, None
    t = _strip_opt(b["type"])
    if t == None:
        return None, None
    return e["id"], t

def cond_narrow(st, fc, e):
    """What test e tells about optional variables: (names -> types when it
    holds, names -> types when it doesn't)."""
    k = e["kind"]
    if k == "name":
        name, t = _narrowable(st, fc, e)
        return ({name: t}, {}) if name != None else ({}, {})
    if k == "unop" and e["op"] == "not":
        yes, no = cond_narrow(st, fc, e["x"])
        return no, yes
    if k == "binop":
        op = e["op"]
        if op == "!=" or op == "==":
            x, y = e["x"], e["y"]
            if _is_none(x):
                x, y = y, x
            if _is_none(y):
                name, t = _narrowable(st, fc, x)
                if name != None:
                    return ({name: t}, {}) if op == "!=" else ({}, {name: t})
            return {}, {}
        if op == "and" or op == "or":
            y1, n1 = cond_narrow(st, fc, e["x"])
            y2, n2 = cond_narrow(st, fc, e["y"])
            if op == "and":
                y1.update(y2)
                return y1, {}
            n1.update(n2)
            return {}, n1
    return {}, {}

def _with(fc, more):
    """fc's narrowings plus `more`, as a new dict."""
    d = dict(fc["narrow"])
    d.update(more)
    return d

def _assigned(stmts, out):
    for s in stmts:
        k = s["kind"]
        if k == "assign":
            names = []
            _targets(s["lhs"], names)
            for n in names:
                out[n["id"]] = True
        elif k == "for":
            names = []
            _targets(s["target"], names)
            for n in names:
                out[n["id"]] = True
            _assigned(s["body"], out)
        elif k == "if":
            _assigned(s["body"], out)
            _assigned(s["else_"], out)
        elif k == "while":
            _assigned(s["body"], out)

def _forget(fc, stmts):
    """Drop the narrowings of variables assigned in stmts."""
    names = {}
    _assigned(stmts, names)
    for n in names:
        if n in fc["narrow"]:
            fc["narrow"].pop(n)

# ---------------------------------------------------------------- statements

def infer_block(st, fc, stmts):
    for s in stmts:
        infer_stmt(st, fc, s)

def infer_stmt(st, fc, s):
    k = s["kind"]
    if k == "expr":
        if fc["def"] == None and fc["scope"]["level"] == 0:
            fc["observer"] = True
        infer_expr(st, fc, s["x"])
    elif k == "assign":
        _infer_assign(st, fc, s)
    elif k == "return":
        if fc["ret"] == None:
            return  # at top level: the compiler's error
        if s["value"] == None:
            t = con("None", [], _ctx(fc, s["pos"], "return without a value"))
        else:
            t = infer_expr(st, fc, s["value"])
        pos = s["value"]["pos"] if s["value"] != None else s["pos"]
        flow_report(st, t, fc["ret"], _ctx(fc, pos, "return value of " + fc["def"]["name"] + "()"))
    elif k == "if":
        infer_expr(st, fc, s["test"])
        yes, no = cond_narrow(st, fc, s["test"])
        saved = fc["narrow"]
        fc["narrow"] = _with(fc, yes)
        infer_block(st, fc, s["body"])
        after_body = fc["narrow"]
        fc["narrow"] = _with({"narrow": saved}, no)
        infer_block(st, fc, s["else_"])
        after_else = fc["narrow"]
        # what holds after the if: what holds at the end of the branch
        # that gets there, or of both (so after `if x == None: return`,
        # or `if x == None: x = 0`, x is not None)
        if _exits(s["body"]) and not _exits(s["else_"]):
            fc["narrow"] = after_else
        elif _exits(s["else_"]) and not _exits(s["body"]):
            fc["narrow"] = after_body
        else:
            fc["narrow"] = {n: t for n, t in after_body.items() if n in after_else}
    elif k == "for":
        it = infer_expr(st, fc, s["iter"])
        elem = _fresh(st, fc)
        add_pred(st, pred("iter", it, [elem], _ctx(fc, s["iter"]["pos"], "for loop over it")), _ctx(fc, s["iter"]["pos"]))
        saved = fc["narrow"]
        fc["narrow"] = dict(saved)
        _forget(fc, [s])
        assign_target(st, fc, s["target"], elem, "loop variable")
        infer_block(st, fc, s["body"])
        fc["narrow"] = dict(saved)
        _forget(fc, [s])
    elif k == "while":
        saved = fc["narrow"]
        fc["narrow"] = dict(saved)
        _forget(fc, s["body"])
        infer_expr(st, fc, s["test"])
        yes, _ = cond_narrow(st, fc, s["test"])
        fc["narrow"].update(yes)
        infer_block(st, fc, s["body"])
        fc["narrow"] = dict(saved)
        _forget(fc, s["body"])
    elif k == "def":
        b = fc["scope"]["vars"].get(s["name"])
        if b != None and b["kind"] == "var":
            # a name bound by several defs, or also assigned: each def's
            # type (not generalized) must be the variable's
            tmp = {"kind": "def", "node": s, "state": "todo", "type": None, "declared": None, "complete": False,
                   "scope": fc["scope"], "ann": None, "cv": None, "locals": None, "pos": s["namepos"], "name": s["name"]}
            saved = st["stack"]
            st["stack"] = []
            _infer_as_value(st, fc, tmp)
            st["stack"] = saved
            flow_report(st, tmp["type"], b["type"], _ctx(fc, s["namepos"], "definition of '" + s["name"] + "'"))
    elif k == "reactive":
        _infer_reactive(st, fc, s)
    # load: bound by declare_scope; pass, break, continue: nothing

def _infer_as_value(st, fc, b):
    """Infer def b where it stands, without generalizing it."""
    # the body's variables are at the enclosing level: nothing generalizes
    node = b["node"]
    inner = new_scope(fc["scope"], fc["scope"]["level"], fc["mod"])
    ifc = {"scope": inner, "ret": _fresh(st, fc), "narrow": {}, "mod": fc["mod"], "def": b}
    params = []
    for name, star, has_default, kw, pnode in _node_params(node):
        t = _fresh(st, fc)
        if pnode["default"] != None:
            flow_report(st, infer_expr(st, fc, pnode["default"]), t, _ctx(fc, pnode["default"]["pos"], "default value of parameter '" + name + "'"))
        params.append(param(name, t, has_default, star, kw))
        local = con("vtuple", [t]) if star == "*" else (con("dict", [con("str"), t]) if star == "**" else t)
        _declare(inner, name, {"kind": "var", "type": local, "pos": pnode["pos"], "param": True})
    b["type"] = fn(params, ifc["ret"], _ctx(fc, node["namepos"], "definition of " + node["name"]))
    b["state"] = "done"
    b["locals"] = inner
    declare_scope(st, ifc, node["body"], new_conv(st, "", {}, 0), {}, {}, node["name"])
    infer_block(st, ifc, node["body"])
    finish_scope(st, inner)
    if not terminates(node["body"]):
        flow(st, con("None"), ifc["ret"], _ctx(fc, node["namepos"]))

def _infer_assign(st, fc, s):
    op = s["op"]
    lhs = s["lhs"]
    if op == "=":
        t = infer_expr(st, fc, s["rhs"])
        assign_target(st, fc, lhs, t, "assignment")
        return
    # augmented: x op= y is x = x op y
    lt = infer_expr(st, fc, lhs)
    rt = infer_expr(st, fc, s["rhs"])
    res = _fresh(st, fc)
    bop = op[:-1]
    ctx = _ctx(fc, s.get("oppos") or s["pos"], "operand of " + op)
    add_pred(st, binop_pred(bop, lt, rt, res, ctx), ctx)
    if lhs["kind"] in ["name", "index", "dot"]:
        assign_target(st, fc, lhs, res, "result of " + op)

def assign_target(st, fc, target, t, what):
    """Bind assignment target `target` to a value of type t."""
    k = target["kind"]
    pos = target["pos"]
    if k == "name":
        name = target["id"]
        b = fc["scope"]["vars"].get(name)
        if b == None or b["kind"] != "var":
            return  # a def's name, or not declared: the compiler's error
        role = what + " to '" + name + "'" if what != "loop variable" else "loop variable '" + name + "'"
        ctx = _ctx(fc, pos, role)
        if name in fc["narrow"]:
            fc["narrow"].pop(name)
        if name == "_" and st.get("repl", False) and fc["def"] == None and fc["scope"]["level"] == 0:
            # the REPL's last value: each input gives it a new type
            b["type"] = t
            return
        if flow_report(st, t, b["type"], ctx):
            # x = <not None> makes an optional x not None from here on
            r = resolve(t)
            known = r["k"] != "var" or r["num"] or r["lit"] != None
            if _strip_opt(b["type"]) != None and not is_con(r, "opt") and not is_con(r, "None") and known:
                fc["narrow"][name] = t
        return
    if k == "tuple" or k == "list":
        parts = destructure(st, fc, t, len(target["elems"]), pos)
        for i, x in enumerate(target["elems"]):
            assign_target(st, fc, x, parts[i], what)
        return
    if k == "index":
        ct = infer_expr(st, fc, target["x"])
        kt = infer_expr(st, fc, target["i"])
        ctx = _ctx(fc, pos, "item assignment")
        add_pred(st, pred("setitem", ct, [kt, t], ctx), ctx)
        return
    if k == "dot":
        xt = head(st, infer_expr(st, fc, target["x"]))
        if not is_con(xt, "Any"):
            report(st, _ctx(fc, pos), "cannot assign to field '" + target["name"] + "' of " + show(xt) + ": structs are immutable (make a new one: s + struct(" + target["name"] + " = ...))")

def destructure(st, fc, t, n, pos):
    """The types of the n values that a value of type t unpacks to."""
    h = head(st, t)
    ctx = _ctx(fc, pos, "unpacking")
    if h["k"] == "var" and not h["rigid"]:
        parts = [_fresh(st, fc) for _ in range(n)]
        unify_report(st, h, con("tuple", parts, ctx), ctx)
        return parts
    if h["k"] == "con":
        name = h["name"]
        if name == "tuple":
            if len(h["args"]) != n:
                report(st, ctx, "cannot unpack " + show(h) + " (" + str(len(h["args"])) + " elements) into " + str(n) + " variables")
                return [T_ANY] * n
            return h["args"]
        if name == "vtuple" or name == "list" or name == "set" or name == "dict":
            return [h["args"][0]] * n
        if name == "range":
            return [con("int", [], ctx)] * n
        if name == "Any":
            return [T_ANY] * n
        if name == "opt":
            report(st, ctx, "the value may be None (it is " + show(h) + "): test it against None before unpacking it")
            return [T_ANY] * n
    report(st, ctx, "cannot unpack " + show(h) + " into " + str(n) + " variables")
    return [T_ANY] * n

def _infer_reactive(st, fc, s):
    """`name : expr` and struct blocks (the reactive extension)."""
    b = fc["scope"]["vars"].get(s["name"])
    rfc = dict(fc)
    rfc["reactive"] = True
    rfc["observer"] = False
    if s.get("when") != None:
        infer_expr(st, rfc, s["when"])
    t = infer_expr(st, rfc, s["value"])
    if s.get("implicit_id", False):
        h = head(st, t)
        if h["k"] == "rec":
            idf = field(lit("id"), con("int", [], _ctx(fc, s["pos"], "the id that a struct block gets")), _ctx(fc, s["pos"], "the id that a struct block gets"))
            t = rec(row([idf, h["row"]]), h["at"])
    if b == None or (b["kind"] != "var" and b["kind"] != "relation"):
        return
    flow_report(st, t, b["type"], _ctx(fc, s["pos"], "definition of '" + s["name"] + "'"))

# ---------------------------------------------------------------- expressions

def infer_expr(st, fc, e):
    k = e["kind"]
    pos = e["pos"]
    if k == "name":
        return lookup(st, fc, e)
    if k == "int":
        v = _fresh(st, fc)
        v["num"] = True
        v["at"] = _ctx(fc, pos, "an int literal")
        return v
    if k == "float":
        return con("float", [], _ctx(fc, pos, "a float literal"))
    if k == "string":
        v = _fresh(st, fc)
        v["lit"] = e["val"]
        v["at"] = _ctx(fc, pos, "a string literal")
        return v
    if k == "bytes":
        return con("bytes", [], _ctx(fc, pos, "a bytes literal"))
    if k == "list":
        t = _fresh(st, fc)
        first = True
        for x in e["elems"]:
            xt = infer_expr(st, fc, x)
            t = xt if first else join(st, t, xt, _ctx(fc, x["pos"], "list elements have different types"))
            first = False
        return con("list", [t], _ctx(fc, pos, "a list"))
    if k == "tuple":
        return con("tuple", [infer_expr(st, fc, x) for x in e["elems"]], _ctx(fc, pos, "a tuple"))
    if k == "dict":
        kt = _fresh(st, fc)
        vt = _fresh(st, fc)
        first = True
        for key, val in e["entries"]:
            k1 = infer_expr(st, fc, key)
            v1 = infer_expr(st, fc, val)
            kt = k1 if first else join(st, kt, k1, _ctx(fc, key["pos"], "dict keys have different types"))
            vt = v1 if first else join(st, vt, v1, _ctx(fc, val["pos"], "dict values have different types"))
            first = False
        return con("dict", [kt, vt], _ctx(fc, pos, "a dict"))
    if k == "unop":
        t = infer_expr(st, fc, e["x"])
        op = e["op"]
        if op == "not":
            return con("bool", [], _ctx(fc, pos, "result of not"))
        ctx = _ctx(fc, pos, "operand of unary " + op)
        if op == "~":
            unify_report(st, t, con("int"), ctx)
            return con("int", [], ctx)
        r = resolve(t)
        if not (r["k"] == "var" and r["num"]):
            add_pred(st, pred("among", t, [], ctx, ["int", "float"]), ctx)
        return t
    if k == "binop":
        return _infer_binop(st, fc, e)
    if k == "cond":
        infer_expr(st, fc, e["test"])
        yes, no = cond_narrow(st, fc, e["test"])
        saved = fc["narrow"]
        fc["narrow"] = _with(fc, yes)
        a = infer_expr(st, fc, e["then"])
        fc["narrow"] = _with({"narrow": saved}, no)
        b = infer_expr(st, fc, e["else_"])
        fc["narrow"] = saved
        return join(st, a, b, _ctx(fc, e["else_"]["pos"], "the branches of a conditional expression have different types"))
    if k == "call":
        return infer_call(st, fc, e)
    if k == "index":
        ct = infer_expr(st, fc, e["x"])
        it = infer_expr(st, fc, e["i"])
        h = resolve(ct)
        if is_con(h, "tuple") and e["i"]["kind"] == "int":
            n = len(h["args"])
            i = e["i"]["val"]
            if i >= n or i < -n:
                report(st, _ctx(fc, e["i"]["pos"]), "index " + str(i) + " is out of range for " + show(h) + " (" + str(n) + " elements)")
                return T_ANY
            return h["args"][i]
        res = _fresh(st, fc)
        ctx = _ctx(fc, pos, "indexing")
        add_pred(st, pred("getitem", ct, [it, res], ctx, e["i"]["val"] if e["i"]["kind"] == "int" else None), ctx)
        return res
    if k == "slice":
        ct = infer_expr(st, fc, e["x"])
        for part in ["lo", "hi", "step"]:
            if e[part] != None and not _is_none(e[part]):
                unify_report(st, infer_expr(st, fc, e[part]), con("int"), _ctx(fc, e[part]["pos"], "slice index"))
        res = _fresh(st, fc)
        ctx = _ctx(fc, pos, "slicing")
        add_pred(st, pred("slice", ct, [res], ctx), ctx)
        return res
    if k == "dot":
        xt = infer_expr(st, fc, e["x"])
        return attr_type(st, xt, e["name"], _ctx(fc, pos, "." + e["name"] + " is used here"), fc["scope"]["level"])
    if k == "comp":
        return _infer_comp(st, fc, e)
    if k == "lambda":
        return _infer_lambda(st, fc, e)
    return T_ANY

def _quiet_join(st, fc, a, b, op):
    """The type of `a or b` / `a and b`: these are mostly used for their
    truth, so operands of different types are no error (the result is then
    Any)."""
    ra = head(st, a)
    rb = head(st, b)
    if ra["k"] == "var" or rb["k"] == "var":
        # `x or default`: x is what the default is
        if op == "or" and not is_con(ra, "None") and not is_con(rb, "None") and unify(st, a, b, _ctx(fc, (0, 0))) == None:
            return a
        return b if ra["k"] == "var" else a
    if is_con(ra, "None"):
        return mk_opt(b) if not is_con(rb, "None") else rb
    if is_con(rb, "None"):
        return mk_opt(a)
    if is_con(ra, "opt") or is_con(rb, "opt"):
        x = ra["args"][0] if is_con(ra, "opt") else ra
        y = rb["args"][0] if is_con(rb, "opt") else rb
        return mk_opt(_quiet_join(st, fc, x, y, op))
    if ra["k"] != rb["k"] or (ra["k"] == "con" and (ra["name"] != rb["name"] or len(ra["args"]) != len(rb["args"]))):
        return T_ANY
    if unify(st, a, b, _ctx(fc, (0, 0))) != None:
        return T_ANY
    return a

def _numeric(t):
    r = resolve(t)
    return (r["k"] == "var" and r["num"]) or is_con(r, "int") or is_con(r, "float")

def _infer_binop(st, fc, e):
    op = e["op"]
    pos = e["pos"]
    if op == "and" or op == "or":
        a = infer_expr(st, fc, e["x"])
        yes, no = cond_narrow(st, fc, e["x"])
        saved = fc["narrow"]
        fc["narrow"] = _with(fc, yes if op == "and" else no)
        b = infer_expr(st, fc, e["y"])
        fc["narrow"] = saved
        if op == "or":
            s = _strip_opt(a)
            if s != None:
                a = s
            elif is_con(resolve(a), "None"):
                return b
        return _quiet_join(st, fc, a, b, op)
    a = infer_expr(st, fc, e["x"])
    b = infer_expr(st, fc, e["y"])
    if op == "==" or op == "!=":
        # x == None, for an x of unknown type: x may be None
        for x, xt, y in [(e["x"], a, e["y"]), (e["y"], b, e["x"])]:
            r = resolve(xt)
            if _is_none(y) and r["k"] == "var" and not r["rigid"] and r["lit"] == None and not r["num"]:
                unify(st, r, mk_opt(new_var(st, "type", r["level"])), _ctx(fc, pos, "comparison with None"))
        return con("bool", [], _ctx(fc, pos, "a comparison"))
    if op in ["<", "<=", ">", ">="]:
        if not (_numeric(a) and _numeric(b)):
            ctx = _ctx(fc, pos, "operands of " + op + " have different types")
            if unify_report(st, a, b, ctx):
                add_pred(st, pred("ordered", a, [], _ctx(fc, pos, "operand of " + op)), ctx)
        return con("bool", [], _ctx(fc, pos, "a comparison"))
    if op == "in" or op == "not in":
        ctx = _ctx(fc, pos, "operand of " + op)
        add_pred(st, pred("contains", b, [a], ctx), ctx)
        return con("bool", [], _ctx(fc, pos, "a membership test"))
    res = _fresh(st, fc)
    ctx = _ctx(fc, pos, "operand of " + op)
    add_pred(st, binop_pred(op, a, b, res, ctx), ctx)
    return res

def _infer_comp(st, fc, e):
    inner = new_scope(fc["scope"], fc["scope"]["level"], fc["mod"])
    cfc = dict(fc)
    cfc["narrow"] = dict(fc["narrow"])
    for c in e["clauses"]:
        if c["kind"] == "for":
            names = []
            _targets(c["target"], names)
            for n in names:
                _declare(inner, n["id"], {"kind": "var", "type": _fresh(st, fc), "pos": n["pos"]})
                if n["id"] in cfc["narrow"]:
                    cfc["narrow"].pop(n["id"])
    first = True
    for c in e["clauses"]:
        if c["kind"] == "for":
            # the first iterable is evaluated outside the comprehension
            it = infer_expr(st, fc if first else cfc, c["iter"])
            first = False
            cfc["scope"] = inner
            elem = _fresh(st, fc)
            ctx = _ctx(fc, c["iter"]["pos"], "comprehension over it")
            add_pred(st, pred("iter", it, [elem], ctx), ctx)
            assign_target(st, cfc, c["target"], elem, "loop variable")
        else:
            infer_expr(st, cfc, c["test"])
            yes, _ = cond_narrow(st, cfc, c["test"])
            cfc["narrow"].update(yes)
    if e["comp"] == "dict":
        kt = infer_expr(st, cfc, e["body"][0])
        vt = infer_expr(st, cfc, e["body"][1])
        return con("dict", [kt, vt], _ctx(fc, e["pos"], "a dict comprehension"))
    return con("list", [infer_expr(st, cfc, e["body"])], _ctx(fc, e["pos"], "a list comprehension"))

def _infer_lambda(st, fc, e):
    inner = new_scope(fc["scope"], fc["scope"]["level"], fc["mod"])
    lfc = dict(fc)
    lfc["scope"] = inner
    lfc["narrow"] = {}
    params = []
    for name, star, has_default, kw, pnode in _node_params(e):
        t = _fresh(st, fc)
        if pnode["default"] != None:
            dt = infer_expr(st, fc, pnode["default"])
            if _is_none(pnode["default"]):
                t = mk_opt(t)
            else:
                flow_report(st, dt, t, _ctx(fc, pnode["default"]["pos"], "default value of parameter '" + name + "'"))
        params.append(param(name, t, has_default, star, kw))
        local = con("vtuple", [t]) if star == "*" else (con("dict", [con("str"), t]) if star == "**" else t)
        _declare(inner, name, {"kind": "var", "type": local, "pos": pnode["pos"], "param": True})
    ret = infer_expr(st, lfc, e["body"])
    return fn(params, ret, _ctx(fc, e["pos"], "a lambda"))

# ---------------------------------------------------------------- calls

def _callee_name(f):
    if f["kind"] == "name":
        return f["id"] + "()"
    if f["kind"] == "dot":
        return "." + f["name"] + "()"
    return "this"

# A call of this name with one argument records the argument's type in
# st["probe"]: how the REPL asks for the type of an expression inside a
# block that is still being typed (--attrs-probe in main.star).
PROBE = "_complete_probe_"

def infer_call(st, fc, e):
    f = e["fn"]
    pos = e["pos"]
    if f["kind"] == "name" and f["id"] == PROBE and len(e["args"]) == 1:
        st["probe"] = infer_expr(st, fc, e["args"][0]["value"])
        return T_ANY
    if f["kind"] == "name" and f["id"] in SPECIAL and _special(fc, f["id"]):
        t = SPECIAL[f["id"]](st, fc, e)
        if t != None:
            return t
    if f["kind"] == "dot":
        rt = infer_expr(st, fc, f["x"])
        name = f["name"]
        npos = len([a for a in e["args"] if a["name"] == None and a["star"] == ""])
        if name in ["get", "pop"] and npos == 2 and len(e["args"]) == 2:
            h = head(st, rt)
            if h["k"] == "var" and not h["rigid"] and name == "get":
                unify(st, h, pattern(st, "dict", h["level"]), _ctx(fc, f["pos"], ".get is used here"))
                h = resolve(h)
            if is_con(h, "dict"):
                # d.get(k, default), d.pop(k, default): a V or the default
                kt = infer_expr(st, fc, e["args"][0]["value"])
                dt = infer_expr(st, fc, e["args"][1]["value"])
                flow_report(st, kt, h["args"][0], _ctx(fc, e["args"][0]["value"]["pos"], "argument 'key' of ." + name + "()"))
                return join(st, h["args"][1], dt, _ctx(fc, e["args"][1]["value"]["pos"], "the default of ." + name + "() and the dict's values have different types"))
        ft = attr_type(st, rt, name, _ctx(fc, f["pos"], "." + name + " is used here"), fc["scope"]["level"])
    else:
        ft = infer_expr(st, fc, f)
    args = [{"name": a["name"], "star": a["star"], "type": infer_expr(st, fc, a["value"]), "pos": a["value"]["pos"]} for a in e["args"]]
    return apply(st, fc, ft, args, pos, _callee_name(f))

def apply(st, fc, ft, args, pos, fname):
    """The type of calling a value of type ft with args ({name, star,
    type, pos}), checking them against its parameters."""
    h = head(st, ft)
    ctx = _ctx(fc, pos, "call of " + fname)
    if h["k"] == "con" and h["name"] == "Any":
        return T_ANY
    if h["k"] == "var":
        if h["rigid"]:
            report(st, ctx, "cannot call " + fname + ": its type is the type parameter '" + (h["name"] or "?") + "', which stands for any type")
            return T_ANY
        # an unknown function: it takes what it is given
        params = []
        for a in args:
            if a["star"] != "":
                params.append(param("args" if a["star"] == "*" else "kwargs", _fresh(st, fc), False, a["star"]))
            else:
                params.append(param(a["name"], a["type"], False, "", a["name"] != None))
        ret = _fresh(st, fc)
        unify_report(st, h, fn(params, ret, ctx), ctx)
        return ret
    if h["k"] != "fn":
        if is_con(h, "opt"):
            report(st, ctx, "cannot call " + fname + ": it may be None (it is " + show(h) + ")")
        else:
            report(st, ctx, "cannot call " + fname + ": it is " + show(h) + ", not a function")
        return T_ANY
    params = h["params"]
    positional = [p for p in params if p["star"] == "" and not p["kw"]]
    named = {p["name"]: p for p in params if p["star"] == "" and p["name"] != None}
    star = [p for p in params if p["star"] == "*"]
    kwstar = [p for p in params if p["star"] == "**"]
    used = {}
    i = 0
    # a *args (**kwargs) parameter of unknown type takes arguments of
    # different types, as print does: nothing in the function depends on
    # their type
    loose_star = len(star) > 0 and resolve(star[0]["type"])["k"] == "var"
    loose_kw = len(kwstar) > 0 and resolve(kwstar[0]["type"])["k"] == "var"
    any_star = False
    any_kw = False
    defined = []
    o = h.get("at")
    if o != None and (o.get("role") or "").startswith("definition"):
        defined = [note_at(o, fname + " is defined here")]
    elif o != None and o.get("role") == "declared here":
        defined = [note_at(o, fname + " is declared here")]
    too_many = False
    for a in args:
        if a["star"] == "*":
            any_star = True
            elem = _fresh(st, fc)
            actx = _ctx(fc, a["pos"], "argument *args of " + fname)
            add_pred(st, pred("iter", a["type"], [elem], actx), actx)
            for p in positional[i:]:
                flow(st, elem, p["type"], actx)
            if star:
                flow_report(st, elem, star[0]["type"], actx)
            continue
        if a["star"] == "**":
            any_kw = True
            continue
        if a["name"] == None:
            if i < len(positional):
                p = positional[i]
                i += 1
                label = "argument '" + p["name"] + "' of " + fname if p["name"] != None else "argument " + str(i) + " of " + fname
                if p["name"] != None:
                    used[p["name"]] = True
                else:
                    used[i] = True
                flow_report(st, a["type"], p["type"], _ctx(fc, a["pos"], label))
            elif star and loose_star:
                flow(st, a["type"], star[0]["type"], _ctx(fc, a["pos"]))
            elif star:
                flow_report(st, a["type"], star[0]["type"], _ctx(fc, a["pos"], "argument of " + fname))
            elif not too_many:
                too_many = True
                n = len(positional)
                report(st, _ctx(fc, a["pos"]), fname + " takes " + ("no" if n == 0 else "at most " + str(n)) + " positional argument" + ("" if n == 1 else "s") +
                                               ", but " + str(len([x for x in args if x["name"] == None and x["star"] == ""])) + " are given", defined)
            continue
        p = named.get(a["name"])
        if p != None:
            if used.get(a["name"], False):
                report(st, _ctx(fc, a["pos"]), "argument '" + a["name"] + "' of " + fname + " is given twice")
            used[a["name"]] = True
            flow_report(st, a["type"], p["type"], _ctx(fc, a["pos"], "argument '" + a["name"] + "' of " + fname))
        elif kwstar and loose_kw:
            flow(st, a["type"], kwstar[0]["type"], _ctx(fc, a["pos"]))
        elif kwstar:
            flow_report(st, a["type"], kwstar[0]["type"], _ctx(fc, a["pos"], "argument '" + a["name"] + "' of " + fname))
        else:
            hn = nearest(a["name"], named.keys())
            report(st, _ctx(fc, a["pos"]), fname + " has no parameter '" + a["name"] + "'" + (" (did you mean '" + hn + "'?)" if hn else ""), defined)
    missing = []
    for j, p in enumerate(positional):
        if p["opt"] or any_star:
            continue
        if p["name"] != None and (used.get(p["name"], False) or any_kw):
            continue
        if p["name"] == None and j < i:
            continue
        if j < i:
            continue
        missing.append("'" + p["name"] + "'" if p["name"] != None else "#" + str(j + 1))
    for p in params:
        if p["kw"] and p["star"] == "" and not p["opt"] and not used.get(p["name"], False) and not any_kw:
            missing.append("'" + p["name"] + "'")
    if missing:
        report(st, ctx, fname + " is missing argument" + ("s " if len(missing) > 1 else " ") + ", ".join(missing), defined)
    return h["ret"]

# Builtins with a typing rule of their own. Each returns the call's type,
# or None to have the call checked against the builtin's signature.

def _sp_struct(st, fc, e):
    items = []
    seen = {}
    for a in e["args"]:
        t = infer_expr(st, fc, a["value"])
        if a["star"] == "**":
            # fields that are only known at run time: an open struct
            items.append(new_var(st, "row", fc["scope"]["level"]))
        elif a["star"] == "*" or a["name"] == None:
            report(st, _ctx(fc, a["value"]["pos"]), "struct() takes only named arguments: struct(name = value, ...)")
        else:
            if a["name"] in seen:
                report(st, _ctx(fc, a.get("pos") or a["value"]["pos"]), "field '" + a["name"] + "' is given twice")
                continue
            seen[a["name"]] = True
            items.append(field(lit(a["name"]), t, _ctx(fc, a.get("pos") or a["value"]["pos"], "field '" + a["name"] + "' of the struct")))
    return rec(row(items), _ctx(fc, e["pos"], "a struct made here"))

def _sp_getattr(st, fc, e):
    args = e["args"]
    if len(args) < 2 or len(args) > 3 or len([a for a in args if a["name"] != None or a["star"] != ""]) > 0:
        return None
    xt = infer_expr(st, fc, args[0]["value"])
    nt = infer_expr(st, fc, args[1]["value"])
    npos = args[1]["value"]["pos"]
    rn = resolve(nt)
    level = fc["scope"]["level"]
    if len(args) == 3:
        # the field may be missing: the result is its type or the default's
        dt = infer_expr(st, fc, args[2]["value"])
        h = resolve(xt)
        if rn["k"] == "var" and rn["lit"] != None and h["k"] == "rec":
            for it in [x for x in _fields(h) if x[0] == rn["lit"]]:
                return join(st, it[1], dt, _ctx(fc, args[2]["value"]["pos"], "the default of getattr() and the field have different types"))
            return dt
        return T_ANY
    if rn["k"] == "var" and rn["lit"] != None:
        # getattr(x, "name") is x.name
        return attr_type(st, xt, rn["lit"], _ctx(fc, npos, "field '" + rn["lit"] + "' is used here"), level)
    if is_con(rn, "str") or is_con(rn, "Any"):
        return T_ANY  # any string: nothing is known about the field
    # a field name that is a value (the paper's first-class labels): x is
    # {L: T | R} and the name is an L
    label = new_var(st, "label", level)
    ctx = _ctx(fc, npos, "field name of getattr()")
    if not unify_report(st, nt, lab(label, ctx), ctx):
        return T_ANY
    ft = _fresh(st, fc)
    want = rec(row([field(label, ft, ctx), new_var(st, "row", level)]), ctx)
    flow_report(st, xt, want, _ctx(fc, args[0]["value"]["pos"], "argument 1 of getattr()"))
    return ft

def _fields(h):
    """(name, type) of the fields of record type h with literal names."""
    out = []
    for it in flatten(h["row"]):
        if it["k"] == "f":
            l = resolve_label(it["label"])
            if l["k"] == "lit":
                out.append((l["name"], it["type"]))
    return out

def _sp_minmax(st, fc, e):
    name = e["fn"]["id"]
    pos_args = [a for a in e["args"] if a["name"] == None and a["star"] == ""]
    if len(pos_args) != len([a for a in e["args"] if a["name"] != "key"]) or not pos_args:
        return None
    has_key = False
    for a in e["args"]:
        if a["name"] == "key":
            infer_expr(st, fc, a["value"])
            has_key = True
    ctx = _ctx(fc, e["pos"], "argument of " + name + "()")
    if len(pos_args) == 1:
        it = infer_expr(st, fc, pos_args[0]["value"])
        t = _fresh(st, fc)
        add_pred(st, pred("iter", it, [t], ctx), ctx)
    else:
        t = infer_expr(st, fc, pos_args[0]["value"])
        for a in pos_args[1:]:
            t = join(st, t, infer_expr(st, fc, a["value"]), _ctx(fc, a["value"]["pos"], "arguments of " + name + "() have different types"))
    if not has_key:
        add_pred(st, pred("ordered", t, [], ctx), ctx)
    return t

def _sp_zip(st, fc, e):
    if len([a for a in e["args"] if a["name"] != None or a["star"] != ""]) > 0:
        return None
    elems = []
    for a in e["args"]:
        it = infer_expr(st, fc, a["value"])
        t = _fresh(st, fc)
        ctx = _ctx(fc, a["value"]["pos"], "argument of zip()")
        add_pred(st, pred("iter", it, [t], ctx), ctx)
        elems.append(t)
    return con("list", [con("tuple", elems)], _ctx(fc, e["pos"], "result of zip()"))

def _sp_dict(st, fc, e):
    if len([a for a in e["args"] if a["star"] != ""]) > 0:
        return None
    pos_args = [a for a in e["args"] if a["name"] == None]
    if len(pos_args) > 1:
        return None
    kt = _fresh(st, fc)
    vt = _fresh(st, fc)
    if pos_args:
        a = pos_args[0]["value"]
        t = infer_expr(st, fc, a)
        h = head(st, t)
        ctx = _ctx(fc, a["pos"], "argument of dict()")
        if is_con(h, "dict"):
            kt, vt = h["args"]
        else:
            add_pred(st, pred("iter", t, [con("tuple", [kt, vt], ctx)], ctx), ctx)
    first = not pos_args
    for a in e["args"]:
        if a["name"] != None:
            unify_report(st, kt, con("str"), _ctx(fc, a["value"]["pos"], "the keys of dict(name = ...) are strings"))
            v1 = infer_expr(st, fc, a["value"])
            vt = v1 if first else join(st, vt, v1, _ctx(fc, a["value"]["pos"], "dict values have different types"))
            first = False
    return con("dict", [kt, vt], _ctx(fc, e["pos"], "result of dict()"))

SPECIAL = {
    "struct": _sp_struct,
    "getattr": _sp_getattr,
    "min": _sp_minmax,
    "max": _sp_minmax,
    "zip": _sp_zip,
    "dict": _sp_dict,
}
