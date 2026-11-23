# nones.star — analyses of the AST for contagious None (EXTENSIONS.md,
# "Fallible operations"), used by infer.star:
#
# - unbound reads: a def (or lambda) that may read a variable before it is
#   assigned fails then, at run time, and so its call gives None;
# - safe item assignments: `x[k] = v` fails (giving None) unless x is a
#   dict or list that the def itself made and isn't iterating over;
# - escapes: a def called with a None for a parameter (a None the checker
#   took out of the argument's type, making the call's result optional)
#   runs with it. That is right only if the None can't get out of the call
#   other than as (what is computed from it in) its result: not into a
#   container it doesn't make, a value it returns, a closure or another
#   function that might keep it.
#
# All of them look only at the syntax; names are resolved by the caller.

# ---------------------------------------------------------------- bindings

def targets(e, out):
    """The name nodes bound by assignment target e."""
    k = e["kind"]
    if k == "name":
        out.append(e)
    elif k == "tuple" or k == "list":
        for x in e["elems"]:
            targets(x, out)

def bound_names(stmts, out):
    """out[name] = True for each name the statements bind in their own
    scope (assignments, loop variables, defs, loads, reactive variables;
    not the names of nested defs' bodies or comprehensions)."""
    for s in stmts:
        k = s["kind"]
        names = []
        if k == "assign":
            targets(s["lhs"], names)
        elif k == "for":
            targets(s["target"], names)
            bound_names(s["body"], out)
        elif k == "if":
            bound_names(s["body"], out)
            bound_names(s["else_"], out)
        elif k == "while":
            bound_names(s["body"], out)
        elif k == "def":
            out[s["name"]] = True
        elif k == "load":
            for local, _ in s["names"]:
                out[local] = True
        elif k == "reactive":
            out[s["name"]] = True
        for n in names:
            out[n["id"]] = True

def param_names(node):
    return [p["name"] for p in node["params"] if p["name"] != None]

# ---------------------------------------------------------------- unbound reads
#
# Definite assignment: D, the names certainly assigned at a point (None
# where the point can't be reached: after return, break, continue, fail).
# A read of a local name not in D may fail; so may a read of a name of an
# enclosing scope that may be unassigned there (`outer`): for a def at the
# top level, a global that may be unassigned at the end of the module (the
# defs run after it, in updates); for a nested def or lambda, a local of
# the enclosing def that may be unassigned where the nested one is made.

def _meet(a, b):
    if a == None:
        return b
    if b == None:
        return a
    return {n: True for n in a if n in b}

def _ua_stmts(stmts, d, cx):
    for s in stmts:
        if d == None:
            return None
        d = _ua_stmt(s, d, cx)
    return d

def _ua_stmt(s, d, cx):
    k = s["kind"]
    if k == "expr":
        _ua_expr(s["x"], d, cx, {})
        x = s["x"]
        if x["kind"] == "call" and x["fn"]["kind"] == "name" and x["fn"]["id"] == "fail":
            return None
        return d
    if k == "assign":
        if s["op"] != "=":
            _ua_expr(s["lhs"], d, cx, {})
        _ua_expr(s["rhs"], d, cx, {})
        _ua_target(s["lhs"], d, cx)
        names = []
        targets(s["lhs"], names)
        d = dict(d)
        for n in names:
            d[n["id"]] = True
        return d
    if k == "return":
        if s["value"] != None:
            _ua_expr(s["value"], d, cx, {})
        return None
    if k == "break" or k == "continue":
        return None
    if k == "if":
        _ua_expr(s["test"], d, cx, {})
        return _meet(_ua_stmts(s["body"], dict(d), cx), _ua_stmts(s["else_"], dict(d), cx))
    if k == "for":
        _ua_expr(s["iter"], d, cx, {})
        names = []
        targets(s["target"], names)
        _ua_target(s["target"], d, cx)
        inner = dict(d)
        for n in names:
            inner[n["id"]] = True
        _ua_stmts(s["body"], inner, cx)
        return d  # (the loop may not run)
    if k == "while":
        _ua_expr(s["test"], d, cx, {})
        _ua_stmts(s["body"], dict(d), cx)
        return d
    if k == "def":
        for p in s["params"]:
            if p["default"] != None:
                _ua_expr(p["default"], d, cx, {})
        _ua_nested(s, d, cx, {})
        d = dict(d)
        d[s["name"]] = True
        return d
    if k == "reactive":
        if s.get("when") != None:
            _ua_expr(s["when"], d, cx, {})
        _ua_expr(s["value"], d, cx, {})
        d = dict(d)
        d[s["name"]] = True
        return d
    if k == "load":
        d = dict(d)
        for local, _ in s["names"]:
            d[local] = True
        return d
    return d  # pass

