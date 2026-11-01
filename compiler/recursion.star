# recursion.star — starlark-go's Recursion option, checked statically.
#
# starlark-go forbids recursion unless a file has the Recursion option: a
# call of a function that is already active fails at run time with
# "function f called recursively". starwasm checks at compile time
# instead, so compiled code pays nothing: without --recursion, a cycle of
# calls between functions is an error ("function f called recursively", at
# the call that closes the cycle).
#
# Only calls whose callee is known statically count: a call by name of
#   - a top-level def of the module, or one loaded from another module, or
#   - a def nested in an enclosing function, when that def is the only
#     binding of the name there (no parameter, assignment or other def).
# A call through any other value (a variable, a parameter, a lambda, an
# element, a method, a builtin such as sorted calling a key function) adds
# no edge, so recursion through function values is not caught; and a cycle
# is an error even if the call that closes it would never run (both differ
# from starlark-go's run-time check). Lambdas are functions of their own:
# calls in a lambda's body are the lambda's, and nothing calls a lambda
# statically. Top-level code is not a function (it can't be re-entered).

load("resolve.star", "target_names")

def check_recursion(mods, lookup_def, err):
    """mods: the program's modules (dicts with "stmts", "path"), dependencies
    first. lookup_def(mod, name): the key of the top-level def that name
    means at module level in mod (following loads), or None. err(mod, pos,
    msg): report a compile error (does not return)."""
    graph = {}  # function key -> {"name", "calls": [(callee key, pos, mod)]}
    nested = [0]  # nested functions so far (their keys: %nested<n>)
    for mod in mods:
        for s in mod["stmts"]:
            if s["kind"] == "def":
                add_function(graph, nested, mod, lookup_def, s, s["fkey"], [], s["body"], False)
    find_cycle(graph, err)

def bound_once_by_def(params, body):
    """Names bound in a function only by one def statement in its body:
    name -> def node."""
    counts = {}
    defs = {}
    for p in params:
        if p["name"] != None:
            counts[p["name"]] = counts.get(p["name"], 0) + 1
    stack = [body]
    for _ in range(1000000):
        if not stack:
            break
        stmts = stack.pop()
        for s in stmts:
            k = s["kind"]
            names = []
            if k == "assign":
                target_names(s["lhs"], names)
            elif k == "for":
                target_names(s["target"], names)
                stack.append(s["body"])
            elif k == "if":
                stack.append(s["body"])
                stack.append(s["else_"])
            elif k == "while":
                stack.append(s["body"])
            elif k == "def":
                names.append(s["name"])
                defs[s["name"]] = s
            for n in names:
                counts[n] = counts.get(n, 0) + 1
    return {n: d for n, d in defs.items() if counts[n] == 1}

def add_function(graph, nested, mod, lookup_def, node, key, params, body, is_lambda):
    """Add the function `node` (a def, or a lambda when is_lambda) under
    key, and the functions nested in it."""
    ctx = {"mod": mod, "lookup_def": lookup_def, "graph": graph, "nested": nested, "calls": None}
    node["rkey"] = key
    walk_function(ctx, node, body, is_lambda)

def callee(ctx, name, sc):
    """The key of the function a call of `name` in scope sc means
    statically, or None."""
    s = sc
    for _ in range(100000):
        if s == None:
            break
        if s["kind"] == "module":
            return ctx["lookup_def"](ctx["mod"], name)
        if s["bindings"].get(name) != None:
            if s["kind"] != "function":
                return None  # a comprehension variable
            d = s.get("rdefs", {}).get(name)
            if d == None:
                return None  # a parameter or variable
            return d.get("rkey")
        s = s["parent"]
    return None

def walk_stmts(ctx, stmts, sc):
    for s in stmts:
        k = s["kind"]
        if k == "def":
            for p in s["params"]:
                if p["default"] != None:
                    walk_expr(ctx, p["default"], sc)
            nested_function(ctx, s, s["body"], False)
        elif k == "assign":
            walk_expr(ctx, s["rhs"], sc)
            walk_expr(ctx, s["lhs"], sc)
        elif k == "expr":
            walk_expr(ctx, s["x"], sc)
        elif k == "return":
            if s["value"] != None:
                walk_expr(ctx, s["value"], sc)
        elif k == "if" or k == "while":
            walk_expr(ctx, s["test"], sc)
            walk_stmts(ctx, s["body"], sc)
            walk_stmts(ctx, s.get("else_", []), sc)
        elif k == "for":
            walk_expr(ctx, s["iter"], sc)
            walk_expr(ctx, s["target"], sc)
            walk_stmts(ctx, s["body"], sc)