def _ua_target(e, d, cx):
    """The reads in assignment target e (x and i in x[i] = v)."""
    k = e["kind"]
    if k == "index":
        _ua_expr(e["x"], d, cx, {})
        _ua_expr(e["i"], d, cx, {})
    elif k == "dot":
        _ua_expr(e["x"], d, cx, {})
    elif k == "tuple" or k == "list":
        for x in e["elems"]:
            _ua_target(x, d, cx)

def _ua_nested(node, d, cx, shadow):
    """Note what a nested def or lambda, made at a point where d holds,
    may find unassigned among the names of the scopes around it."""
    out = {n: True for n in cx["locals"] if n not in d and n not in shadow}
    for n in cx["outer"]:
        if n not in cx["locals"] and n not in shadow:
            out[n] = True
    cx["nested"][cx["key"](node)] = out

def _ua_read(name, d, cx, shadow):
    if name in shadow:
        return
    if name in cx["locals"]:
        if name not in d:
            cx["bad"].append(name)
    elif name in cx["outer"]:
        cx["bad"].append(name)

def _ua_expr(e, d, cx, shadow):
    if e == None:
        return
    k = e["kind"]
    if k == "name":
        _ua_read(e["id"], d, cx, shadow)
    elif k == "list" or k == "tuple":
        for x in e["elems"]:
            _ua_expr(x, d, cx, shadow)
    elif k == "dict":
        for key, val in e["entries"]:
            _ua_expr(key, d, cx, shadow)
            _ua_expr(val, d, cx, shadow)
    elif k == "unop":
        _ua_expr(e["x"], d, cx, shadow)
    elif k == "binop":
        _ua_expr(e["x"], d, cx, shadow)
        _ua_expr(e["y"], d, cx, shadow)
    elif k == "cond":
        _ua_expr(e["test"], d, cx, shadow)
        _ua_expr(e["then"], d, cx, shadow)
        _ua_expr(e["else_"], d, cx, shadow)
    elif k == "call":
        _ua_expr(e["fn"], d, cx, shadow)
        for a in e["args"]:
            _ua_expr(a["value"], d, cx, shadow)
    elif k == "index":
        _ua_expr(e["x"], d, cx, shadow)
        _ua_expr(e["i"], d, cx, shadow)
    elif k == "slice":
        _ua_expr(e["x"], d, cx, shadow)
        for part in ["lo", "hi", "step"]:
            _ua_expr(e[part], d, cx, shadow)
    elif k == "dot":
        _ua_expr(e["x"], d, cx, shadow)
    elif k == "comp":
        inner = dict(shadow)
        first = True
        for c in e["clauses"]:
            if c["kind"] == "for":
                # (the first iterable is evaluated outside the comprehension)
                _ua_expr(c["iter"], d, cx, shadow if first else inner)
                first = False
                names = []
                targets(c["target"], names)
                for n in names:
                    inner[n["id"]] = True
            else:
                _ua_expr(c["test"], d, cx, inner)
        if e["comp"] == "dict":
            _ua_expr(e["body"][0], d, cx, inner)
            _ua_expr(e["body"][1], d, cx, inner)
        else:
            _ua_expr(e["body"], d, cx, inner)
    elif k == "lambda":
        for p in e["params"]:
            if p["default"] != None:
                _ua_expr(p["default"], d, cx, shadow)
        _ua_nested(e, d, cx, shadow)

def unbound_module(stmts, key):
    """(The names of the module that may be unassigned at its end, {key of
    a nested def or lambda: what it may find unassigned}.) key(node) names
    a def or lambda node."""
    names = {}
    bound_names(stmts, names)
    cx = {"locals": names, "outer": {}, "bad": [], "nested": {}, "key": key}
    d = _ua_stmts(stmts, {}, cx)
    if d == None:
        return {}, cx["nested"]
    out = {n: True for n in names if n not in d}
    for node in [s for s in stmts if s["kind"] == "def"]:
        cx["nested"][key(node)] = out  # (called after the top level has run)
    return out, cx["nested"]

def unbound_def(node, outer, key):
    """(The names def node may read unassigned, {key of a def or lambda
    nested in it: what it may find unassigned}.) outer: the names of the
    scopes around it that may be unassigned (unbound_module, or what the
    enclosing def noted)."""
    names = {}
    bound_names(node["body"], names)
    params = param_names(node)
    for p in params:
        names[p] = True
    cx = {"locals": names, "outer": outer, "bad": [], "nested": {}, "key": key}
    _ua_stmts(node["body"], {p: True for p in params}, cx)
    return cx["bad"], cx["nested"]

def unbound_lambda(node, outer, key):
    """As unbound_def, for a lambda node."""
    params = param_names(node)
    cx = {"locals": {p: True for p in params}, "outer": outer, "bad": [], "nested": {}, "key": key}
    _ua_expr(node["body"], {p: True for p in params}, cx, {})
    return cx["bad"], cx["nested"]

# ---------------------------------------------------------------- item assignment
#
# `x[k] = v` (and `x[k] += v`, `for x[k] in ...`) can fail: a list index out
# of range, a frozen value (every global, after the first run), a list or
# dict that is being iterated over. It can't for a local variable whose
# every binding is a dict made right there (a literal or comprehension),
# where the assignment isn't inside a loop over an expression that reads
# the variable. (Not a local of an enclosing def: a closure that holds it
# may be held by a global, which freezes it.) Nor for such a list made by list
# literals, by an index written out that each of them has, where nothing
# can have removed elements: no .pop, .remove or .clear of it, and it isn't
# used but indexed, by a method, assigned to, or returned.

def _fresh_kind(e):
    """"dict" or "list" if e makes a new dict or list, else None."""
    k = e["kind"]
    if k == "dict":
        return "dict"
    if k == "list":
        return "list"
    if k == "comp":
        return e["comp"]
    return None

def _fresh_locals(stmts, params, out):
    """out[name] = "dict" / "list" / False: the kind of what every binding
    of name in stmts makes, or False if one is anything else."""
    for s in stmts:
        k = s["kind"]
        if k == "assign":
            names = []
            targets(s["lhs"], names)
            for n in names:
                kind = _fresh_kind(s["rhs"]) if s["op"] == "=" and s["lhs"]["kind"] == "name" else None
                prev = out.get(n["id"])
                out[n["id"]] = kind if kind != None and (prev == None or prev == kind) else False
        elif k == "for":
            names = []
            targets(s["target"], names)
            for n in names:
                out[n["id"]] = False
            _fresh_locals(s["body"], params, out)
        elif k == "if":
            _fresh_locals(s["body"], params, out)
            _fresh_locals(s["else_"], params, out)
        elif k == "while":
            _fresh_locals(s["body"], params, out)
        elif k == "def":
            out[s["name"]] = False
    for p in params:
        out[p] = False

def _reads(e, name):
    """Does expression e read name (anywhere in it)?"""
    t = type(e)
    if t == "list" or t == "tuple":
        for x in e:
            if _reads(x, name):
                return True
        return False
    if t != "dict":
        return False
    if e.get("kind") == "name" and e.get("id") == name:
        return True
    for key, v in e.items():
        if key != "pos" and _reads(v, name):
            return True
    return False