def new_key(ctx):
    ctx["nested"][0] += 1
    return "%nested" + str(ctx["nested"][0])

def nested_function(ctx, node, body, is_lambda):
    if node.get("rkey") == None:
        node["rkey"] = new_key(ctx)
    walk_function(ctx, node, body, is_lambda)

def walk_function(ctx, node, body, is_lambda):
    """Add the graph node for function `node` (key node["rkey"]) and walk
    its body. Its nested defs that are the only binding of their name get
    keys first (node["scope"]["rdefs"]: name -> def), so a call of one
    defined further down still counts."""
    sub = dict(ctx)
    sub["calls"] = []
    ctx["graph"][node["rkey"]] = {"name": node.get("name", "lambda"), "calls": sub["calls"]}
    if is_lambda:
        walk_expr(sub, body, node["scope"])
        return
    defs = bound_once_by_def(node["params"], body)
    for d in defs.values():
        if d.get("rkey") == None:
            d["rkey"] = new_key(ctx)
    node["scope"]["rdefs"] = defs
    walk_stmts(sub, body, node["scope"])

def walk_expr(ctx, e, sc):
    stack = [(e, sc)]
    for _ in range(10000000):
        if not stack:
            break
        e, sc = stack.pop()
        if e == None:
            continue
        k = e["kind"]
        if k == "call":
            if e["fn"]["kind"] == "name":
                c = callee(ctx, e["fn"]["id"], sc)
                if c != None:
                    ctx["calls"].append((c, e["pos"], ctx["mod"]))
            stack.append((e["fn"], sc))
            for a in e["args"]:
                stack.append((a["value"], sc))
        elif k == "list" or k == "tuple":
            for x in e["elems"]:
                stack.append((x, sc))
        elif k == "dict":
            for key, val in e["entries"]:
                stack.append((key, sc))
                stack.append((val, sc))
        elif k == "binop":
            stack.append((e["x"], sc))
            stack.append((e["y"], sc))
        elif k == "unop":
            stack.append((e["x"], sc))
        elif k == "cond":
            stack.append((e["test"], sc))
            stack.append((e["then"], sc))
            stack.append((e["else_"], sc))
        elif k == "index":
            stack.append((e["x"], sc))
            stack.append((e["i"], sc))
        elif k == "slice":
            for part in [e["x"], e["lo"], e["hi"], e["step"]]:
                stack.append((part, sc))
        elif k == "dot":
            stack.append((e["x"], sc))
        elif k == "lambda":
            for p in e["params"]:
                if p["default"] != None:
                    stack.append((p["default"], sc))
            nested_function(ctx, e, e["body"], True)
        elif k == "comp":
            cs = e["scope"]
            first = True
            for c in e["clauses"]:
                if c["kind"] == "for":
                    stack.append((c["iter"], sc if first else cs))
                    first = False
                else:
                    stack.append((c["test"], cs))
            if e["comp"] == "dict":
                stack.append((e["body"][0], cs))
                stack.append((e["body"][1], cs))
            else:
                stack.append((e["body"], cs))

def find_cycle(graph, err):
    """Depth-first search; at the first edge back to a function on the
    current path, report the call."""
    state = {}  # key -> 1 on the path, 2 done
    for root in graph.keys():
        if state.get(root) != None:
            continue
        state[root] = 1
        path = [(root, 0)]
        for _ in range(100000000):
            if not path:
                break
            key, i = path[-1]
            calls = graph[key]["calls"]
            if i == len(calls):
                state[key] = 2
                path.pop()
                continue
            path[-1] = (key, i + 1)
            c, posn, mod = calls[i]
            if graph.get(c) == None:
                continue  # a def outside the program's modules (the prelude)
            st = state.get(c)
            if st == 1:
                err(mod, posn, "function " + graph[c]["name"] + " called recursively")
            if st == None:
                state[c] = 1
                path.append((c, 0))