def _si_stmts(stmts, fresh, loops, out):
    for s in stmts:
        k = s["kind"]
        if k == "assign":
            _si_target(s["lhs"], fresh, loops, out)
        elif k == "for":
            _si_target(s["target"], fresh, loops, out)
            _si_stmts(s["body"], fresh, loops + [s["iter"]], out)
        elif k == "if":
            _si_stmts(s["body"], fresh, loops, out)
            _si_stmts(s["else_"], fresh, loops, out)
        elif k == "while":
            # (a while loop iterates over nothing; its test may read x, but
            # an assignment in its body doesn't upset that)
            _si_stmts(s["body"], fresh, loops, out)

def _si_target(e, fresh, loops, out):
    k = e["kind"]
    if k == "tuple" or k == "list":
        for x in e["elems"]:
            _si_target(x, fresh, loops, out)
    elif k == "index" and e["x"]["kind"] == "name":
        name = e["x"]["id"]
        kind = fresh.get(name)
        if kind and len([it for it in loops if _reads(it, name)]) == 0:
            out.append((e, kind))

def _index_written(i):
    """The int that index expression i writes out, or None."""
    if i["kind"] == "int":
        return i["val"]
    if i["kind"] == "unop" and i["op"] == "-" and i["x"]["kind"] == "int":
        return -i["x"]["val"]
    return None

def _list_lengths(stmts, name, out):
    """out gets the number of elements of each list literal bound to name
    (None for a comprehension)."""
    for s in stmts:
        k = s["kind"]
        if k == "assign" and s["op"] == "=" and s["lhs"]["kind"] == "name" and s["lhs"]["id"] == name:
            out.append(len(s["rhs"]["elems"]) if s["rhs"]["kind"] == "list" else None)
        for key in ["body", "else_"]:
            if k != "def" and key in s:
                _list_lengths(s[key], name, out)

def _shrinkable(x, name):
    """Can AST x remove elements of the list name holds: call .pop,
    .remove or .clear on it, or use it other than indexed, by another
    method, assigned to, or returned (it may be given to code that does)?"""
    t = type(x)
    if t == "list" or t == "tuple":
        for v in x:
            if _shrinkable(v, name):
                return True
        return False
    if t != "dict":
        return False
    k = x.get("kind")
    if k == "name":
        return x["id"] == name
    if k == "return" and x["value"] != None and x["value"]["kind"] == "name":
        return False
    if k == "call" and x["fn"]["kind"] == "dot" and x["fn"]["x"]["kind"] == "name" and x["fn"]["x"]["id"] == name:
        if x["fn"]["name"] in ["pop", "remove", "clear"]:
            return True
        return _shrinkable([a["value"] for a in x["args"]], name)
    if (k == "index" or k == "dot") and x["x"]["kind"] == "name" and x["x"]["id"] == name:
        return _shrinkable(x.get("i"), name)
    for key, v in x.items():
        if key == "pos":
            continue
        if (key == "lhs" or key == "target") and type(v) == "dict" and v.get("kind") == "name":
            continue
        if _shrinkable(v, name):
            return True
    return False

def safe_setitems(node):
    """{position of an item assignment target in def node's body: True}:
    the ones that can't fail. An item assignment not listed may."""
    fresh = {}
    _fresh_locals(node["body"], param_names(node), fresh)
    found = []
    _si_stmts(node["body"], fresh, [], found)
    out = {}
    for e, kind in found:
        if kind == "list":
            name = e["x"]["id"]
            i = _index_written(e["i"])
            lengths = []
            _list_lengths(node["body"], name, lengths)
            if i == None or None in lengths or len([n for n in lengths if i >= n or i < -n]) > 0:
                continue
            if _shrinkable(node["body"], name):
                continue
        out[e["pos"]] = True
    return out

# ---------------------------------------------------------------- escapes
#
# What a value may hold of the None a parameter was given, as a mask: W, it
# may be that None (or a None computed from it: contagious None), I, it may
# have it inside (an element, a field). The analysis runs over a def's body
# with the parameter W (or I), each variable's mask growing until nothing
# changes, and tells whether the None may escape: be stored in a container
# that the def didn't make, given to a function it can't follow (or that
# lets it escape), seen by a nested def or lambda, or assigned to a field;
# and what the def's returned values may hold of it.

W = 1
I = 2

def escapes(cx, node, start):
    """(Does the None that the parameters given in start ({name: mask})
    hold escape def node (a def or lambda)?, the mask of what it returns).
    cx: {resolve(scope, name) -> ("def", node, the scope its free names
    are found in, or None) | ("builtin", name) | ("unknown",), stores: name
    -> positions (infer.star, STORES), scope: the scope node's free names
    are found in, path: its module's, mod_path(scope), memo, busy}."""
    params = param_names(node)
    fresh = {}
    if node["kind"] == "def":
        _fresh_locals(node["body"], params, fresh)
    env = {"t": dict(start), "esc": False, "ret": 0, "fresh": fresh, "cx": cx, "node": node,
           "locals": {}, "changed": False}
    if node["kind"] == "def":
        bound_names(node["body"], env["locals"])
    for p in params:
        env["locals"][p] = True
    for _ in range(20):
        env["changed"] = False
        if node["kind"] == "def":
            _es_stmts(node["body"], env)
        else:
            _es_ret(env, _es_expr(node["body"], env))
        if env["esc"] or not env["changed"]:
            break
    return env["esc"], env["ret"]

def _es_ret(env, m):
    if env["ret"] | m != env["ret"]:
        env["ret"] = env["ret"] | m
        env["changed"] = True

def _es_set(env, name, m):
    old = env["t"].get(name, 0)
    if old | m != old:
        env["t"][name] = old | m
        env["changed"] = True

def _es_store(env, x, m):
    """A value of mask m is stored into container expression x (x.append(v),
    x[k] = v, x += [v], ...): fine in a container the def made (which then
    holds it), else an escape."""
    if m == 0:
        return
    if x["kind"] == "name" and env["fresh"].get(x["id"]) and x["id"] in env["locals"]:
        _es_set(env, x["id"], I)
    else:
        env["esc"] = True

def _es_stmts(stmts, env):
    for s in stmts:
        _es_stmt(s, env)

def _es_stmt(s, env):
    k = s["kind"]
    if k == "expr":
        _es_expr(s["x"], env)
    elif k == "assign":
        m = _es_expr(s["rhs"], env)
        if s["op"] != "=":
            lm = _es_expr(s["lhs"], env)
            m = m | lm
            if s["lhs"]["kind"] == "name" and m & I:
                # (x += [v] extends the list x is, in place)
                _es_store(env, s["lhs"], m & I)
        _es_target(s["lhs"], m, env)
    elif k == "return":
        if s["value"] != None:
            _es_ret(env, _es_expr(s["value"], env))
    elif k == "if":
        _es_expr(s["test"], env)
        _es_stmts(s["body"], env)
        _es_stmts(s["else_"], env)
    elif k == "for":
        m = _es_expr(s["iter"], env)
        _es_target(s["target"], W | I if m & I else 0, env)
        _es_stmts(s["body"], env)
    elif k == "while":
        _es_expr(s["test"], env)
        _es_stmts(s["body"], env)
    elif k == "def":
        for p in s["params"]:
            if p["default"] != None:
                _es_expr(p["default"], env)
        _es_closure(s["body"], env)

def _es_target(e, m, env):
    k = e["kind"]
    if k == "name":
        _es_set(env, e["id"], m)
    elif k == "tuple" or k == "list":
        # (unpacking a None fails: the call gives None; one with a None
        # inside gives it to the variables)
        for x in e["elems"]:
            _es_target(x, W | I if m & I else 0, env)
    elif k == "index":
        _es_expr(e["x"], env)
        km = _es_expr(e["i"], env)
        _es_store(env, e["x"], m | (I if km & W else 0))  # (d[None] = v stores None)
    elif k == "dot":
        _es_expr(e["x"], env)
        if m != 0:
            env["esc"] = True

def _es_closure(x, env):
    """A nested def or lambda that reads a variable that may hold the None
    may keep it: an escape."""
    t = env["t"]
    if len([n for n, m in t.items() if m != 0 and _reads(x, n)]) > 0:
        env["esc"] = True

def _es_expr(e, env):
    if e == None:
        return 0
    k = e["kind"]
    if k == "name":
        return env["t"].get(e["id"], 0) if e["id"] in env["locals"] else 0
    if k in ["int", "float", "string", "bytes"]:
        return 0
    if k == "list" or k == "tuple":
        m = 0
        for x in e["elems"]:
            m = m | _es_expr(x, env)
        return I if m else 0
    if k == "dict":
        m = 0
        for key, val in e["entries"]:
            m = m | _es_expr(key, env) | _es_expr(val, env)
        return I if m else 0
    if k == "unop":
        return W if _es_expr(e["x"], env) & W else 0
    if k == "binop":
        mx = _es_expr(e["x"], env)
        my = _es_expr(e["y"], env)
        op = e["op"]
        if op == "??":
            return (mx & I) | my
        if op == "and" or op == "or":
            return mx | my
        m = mx | my
        if op in ["==", "!=", "<", "<=", ">", ">=", "in", "not in", "%"] and m & I:
            m = m | W  # (comparisons and formatting look inside)
        return m
    if k == "cond":
        return (_es_expr(e["test"], env) & W) | _es_expr(e["then"], env) | _es_expr(e["else_"], env)
    if k == "index":
        mx = _es_expr(e["x"], env)
        mi = _es_expr(e["i"], env)
        return (W if (mx | mi) & W else 0) | (W | I if mx & I else 0)
    if k == "slice":
        mx = _es_expr(e["x"], env)
        mb = 0
        for part in ["lo", "hi", "step"]:
            mb = mb | _es_expr(e[part], env)
        return (W if (mx | mb) & W else 0) | (I if mx & I else 0)
    if k == "dot":
        m = _es_expr(e["x"], env)
        return (W if m & W else 0) | (W | I if m & I else 0)
    if k == "comp":
        return _es_comp(e, env)
    if k == "lambda":
        for p in e["params"]:
            if p["default"] != None:
                _es_expr(p["default"], env)
        _es_closure(e["body"], env)
        return 0
    if k == "call":
        return _es_call(e, env)
    return W | I

def _es_comp(e, env):
    t = env["t"]
    saved = {}
    res = 0
    for c in e["clauses"]:
        if c["kind"] == "for":
            m = _es_expr(c["iter"], env)
            if m & W:
                res = res | W  # (over None: the comprehension is None)
            names = []
            targets(c["target"], names)
            for n in names:
                if n["id"] not in saved:
                    saved[n["id"]] = (t.get(n["id"]), n["id"] in env["locals"])
                t[n["id"]] = W | I if m & I else 0
                env["locals"][n["id"]] = True
        elif _es_expr(c["test"], env) & W:
            res = res | W
    if e["comp"] == "dict":
        m = _es_expr(e["body"][0], env) | _es_expr(e["body"][1], env)
    else:
        m = _es_expr(e["body"], env)
    for name, (old, was_local) in saved.items():
        if old == None:
            t.pop(name)
        else:
            t[name] = old
        if not was_local:
            env["locals"].pop(name)
    return res | (I if m else 0)

def _es_call(e, env):
    cx = env["cx"]
    f = e["fn"]
    args = [(a, _es_expr(a["value"], env)) for a in e["args"]]
    if f["kind"] == "dot":
        # a method: of a builtin type (a struct's field holding a def can't
        # be told apart: taken to be a builtin's)
        rm = _es_expr(f["x"], env)
        name = f["name"]
        res = W if rm & W else 0
        if rm & I:
            res = res | W | I  # (its elements: xs.pop(), d.values(), ...)
        stores = cx["stores"].get(name, ())
        i = 0
        for a, m in args:
            positional = a["name"] == None and a["star"] == ""
            kept = stores == "all" or (positional and i in stores) or (not positional and "kw" in stores)
            if positional:
                i += 1
            if m == 0:
                continue
            if kept:
                _es_store(env, f["x"], m)
                if name in ["get", "pop", "setdefault"]:
                    res = res | m  # (the default, given back)
            elif name in ["extend", "update"] and m & I:
                _es_store(env, f["x"], I)
            else:
                res = res | (W if m & W else 0) | (W | I if m & I else 0)
        return res
    fm = _es_expr(f, env)
    r = ("unknown",)
    if f["kind"] == "name" and f["id"] in env["locals"]:
        # a def nested in this one can be followed (what it reads around
        # it, not: scope None); a parameter or variable, not
        nested = _nested_def(env["node"], f["id"])
        if nested != None:
            r = ("def", nested, None)
    elif f["kind"] == "name":
        r = cx["resolve"](cx["scope"], f["id"])
    if fm & W:
        return W
    tainted = [(a, m) for a, m in args if m != 0]
    if not tainted:
        return 0
    if r[0] == "builtin":
        name = f["id"]
        stores = cx["stores"].get(name, ())
        res = 0
        i = 0
        for a, m in args:
            positional = a["name"] == None and a["star"] == ""
            kept = stores == "all" or (positional and i in stores) or (not positional and "kw" in stores)
            if positional:
                i += 1
            if m == 0:
                continue
            if kept:
                if name == "struct" or name == "dict":
                    res = res | I
                elif name == "getattr":
                    res = res | m
            else:
                res = res | (W if m & W else 0) | (W | I if m & I else 0)
        return res
    if r[0] == "def":
        _, callee, scope = r
        start = {}
        names = [p for p in callee["params"]]
        positional = [p for p in names if p["star"] == "" and p["name"] != None]
        i = 0
        for a, m in args:
            if a["star"] != "":
                if m != 0:
                    env["esc"] = True
                continue
            if a["name"] == None:
                p = positional[i] if i < len(positional) else None
                i += 1
            else:
                p = ([q for q in names if q["name"] == a["name"] and q["star"] == ""] + [None])[0]
            if m == 0:
                continue
            if p == None:
                env["esc"] = True  # (into *args or **kwargs)
                continue
            start[p["name"]] = start.get(p["name"], 0) | m
        if env["esc"]:
            return W | I
        esc, ret = follow(cx, callee, scope, start)
        if esc:
            env["esc"] = True
        return ret
    env["esc"] = True
    return W | I

def _nested_def(node, name):
    """The def statement that binds name in def node's body, if that is
    the name's only binding there."""
    if node["kind"] != "def":
        return None
    found = []
    _defs_named(node["body"], name, found)
    if len(found) != 1 or name in param_names(node):
        return None
    others = []
    _assigned(node["body"], name, others)
    return found[0] if not others else None

def _defs_named(stmts, name, out):
    for s in stmts:
        if s["kind"] == "def" and s["name"] == name:
            out.append(s)
        for key in ["body", "else_"]:
            if s["kind"] != "def" and key in s:
                _defs_named(s[key], name, out)

def _assigned(stmts, name, out):
    """out gets a statement for each binding of name in stmts other than
    by a def."""
    for s in stmts:
        k = s["kind"]
        names = []
        if k == "assign":
            targets(s["lhs"], names)
        elif k == "for":
            targets(s["target"], names)
        if len([n for n in names if n["id"] == name]) > 0:
            out.append(s)
        for key in ["body", "else_"]:
            if k != "def" and key in s:
                _assigned(s[key], name, out)

def follow(cx, node, scope, start):
    """escapes() for a def that the def being looked at calls, memoized;
    a def being looked at already (recursion) is taken not to let the None
    escape (what holds then is checked when the cycle is done: the least
    solution), and to give back what it was given."""
    path = cx["path"] if scope == None else cx["mod_path"](scope)
    key = path + ":" + str(node["pos"]) + "|" + ",".join(sorted([n + "=" + str(m) for n, m in start.items()]))
    if key in cx["memo"]:
        return cx["memo"][key]
    if key in cx["busy"]:
        m = 0
        for v in start.values():
            m = m | v
        return False, m
    cx["busy"][key] = True
    saved = (cx["scope"], cx["path"])
    cx["scope"] = scope
    cx["path"] = path
    out = escapes(cx, node, start)
    cx["scope"], cx["path"] = saved
    cx["busy"].pop(key)
    cx["memo"][key] = out
    return out
