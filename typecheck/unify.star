# unify.star — unification, the constraints that wait for a type to be
# known, attribute lookup, and generalization.
#
# Unification of types, rows and labels follows Fig. 10 of "Infix-Extensible
# Record Types for Tabular Data" (Paszke & Xie, TyDe '23): see unify_rows.
#
# Everything here takes st, the checker's state:
#   next      counter for variable ids
#   errors    the diagnostics so far: {file, pos, msg, notes: [{file, pos, msg}]}
#   seen      their keys, to report each only once
#   pending   operator constraints not yet solved (see default_pending)
#   methods   builtin methods: type name -> method name -> type scheme of
#             the method as a function of the receiver (typecheck/builtins.star)
#   owners    method name -> the builtin types that have it
#
# A ctx says what is being checked, for messages: {file, pos, role}, where
# role describes the value at pos ("argument 'n' of f()").
#
# unify and flow return None, or a failure {a, b, msg, notes, ...} that the
# caller turns into a diagnostic (unify_report, flow_report). Constraints
# solved later report their own failures.

load(
    "types.star",
    "GENERIC",
    "T_ANY",
    "con",
    "describe_pred",
    "field",
    "flatten",
    "fn",
    "is_con",
    "lab",
    "lit",
    "mk_opt",
    "new_namer",
    "new_var",
    "origin_of",
    "param",
    "rec",
    "resolve",
    "resolve_label",
    "row",
    "show",
    "show_label",
)
load("../compiler/spell.star", "nearest")

# ---------------------------------------------------------------- diagnostics

def report(st, ctx, msg, notes = []):
    key = ctx["file"] + ":" + str(ctx["pos"][0]) + ":" + str(ctx["pos"][1]) + ":" + msg
    if key in st["seen"]:
        return
    st["seen"][key] = True
    st["errors"].append({"file": ctx["file"], "pos": ctx["pos"], "msg": msg, "notes": notes})

def note_at(origin, msg):
    return {"file": origin["file"], "pos": origin["pos"], "msg": msg}

def _same_place(a, b):
    return a["file"] == b["file"] and a["pos"] == b["pos"]

def _origin_note(ctx, t, text, shown):
    """A note pointing at where t comes from, unless that is where the
    error is anyway."""
    o = origin_of(t)
    if o == None or _same_place(o, ctx):
        return []
    role = o.get("role")
    return [note_at(o, shown + " " + text + (" (" + role + ")" if role else ""))]

def failure(a, b, msg = None, notes = None):
    return {"a": a, "b": b, "msg": msg, "notes": notes or []}

def hint(name, candidates):
    """ (did you mean X?), or ""."""
    n = nearest(name, candidates)
    return " (did you mean '" + n + "'?)" if n != "" else ""

def describe_failure(st, ctx, actual, expected, err, flowing):
    """The message and notes for a failure to make `actual` and `expected`
    the same type (flowing: to use actual where expected is wanted)."""
    nm = new_namer(False)
    a = show(actual, nm)
    e = show(expected, nm)
    role = ctx.get("role") or "type mismatch"
    notes = list(err["notes"])
    if "field" in err:
        # a struct lacks a field the other has
        lacking = "a" if err["missing_in"] == "a" else "b"
        if flowing and lacking == "b":
            what = "unexpected field '" + err["field"] + "'"
        else:
            what = "no field '" + err["field"] + "'" + hint(err["field"], err["have"])
        msg = role + ": expected " + e + ", got " + a + ": " + what
        if not flowing:
            msg = role + ": " + a + " vs " + e + ": only one has a field '" + err["field"] + "'" + hint(err["field"], err["have"])
        if err.get("at") != None and not _same_place(err["at"], ctx):
            r = err["at"].get("role")
            notes.append(note_at(err["at"], "field '" + err["field"] + "' comes from here" + (" (" + r + ")" if r else "")))
        return msg, notes
    if flowing:
        msg = role + ": expected " + e + ", got " + a
    else:
        msg = role + ": " + a + " vs " + e
    ia = show(err["a"], nm)
    ib = show(err["b"], nm)
    if err["msg"] != None:
        msg += ": " + err["msg"]
    elif ia != a or ib != e:
        msg += " (" + ia + " vs " + ib + ")"
    notes += _origin_note(ctx, err["b"], "is expected because of this" if flowing else "comes from here", ib)
    for n in _origin_note(ctx, err["a"], "comes from here", ia):
        if n["file"] != ctx["file"] or n["pos"][0] != ctx["pos"][0]:
            notes.append(n)
    return msg, notes

def unify_report(st, a, b, ctx):
    """Unify; report a failure at ctx. Returns whether it worked."""
    err = unify(st, a, b, ctx)
    if err != None:
        msg, notes = describe_failure(st, ctx, a, b, err, False)
        report(st, ctx, msg, notes)
        return False
    return True

def flow_report(st, actual, expected, ctx):
    err = flow(st, actual, expected, ctx)
    if err != None:
        msg, notes = describe_failure(st, ctx, actual, expected, err, True)
        report(st, ctx, msg, notes)
        return False
    return True

# ---------------------------------------------------------------- variables

def lower(st, t, v):
    """Before v is solved to t: every variable of t now lives at least as
    long as v (levels), and v must not be among them (the occurs check;
    returns False if it is)."""
    t = resolve(t) if t["k"] != "row" else t
    k = t["k"]
    if k == "var":
        if t["id"] == v["id"]:
            return False
        if t["level"] > v["level"] and t["level"] != GENERIC:
            t["level"] = v["level"]
            for p in t["preds"]:
                for x in _pred_types(p):
                    if not lower(st, x, v):
                        return False
        return True
    if k == "con":
        for a in t["args"]:
            if not lower(st, a, v):
                return False
    elif k == "fn":
        for p in t["params"]:
            if not lower(st, p["type"], v):
                return False
        return lower(st, t["ret"], v)
    elif k == "rec":
        return lower(st, t["row"], v)
    elif k == "row":
        for it in flatten(t):
            if it["k"] == "f":
                if not lower(st, resolve_label(it["label"]), v) or not lower(st, it["type"], v):
                    return False
            elif not lower(st, it, v):
                return False
    elif k == "lab":
        return lower(st, resolve_label(t["label"]), v)
    return True

def _pred_types(p):
    if p["kind"] == "binop" or p["kind"] == "rbinop":
        return [p["l"], p["r"], p["res"]]
    return [p["subj"]] + p["args"]

def bind(st, v, t, ctx):
    """Solve the unsolved variable v (of any kind) to t, then wake the
    constraints that were waiting for it."""
    if not lower(st, t, v):
        if v["kind"] != "type" or v["lit"] != None or v["num"]:
            return failure(v, t, "the type would contain itself")
        # a recursive type (a tree's nodes hold nodes): there are none, so
        # where the type would contain itself it is Any
        t = con("Any", [], ctx)
    v["ref"] = t
    v["at"] = ctx
    preds = v["preds"]
    v["preds"] = []
    for p in preds:
        add_pred(st, p, ctx)
    return None

def attach(st, v, p):
    """Make constraint p wait for variable v."""
    if "id" not in p:
        st["next"] += 1
        p["id"] = st["next"]
    if p["kind"] in MERGED:
        # a second constraint of the same kind says the same of v
        for q in v["preds"]:
            if q["kind"] == p["kind"] and q["op"] == p["op"]:
                for i in range(len(p["args"])):
                    unify_report(st, p["args"][i], q["args"][i], p["ctx"])
                return
    v["preds"].append(p)
    for x in _pred_types(p):
        lower(st, x, v)
    if p["kind"] == "binop" or p["kind"] == "rbinop":
        st["pending"].append(p)

MERGED = {"iter": True, "contains": True, "sized": True, "ordered": True, "slice": True, "hasattr": True}

def head(st, t):
    """t resolved, for code about to look at what kind of type it is: a
    string literal's type is str here, and so is a field name's."""
    t = resolve(t)
    if t["k"] == "var" and t["num"]:
        s = con("int", [], t["at"])
        t["ref"] = s
        return s
    return _nhead(t)

def _nhead(t):
    """As head, but an int literal's type stays as it is."""
    if t["k"] == "var" and t["lit"] != None:
        s = con("str", [], t["at"])
        t["ref"] = s
        return s
    if t["k"] == "lab":
        return con("str", [], t.get("at"))
    return t

def _is_num(t):
    return t["k"] == "var" and t["num"]

# ---------------------------------------------------------------- unification

def unify(st, a0, b0, ctx):
    a = resolve(a0)
    b = resolve(b0)
    ak = a["k"]
    bk = b["k"]
    if ak == "var" and bk == "var":
        if a["id"] == b["id"]:
            return None
        if a["rigid"] and b["rigid"]:
            return failure(a0, b0, "they are different type parameters")
        if a["rigid"]:
            return _bind_var(st, b, a, a0, b0, ctx)
        if b["rigid"]:
            return _bind_var(st, a, b, a0, b0, ctx)
        if a["lit"] != None and b["lit"] != None and a["lit"] != b["lit"]:
            # two different string literals: both are just str
            s = con("str", [], origin_of(a0))
            bind(st, a, s, ctx)
            return bind(st, b, s, ctx)
        if (a["num"] and b["lit"] != None) or (b["num"] and a["lit"] != None):
            return failure(a0, b0)
        if a["lit"] != None or a["num"]:
            return bind(st, b, a, ctx)
        return bind(st, a, b, ctx)
    if ak == "var":
        return _bind_var(st, a, b, a0, b0, ctx)
    if bk == "var":
        return _bind_var(st, b, a, a0, b0, ctx)
    if ak == "con" and a["name"] == "Any" or bk == "con" and b["name"] == "Any":
        return None
    if ak == "con" and bk == "con":
        an = a["name"]
        bn = b["name"]
        if an == bn and len(a["args"]) == len(b["args"]):
            for i in range(len(a["args"])):
                err = unify(st, a["args"][i], b["args"][i], ctx)
                if err != None:
                    return err
            return None
        if an == "tuple" and bn == "vtuple" or an == "vtuple" and bn == "tuple":
            t, v = (a, b) if an == "tuple" else (b, a)
            for x in t["args"]:
                err = unify(st, x, v["args"][0], ctx) if an == "tuple" else unify(st, v["args"][0], x, ctx)
                if err != None:
                    return err
            return None
        if an == "opt" or bn == "opt":
            if an == "None" or bn == "None":
                return None
            return failure(a0, b0, "only one of them may be None")
        if an == "tuple" and bn == "tuple":
            return failure(a0, b0, "tuples of " + str(len(a["args"])) + " and " + str(len(b["args"])) + " elements")
        return failure(a0, b0)
    if ak == "lab" and bk == "lab":
        return unify_label(st, a["label"], b["label"], a0, b0, ctx)
    if ak == "lab" and is_con(b, "str") or bk == "lab" and is_con(a, "str"):
        l = resolve_label(a["label"] if ak == "lab" else b["label"])
        if l["k"] == "lit":
            return None  # a field name is a string
        return failure(a0, b0, "any string is not a field name: a string literal is needed")
    if ak == "rec" and bk == "rec":
        return unify_rows(st, a["row"], b["row"], ctx)
    if ak == "fn" and bk == "fn":
        return unify_fn(st, a, b, a0, b0, ctx)
    return failure(a0, b0)

def _bind_var(st, v, t, a0, b0, ctx):
    """Unify the unsolved variable v with t (a rigid variable, or not a
    variable); a0, b0: the types being unified, for the failure."""
    if v["rigid"]:
        if t["k"] == "con" and t["name"] == "Any":
            return None
        return failure(a0, b0, "'" + (v["name"] or "?") + "' is a type parameter: it stands for any type")
    if v["kind"] != "type":
        return failure(a0, b0)
    if v["num"]:
        if is_con(t, "int") or is_con(t, "float"):
            return bind(st, v, t, ctx)
        if is_con(t, "Any"):
            return None
        return failure(a0, b0)
    if v["lit"] != None:
        if t["k"] == "lab":
            err = unify_label(st, t["label"], lit(v["lit"]), a0, b0, ctx)
            if err != None:
                return err
            return bind(st, v, t, ctx)
        if is_con(t, "str"):
            return bind(st, v, t, ctx)
        if is_con(t, "Any"):
            return None
        if t["k"] == "var":  # a rigid variable
            return failure(a0, b0, "'" + (t["name"] or "?") + "' is a type parameter: it stands for any type")
        return failure(a0, b0)
    return bind(st, v, t, ctx)

def unify_label(st, a, b, a0, b0, ctx):
    a = resolve_label(a)
    b = resolve_label(b)
    if a["k"] == "lit" and b["k"] == "lit":
        if a["name"] == b["name"]:
            return None
        return failure(a0, b0, "field names '" + a["name"] + "' and '" + b["name"] + "'")
    if a["k"] == "var" and b["k"] == "var":
        if a["id"] == b["id"]:
            return None
        if a["rigid"] and b["rigid"]:
            return failure(a0, b0, "they are different field name parameters")
        if a["rigid"]:
            return bind(st, b, a, ctx)
        return bind(st, a, b, ctx)
    v, l = (a, b) if a["k"] == "var" else (b, a)
    if v["rigid"]:
        return failure(a0, b0, "'" + (v["name"] or "?") + "' is a type parameter: it stands for any field name")
    return bind(st, v, l, ctx)

def unify_fn(st, a, b, a0, b0, ctx):
    pa = [p for p in a["params"] if p["star"] == "" and not p["kw"]]
    pb = [p for p in b["params"] if p["star"] == "" and not p["kw"]]
    n = min(len(pa), len(pb))
    for i in range(n):
        err = unify(st, pa[i]["type"], pb[i]["type"], ctx)
        if err != None:
            return err
    sa = [p for p in a["params"] if p["star"] == "*"]
    sb = [p for p in b["params"] if p["star"] == "*"]
    for longer, shorter_star in [(pa, sb), (pb, sa)]:
        for p in longer[n:]:
            if not p["opt"] and not shorter_star:
                return failure(a0, b0, "functions of " + str(len(pa)) + " and " + str(len(pb)) + " parameters")
    if sa and sb:
        err = unify(st, sa[0]["type"], sb[0]["type"], ctx)
        if err != None:
            return err
    ka = {p["name"]: p for p in a["params"] if p["kw"] or p["star"] == "**"}
    kb = {p["name"]: p for p in b["params"] if p["kw"] or p["star"] == "**"}
    for name, p in ka.items():
        q = kb.get(name)
        if q != None and q["star"] == p["star"]:
            err = unify(st, p["type"], q["type"], ctx)
            if err != None:
                return err
    return unify(st, a["ret"], b["ret"], ctx)

# ---------------------------------------------------------------- rows
#
# Rows are equal up to: associativity of concatenation, the empty row as
# its unit, and swapping two adjacent fields with *different literal*
# labels (the paper's Fig. 3). A field never moves across a row variable,
# a field whose label is a variable, or a field of the same label (scoped
# labels: the first of two fields with one label shadows the other).

def _lit_name(it):
    """The label of a field item if it is a literal, else None."""
    if it["k"] != "f":
        return None
    l = resolve_label(it["label"])
    return l["name"] if l["k"] == "lit" else None

def _same_item(x, y):
    """Are x and y items that must be unified with each other when both
    are first (or both last) in their rows? Equal row variables, or fields
    with the same label."""
    if x["k"] == "var" or y["k"] == "var":
        return x["k"] == "var" and y["k"] == "var" and x["id"] == y["id"]
    lx = resolve_label(x["label"])
    ly = resolve_label(y["label"])
    if lx["k"] == "lit" and ly["k"] == "lit":
        return lx["name"] == ly["name"]
    return lx["k"] == "var" and ly["k"] == "var" and lx["id"] == ly["id"]

def _occurs_in(v, items):
    for it in items:
        if it["k"] == "var" and it["id"] == v["id"]:
            return True
    return False

def _lookup(items, name, others, backwards):
    """The paper's lookup judgment: find the field `name` that row `items`
    must have first (last, if backwards) once fields are reordered.
    Returns (status, index, blocker):
      "found"   items[index] is the field
      "extend"  the row variable items[index] must provide it (LUtail)
      "missing" the row has no such field and cannot grow one
      "stuck"   it depends on how the variable `blocker` is solved
      "loop"    it would take a row that contains itself (the side condition
                of Rfield: the variable is also in `others`, the rest of the
                other row)"""
    n = len(items)
    order = range(n - 1, -1, -1) if backwards else range(n)
    for j in order:
        it = items[j]
        if it["k"] == "f":
            l = resolve_label(it["label"])
            if l["k"] != "lit":
                return ("stuck", j, l)
            if l["name"] == name:
                return ("found", j, None)
            continue
        # a row variable: it provides the field if nothing beyond it can
        # (the paper's LUtail is the case where nothing is beyond it)
        rest = items[:j] if backwards else items[j + 1:]
        for r in rest:
            if r["k"] == "var":
                return ("stuck", j, it)
            rl = resolve_label(r["label"])
            if rl["k"] != "lit":
                return ("stuck", j, rl)
            if rl["name"] == name:
                return ("stuck", j, it)
        if it["rigid"]:
            return ("missing", j, None)
        if _occurs_in(it, others):
            return ("loop", j, it)
        return ("extend", j, None)
    return ("missing", -1, None)

def _field_names(items):
    return [n for n in [_lit_name(it) for it in items] if n != None]

def unify_rows(st, r1, r2, ctx, flowing = False):
    """Make rows r1 and r2 equal. flowing: a struct with row r1 is used
    where one with r2 is wanted, so (structs being immutable) a field of
    r1 need only flow into the field of r2."""
    same = flow if flowing else unify
    a = flatten(r1)
    b = flatten(r2)
    all_a = _field_names(a)
    all_b = _field_names(b)

    # a row with nothing unknown must have every field the other names:
    # said before anything is solved, so that the types read well
    for x, y, x_is_a in [(a, b, True), (b, a, False)]:
        if len(_field_names(x)) != len(x):
            continue
        have = all_a if x_is_a else all_b
        for it in y:
            name = _lit_name(it)
            if name != None and name not in have:
                err = failure(rec(r1), rec(r2))
                err["field"] = name
                err["missing_in"] = "a" if x_is_a else "b"
                err["have"] = have
                err["at"] = it.get("at")
                return err
    for _ in range(1 << 30):
        # the same item at the same end of both rows: unify and drop it
        if a and b and _same_item(a[0], b[0]):
            if a[0]["k"] == "f":
                err = same(st, a[0]["type"], b[0]["type"], ctx)
                if err != None:
                    return err
            a = a[1:]
            b = b[1:]
            continue
        if a and b and _same_item(a[-1], b[-1]):
            if a[-1]["k"] == "f":
                err = same(st, a[-1]["type"], b[-1]["type"], ctx)
                if err != None:
                    return err
            a = a[:-1]
            b = b[:-1]
            continue
        if not a and not b:
            return None

        # a row variable against a whole row (Rsolve)
        done = False
        for x, y, x_is_a in [(a, b, True), (b, a, False)]:
            if len(x) == 1 and x[0]["k"] == "var" and not x[0]["rigid"]:
                if _occurs_in(x[0], y):
                    return failure(rec(r1), rec(r2), "a struct type would contain itself")
                err = bind(st, x[0], row(y), ctx)
                if err != None:
                    return err
                done = True
                break
        if done:
            return None

        # one row is used up: the other must be empty too
        if not a or not b:
            rest = b if not a else a
            for it in rest:
                if it["k"] == "f" or it["rigid"]:
                    name = show_label(it["label"], new_namer(False)) if it["k"] == "f" else "**" + (it["name"] or "?")
                    err = failure(rec(r1), rec(r2))
                    err["field"] = name
                    err["missing_in"] = "a" if not a else "b"
                    err["have"] = all_a if not a else all_b
                    err["at"] = it.get("at")
                    return err
            for it in rest:
                if it["ref"] == None:
                    bind(st, it, row([]), ctx)
            return None

        # a field with a literal label at an end of one row: look it up in
        # the other row (Rfield), from the same end
        progress = False
        blocker = None
        for x, y, x_is_a, backwards in [(a, b, True, False), (b, a, False, False), (a, b, True, True), (b, a, False, True)]:
            f = x[-1] if backwards else x[0]
            name = _lit_name(f)
            if name == None:
                continue
            others = x[:-1] if backwards else x[1:]
            status, j, blk = _lookup(y, name, others, backwards)
            if status == "stuck":
                if blocker == None:
                    blocker = blk
                continue
            if status == "missing":
                err = failure(rec(r1), rec(r2))
                err["field"] = name
                err["missing_in"] = "b" if x_is_a else "a"
                err["have"] = all_b if x_is_a else all_a
                err["at"] = f.get("at")
                return err
            if status == "loop":
                return failure(rec(r1), rec(r2), "a struct type would contain itself")
            if status == "found":
                err = same(st, f["type"], y[j]["type"], ctx) if x_is_a else same(st, y[j]["type"], f["type"], ctx)
                if err != None:
                    return err
                y2 = y[:j] + y[j + 1:]
            else:  # extend: the row variable y[j] is (name: type | fresh)
                fresh = new_var(st, "row", y[j]["level"])
                nf = field(lit(name), f["type"], f.get("at"))
                err = bind(st, y[j], row([fresh, nf] if backwards else [nf, fresh]), ctx)
                if err != None:
                    return err
                y2 = y[:j] + [fresh] + y[j + 1:]
            # solving a variable may have changed both rows: flatten again
            x2 = flatten(row(others))
            y2 = flatten(row(y2))
            a, b = (x2, y2) if x_is_a else (y2, x2)
            progress = True
            break
        if progress:
            continue

        # neither end of either row can be matched until a variable is
        # solved (e.g. (L: int | R) against (x: int, y: int), where the
        # field name L is not known yet): wait for it
        if blocker == None:
            for it in a + b:
                if it["k"] == "var" and not it["rigid"]:
                    blocker = it
                    break
                if it["k"] == "f":
                    l = resolve_label(it["label"])
                    if l["k"] == "var" and not l["rigid"]:
                        blocker = l
                        break
        if blocker == None or blocker["rigid"]:
            return failure(rec(r1), rec(r2), "it is not known whether their fields line up (they depend on type parameters)")
        attach(st, blocker, {"kind": "rows", "subj": blocker, "args": [rec(row(a)), rec(row(b))], "op": flowing, "ctx": ctx})
        return None
    return None

# ---------------------------------------------------------------- flow, join

def flow(st, actual, expected, ctx):
    """A value of type `actual` is used where `expected` is wanted: as
    unify, except that a T is fine where T | None is wanted, an int where a
    float is, and tuples are compared element by element."""
    a = resolve(actual)
    e = resolve(expected)
    if is_con(e, "Any"):
        return None  # used as Any: nothing is learned about the value
    if is_con(a, "Any"):
        if e["k"] == "var" and not e["rigid"] and e["lit"] == None and not e["num"]:
            return bind(st, e, a, ctx)
        return None
    if is_con(e, "opt"):
        if is_con(a, "None"):
            return None
        if is_con(a, "opt"):
            return flow(st, a["args"][0], e["args"][0], ctx)
        return flow(st, a, e["args"][0], ctx)
    if is_con(a, "opt"):
        if e["k"] == "var" and not e["rigid"]:
            return bind(st, e, a, ctx)
        return failure(actual, expected, "the value may be None")
    if (is_con(a, "int") or _is_num(a)) and is_con(e, "float"):
        return None  # (an int literal stays an int when used as a float)
    if is_con(a, "tuple") and is_con(e, "tuple") and len(a["args"]) == len(e["args"]):
        for i in range(len(a["args"])):
            err = flow(st, a["args"][i], e["args"][i], ctx)
            if err != None:
                return err
        return None
    if a["k"] == "lab" and is_con(e, "str"):
        return None
    if a["k"] == "rec" and e["k"] == "rec":
        return unify_rows(st, a["row"], e["row"], ctx, True)
    return unify(st, actual, expected, ctx)

def join(st, a, b, ctx):
    """The type of a value that is either an `a` or a `b` (the branches of
    a conditional, the elements of a list): None joins T as T | None, int
    joins float as float, anything else must unify."""
    ra = resolve(a)
    rb = resolve(b)
    an = is_con(ra, "None")
    bn = is_con(rb, "None")
    if an and bn:
        return ra
    if an:
        return mk_opt(b)
    if bn:
        return mk_opt(a)
    if is_con(ra, "opt") or is_con(rb, "opt"):
        x = ra["args"][0] if is_con(ra, "opt") else ra
        y = rb["args"][0] if is_con(rb, "opt") else rb
        return mk_opt(join(st, x, y, ctx))
    if is_con(ra, "int") and is_con(rb, "float"):
        return rb
    if is_con(ra, "float") and is_con(rb, "int"):
        return ra
    if is_con(ra, "Any"):
        return ra
    if is_con(rb, "Any"):
        return rb
    if is_con(ra, "tuple") and is_con(rb, "tuple") and len(ra["args"]) == len(rb["args"]):
        return con("tuple", [join(st, ra["args"][i], rb["args"][i], ctx) for i in range(len(ra["args"]))], ra["at"])
    if ra["k"] == "rec" and rb["k"] == "rec":
        # structs are immutable: join field by field when both list the
        # same fields
        fa = flatten(ra["row"])
        fb = flatten(rb["row"])
        na = _field_names(fa)
        if len(na) == len(fa) and sorted(na) == sorted(_field_names(fb)) and len(fb) == len(fa) and len({n: 1 for n in na}) == len(na):
            tb = {_lit_name(it): it["type"] for it in fb}
            return rec(row([field(it["label"], join(st, it["type"], tb[_lit_name(it)], ctx), it.get("at")) for it in fa]), ra["at"])
    if not unify_report(st, a, b, ctx):
        return T_ANY
    return a

# ---------------------------------------------------------------- constraints
#
# A constraint (pred) waits on a variable until it is solved:
#   {kind, subj, args, op, ctx}
#     iter      subj is iterable, with elements args[0]
#     getitem   subj[args[0]] is an args[1]
#     setitem   subj[args[0]] = an args[1]
#     sized     len(subj)
#     contains  args[0] in subj
#     slice     subj[i:j] is an args[0]
#     ordered   subj < subj
#     among     subj is one of the types named in op
#     hasattr   subj.<op> is an args[0]  (for the names of builtin methods)
#     rows      the rows of the records args[0] and args[1] are equal: they
#               could not be unified until subj (a row or label variable)
#               is solved
#   {kind: "binop" | "rbinop", op, l, r, res, subj, args, ctx}
#     l <op> r is a res; it waits on l (binop: subj = l, args = [r, res]) or,
#     when l is known, on r (rbinop: subj = r, args = [l, res])
#
# A def generalizes the constraints on its quantified variables with them:
# they are the variables' bounds ("X: Iterable[T]"), checked where the def
# is used.

def pred(kind, subj, args, ctx, op = None):
    return {"kind": kind, "subj": subj, "args": args, "op": op, "ctx": ctx}

def binop_pred(op, l, r, res, ctx):
    return {"kind": "binop", "op": op, "l": l, "r": r, "res": res, "subj": l, "args": [r, res], "ctx": ctx}

def add_pred(st, p, ctx):
    """Solve constraint p now if its subject is known, else make it wait.
    ctx: what is being checked now (p["ctx"]: where p comes from)."""
    k = p["kind"]
    if k == "binop" or k == "rbinop":
        solve_binop(st, p, ctx)
        return
    if k == "rows":
        err = unify_rows(st, p["args"][0]["row"], p["args"][1]["row"], p["ctx"], p["op"])
        if err != None:
            c = p["ctx"]
            extra = []
            if not _same_place(c, ctx) and ctx.get("role"):
                r = c.get("role")
                extra = [note_at(c, "required here" + (" (" + r + ")" if r else ""))]
                c = ctx
            msg, notes = describe_failure(st, c, p["args"][0], p["args"][1], err, p["op"])
            report(st, c, msg, extra + notes)
        return
    s = head(st, p["subj"])
    if s["k"] == "var":
        if s["rigid"]:
            _rigid_pred(st, s, p, ctx)
        else:
            attach(st, s, p)
        return
    dispatch(st, s, p, ctx)

def _pred_error(st, p, ctx, msg):
    """A constraint failed while checking ctx."""
    notes = []
    if not _same_place(p["ctx"], ctx):
        r = p["ctx"].get("role")
        notes.append(note_at(p["ctx"], "required here" + (" (" + r + ")" if r else "")))
        role = ctx.get("role")
        if role:
            msg = role + ": " + msg
    report(st, ctx, msg, notes)

def _rigid_pred(st, v, p, ctx):
    """Constraint p on a type parameter of an annotation: it must be one
    of the parameter's declared bounds."""
    for q in v["preds"]:
        if q["kind"] != p["kind"]:
            if not (q["kind"] == "among" and p["kind"] == "ordered"):
                continue
            if len([n for n in q["op"] if n not in ORDERED]) == 0:
                return
            continue
        if p["kind"] == "among":
            if len([n for n in q["op"] if n not in p["op"]]) == 0:
                return
            continue
        if q["op"] != p["op"] and p["kind"] != "getitem":
            continue
        pa = [p["r"], p["res"]] if p["kind"] == "binop" else ([p["l"], p["res"]] if p["kind"] == "rbinop" else p["args"])
        for i in range(len(pa)):
            unify_report(st, pa[i], q["args"][i], p["ctx"])
        return
    name = v["name"] or "?"
    _pred_error(st, p, ctx, "type parameter '" + name + "' stands for any type, but must be " + describe_pred(p) +
                            " here (give it a bound, or a more specific type)")

ORDERED = {"int": True, "float": True, "str": True, "bytes": True, "bool": True, "list": True, "tuple": True, "vtuple": True, "set": True}

def _check(st, p, ctx, actual, expected, role, flowing):
    """A step of solving constraint p while checking ctx: `actual` flows
    into (or is) `expected`. A failure is reported at ctx (with a note at
    p's origin if that is elsewhere)."""
    pctx = p["ctx"]
    err = flow(st, actual, expected, pctx) if flowing else unify(st, actual, expected, pctx)
    if err == None:
        return True
    r = role or pctx.get("role")
    if _same_place(pctx, ctx):
        c = _role(pctx, r)
        msg, notes = describe_failure(st, c, actual, expected, err, flowing)
    else:
        c = ctx
        msg, notes = describe_failure(st, c, actual, expected, err, flowing)
        notes = [note_at(pctx, "required here" + (" (" + r + ")" if r else ""))] + notes
    report(st, c, msg, notes)
    return False

def dispatch(st, s, p, ctx):
    """Solve constraint p, whose subject is now known to be s."""
    k = p["kind"]
    pctx = p["ctx"]
    name = s["name"] if s["k"] == "con" else s["k"]
    args = p["args"]
    if name == "Any":
        return
    if name == "opt" and k != "among":
        _pred_error(st, p, ctx, "the value may be None (it is " + show(s) + "): test it against None first")
        return
    if k == "iter":
        if name == "list" or name == "set" or name == "vtuple" or name == "dict":
            _check(st, p, ctx, s["args"][0], args[0], None, True)
        elif name == "tuple":
            for x in s["args"]:
                if flow(st, x, args[0], pctx) != None:
                    break  # mixed element types: the loop variable is not checked
        elif name == "range":
            _check(st, p, ctx, con("int"), args[0], None, True)
        elif name == "str":
            _pred_error(st, p, ctx, "str is not iterable (use .elems() or .codepoints())")
        elif name == "bytes":
            _pred_error(st, p, ctx, "bytes is not iterable (use .elems())")
        else:
            _pred_error(st, p, ctx, show(s) + " is not iterable")
    elif k == "getitem":
        if name == "list" or name == "vtuple":
            _check(st, p, ctx, args[0], con("int"), "index of " + show(s), True)
            _check(st, p, ctx, s["args"][0], args[1], None, True)
        elif name == "tuple":
            _check(st, p, ctx, args[0], con("int"), "index of " + show(s), True)
            i = p["op"]  # the index, if it is an int literal
            if i != None and i < len(s["args"]) and i >= -len(s["args"]):
                _check(st, p, ctx, s["args"][i], args[1], None, True)
            elif i != None:
                _pred_error(st, p, ctx, "index " + str(i) + " is out of range for " + show(s))
            else:
                for x in s["args"]:
                    if flow(st, x, args[1], pctx) != None:
                        break
        elif name == "dict":
            _check(st, p, ctx, args[0], s["args"][0], "dict key", True)
            _check(st, p, ctx, s["args"][1], args[1], None, True)
        elif name == "str":
            _check(st, p, ctx, args[0], con("int"), "index of " + show(s), True)
            _check(st, p, ctx, con("str"), args[1], None, True)
        elif name == "bytes" or name == "range":
            _check(st, p, ctx, args[0], con("int"), "index of " + show(s), True)
            _check(st, p, ctx, con("int"), args[1], None, True)
        elif name == "rec":
            _pred_error(st, p, ctx, "a struct is not indexable: use .name, or getattr(x, \"name\")")
        else:
            _pred_error(st, p, ctx, show(s) + " is not indexable")
    elif k == "setitem":
        if name == "list":
            _check(st, p, ctx, args[0], con("int"), "index of " + show(s), True)
            _check(st, p, ctx, args[1], s["args"][0], "list element", True)
        elif name == "dict":
            _check(st, p, ctx, args[0], s["args"][0], "dict key", True)
            _check(st, p, ctx, args[1], s["args"][1], "dict value", True)
        else:
            _pred_error(st, p, ctx, show(s) + " does not support item assignment")
    elif k == "sized":
        if name not in ["list", "dict", "set", "tuple", "vtuple", "str", "bytes", "range"]:
            _pred_error(st, p, ctx, show(s) + " has no len()")
    elif k == "contains":
        if name == "list" or name == "set" or name == "vtuple" or name == "dict":
            _check(st, p, ctx, args[0], s["args"][0], None, False)
        elif name == "str":
            _check(st, p, ctx, args[0], con("str"), None, False)
        elif name == "range":
            _check(st, p, ctx, args[0], con("int"), None, False)
        elif name != "tuple" and name != "bytes":
            _pred_error(st, p, ctx, "'in' needs a list, tuple, dict, set, string or range, not " + show(s))
    elif k == "slice":
        if name == "tuple":
            _check(st, p, ctx, con("vtuple", [T_ANY]), args[0], None, True)
        elif name in ["list", "vtuple", "str", "bytes", "range"]:
            _check(st, p, ctx, s, args[0], None, True)
        else:
            _pred_error(st, p, ctx, show(s) + " cannot be sliced")
    elif k == "ordered":
        if name not in ORDERED:
            _pred_error(st, p, ctx, show(s) + " values cannot be ordered with < or >")
    elif k == "among":
        if name not in p["op"]:
            _pred_error(st, p, ctx, "expected " + " or ".join(p["op"]) + ", got " + show(s))
    elif k == "hasattr":
        t = attr_type(st, s, p["op"], pctx, _level_of(args[0]))
        _check(st, p, ctx, args[0], t, None, False)

def _role(ctx, role):
    return {"file": ctx["file"], "pos": ctx["pos"], "role": role}

def _level_of(t):
    t = resolve(t)
    return t["level"] if t["k"] == "var" and t["level"] != GENERIC else 0

NUMERIC_OPS = {"+": True, "-": True, "*": True, "/": True, "//": True, "%": True}
INT_OPS = {"|": True, "&": True, "^": True, "<<": True, ">>": True}
SET_OPS = {"|": True, "&": True, "^": True, "-": True}

# The operators that some left operand has with a right operand of each
# type (the keys: type names); with any other type, only str % x.
FEASIBLE = {
    "int": ["+", "-", "*", "/", "//", "%", "|", "&", "^", "<<", ">>"],
    "float": ["+", "-", "*", "/", "//", "%"],
    "str": ["+", "*", "%"],
    "bytes": ["+", "*", "%"],
    "list": ["+", "*", "%"],
    "tuple": ["+", "*", "%"],
    "vtuple": ["+", "*", "%"],
    "dict": ["|", "%"],
    "set": ["|", "&", "^", "-", "%"],
    "rec": ["+", "%"],
}

def _binop_error(st, p, ctx, l, r):
    nm = new_namer(False)
    _pred_error(st, p, ctx, "cannot apply " + p["op"] + " to " + show(l, nm) + " and " + show(r, nm))

def _result(st, p, t, ctx):
    _check(st, p, ctx, t, p["res"], "result of " + p["op"], True)

def solve_binop(st, p, ctx):
    """l <op> r is a res: decide from l's type, or else r's; wait if
    neither says enough."""
    op = p["op"]
    l = _nhead(resolve(p["l"]))
    r = _nhead(resolve(p["r"]))
    pctx = p["ctx"]
    if is_con(l, "Any") or is_con(r, "Any"):
        unify(st, p["res"], T_ANY, pctx)
        return
    if op in NUMERIC_OPS and (_is_num(l) or _is_num(r)):
        # an operand is an int literal (or a variable that so far only
        # held one): the result is a float if the other operand is, and
        # otherwise whatever the literal's type turns out to be
        me, other = (l, r) if _is_num(l) else (r, l)
        if _is_num(other):
            if op == "/":
                _result(st, p, con("float", [], pctx), ctx)
            elif unify(st, l, r, pctx) == None:
                _result(st, p, l, ctx)
            return
        if is_con(other, "float") or (op == "/" and is_con(other, "int")):
            _result(st, p, con("float", [], pctx), ctx)
            return
        if is_con(other, "int"):
            _result(st, p, me, ctx)
            return
        if other["k"] == "var" and not other["rigid"]:
            p["kind"] = "rbinop" if _is_num(l) else "binop"
            p["subj"] = p["r"] if _is_num(l) else p["l"]
            p["args"] = [p["l"] if _is_num(l) else p["r"], p["res"]]
            attach(st, other, p)
            return
    l = head(st, l)
    r = head(st, r)
    if l["k"] == "var":
        if l["rigid"]:
            p["kind"] = "binop"
            _rigid_pred(st, l, p, ctx)
            return
        # the right operand decides the left one where only one type fits
        decided = False
        if r["k"] == "rec" and op == "+":
            decided = unify_report(st, l, rec(row([new_var(st, "row", l["level"])])), pctx)
        elif r["k"] == "con":
            rn = r["name"]
            if (op == "+" and rn in ["str", "bytes", "list"]) or (op == "|" and rn in ["dict", "set"]) or (
                rn == "set" and op in SET_OPS
            ):
                decided = unify_report(st, l, r, pctx)
        if not decided:
            if r["k"] != "var" and op not in FEASIBLE.get(r["name"] if r["k"] == "con" else r["k"], ["%"]):
                # nothing has this operator with such a right operand
                _binop_error(st, p, ctx, l, r)
                return
            p["kind"] = "binop"
            p["subj"] = p["l"]
            p["args"] = [p["r"], p["res"]]
            attach(st, l, p)
            return
        l = head(st, p["l"])
    if l["k"] == "rec":
        if op != "+":
            _binop_error(st, p, ctx, l, r)
            return
        if r["k"] == "var" and not r["rigid"]:
            unify_report(st, r, rec(row([new_var(st, "row", r["level"])])), pctx)
            r = resolve(r)
        if r["k"] != "rec":
            _binop_error(st, p, ctx, l, r)
            return
        # struct + struct: the right operand's fields come first, so that
        # they shadow the left operand's fields of the same name
        _result(st, p, rec(row([r["row"], l["row"]]), pctx), ctx)
        return
    if l["k"] != "con":
        _binop_error(st, p, ctx, l, r)
        return
    ln = l["name"]
    if ln == "opt" or is_con(r, "opt"):
        _pred_error(st, p, ctx, ("left" if ln == "opt" else "right") + " operand of " + op + " may be None (it is " +
                                show(l if ln == "opt" else r) + "): test it against None first")
        return
    if ln == "int" or ln == "float":
        if op in NUMERIC_OPS:
            if r["k"] == "var":
                if r["rigid"]:
                    p["kind"] = "rbinop"
                    _rigid_pred(st, r, p, ctx)
                    return
                p["kind"] = "rbinop"
                p["subj"] = p["r"]
                p["args"] = [p["l"], p["res"]]
                attach(st, r, p)
                return
            rn = r["name"] if r["k"] == "con" else ""
            if rn == "int" or rn == "float":
                _result(st, p, con("float" if op == "/" or ln == "float" or rn == "float" else "int", [], pctx), ctx)
                return
            if op == "*" and ln == "int" and rn in ["str", "bytes", "list", "vtuple"]:
                _result(st, p, r, ctx)
                return
            if op == "*" and ln == "int" and rn == "tuple":
                _result(st, p, con("vtuple", [T_ANY], pctx), ctx)
                return
        elif op in INT_OPS and ln == "int":
            if unify(st, r, con("int"), pctx) == None:
                _result(st, p, con("int", [], pctx), ctx)
                return
        _binop_error(st, p, ctx, l, r)
        return
    if ln == "str":
        if op == "%":
            _result(st, p, con("str", [], pctx), ctx)
            return
        if op == "+" and flow(st, r, con("str"), pctx) == None:
            _result(st, p, con("str", [], pctx), ctx)
            return
        if op == "*" and unify(st, r, con("int"), pctx) == None:
            _result(st, p, con("str", [], pctx), ctx)
            return
        _binop_error(st, p, ctx, l, r)
        return
    if ln == "bytes" or ln == "list" or ln == "vtuple":
        if op == "+":
            err = unify(st, r, l, pctx)
            if err != None:
                if ln == "list" and is_con(resolve(r), "list"):
                    msg, notes = describe_failure(st, pctx, r, l, err, False)
                    report(st, pctx, "cannot add lists of different types: " + show(l) + " + " + show(r), notes)
                else:
                    _binop_error(st, p, ctx, l, r)
                return
            _result(st, p, l, ctx)
            return
        if op == "*" and unify(st, r, con("int"), pctx) == None:
            _result(st, p, l, ctx)
            return
        _binop_error(st, p, ctx, l, r)
        return
    if ln == "tuple":
        if op == "+":
            if r["k"] == "var" and not r["rigid"]:
                p["kind"] = "rbinop"
                p["subj"] = p["r"]
                p["args"] = [p["l"], p["res"]]
                attach(st, r, p)
                return
            if is_con(r, "tuple"):
                _result(st, p, con("tuple", l["args"] + r["args"], pctx), ctx)
                return
            if is_con(r, "vtuple"):
                _result(st, p, con("vtuple", [T_ANY], pctx), ctx)
                return
        elif op == "*" and unify(st, r, con("int"), pctx) == None:
            _result(st, p, con("vtuple", [T_ANY], pctx), ctx)
            return
        _binop_error(st, p, ctx, l, r)
        return
    if (ln == "dict" and op == "|") or (ln == "set" and op in SET_OPS):
        if unify(st, r, l, pctx) == None:
            _result(st, p, l, ctx)
            return
    _binop_error(st, p, ctx, l, r)

def default_pending(st, level):
    """Operator constraints still waiting on variables deeper than level
    (those a def is about to generalize; level -1: all, at the end of a
    module): where one operand is a number or the other operand's type is
    the only one left to try, the unknown operand gets the known one's
    type. So `def inc(x): return x + 1` is (x: int) -> int rather than
    generic in x; annotate x as float to have floats."""
    for _ in range(4):
        again = False
        todo = st["pending"]
        st["pending"] = []
        keep = []
        for p in todo:
            s = resolve(p["subj"])
            if s["k"] != "var" or s["rigid"] or not _waits_on(s, p):
                continue  # solved or moved since
            if s["level"] <= level or s["level"] == GENERIC:
                keep.append(p)
                continue
            other = head(st, p["l"] if p["kind"] == "rbinop" else p["r"])
            if other["k"] == "con" and other["name"] in ["int", "float"]:
                # (x / 2 is as good for a float x, and an int is fine where
                # a float is wanted)
                if unify(st, s, con("float") if p["op"] == "/" else other, p["ctx"]) == None:
                    again = True
                    continue
            keep.append(p)
        st["pending"] = keep + st["pending"]
        if not again:
            break

def _waits_on(v, p):
    for q in v["preds"]:
        if q.get("id") == p["id"]:
            return True
    return False

# ---------------------------------------------------------------- attributes

def pattern(st, name, level):
    """The type `name` with fresh arguments."""
    if name == "list" or name == "set":
        return con(name, [new_var(st, "type", level)])
    if name == "dict":
        return con(name, [new_var(st, "type", level), new_var(st, "type", level)])
    return con(name)

def method_type(st, s, tyname, name, ctx, level):
    """The type of s.name for the builtin method `name` of type tyname: the
    method's scheme with its receiver unified with s."""
    f = instantiate(st, st["methods"][tyname][name], level)
    unify(st, f["params"][0]["type"], s, ctx)
    return fn(f["params"][1:], f["ret"], ctx)

def attr_type(st, t, name, ctx, level):
    """The type of x.name for an x of type t."""
    s = head(st, t)
    k = s["k"]
    if k == "var":
        if s["rigid"]:
            for q in s["preds"]:
                if q["kind"] == "hasattr" and q["op"] == name:
                    return q["args"][0]
            report(st, ctx, "type parameter '" + (s["name"] or "?") + "' stands for any type, which may have no ." + name)
            return T_ANY
        owners = st["owners"].get(name)
        if owners == None:
            # not a builtin method: x is a struct with (at least) this field
            ft = new_var(st, "type", s["level"])
            r = row([field(lit(name), ft, ctx), new_var(st, "row", s["level"])])
            bind(st, s, rec(r, ctx), ctx)
            return ft
        if len(owners) == 1:
            unify(st, s, pattern(st, owners[0], s["level"]), ctx)
            return method_type(st, resolve(s), owners[0], name, ctx, level)
        res = new_var(st, "type", s["level"])
        attach(st, s, pred("hasattr", s, [res], ctx, name))
        return res
    if k == "rec":
        return row_get(st, s, name, ctx, level)
    if k == "con":
        n = s["name"]
        if n == "Any":
            return T_ANY
        if n == "opt":
            report(st, ctx, "the value may be None (it is " + show(s) + "): test it against None before using ." + name)
            return T_ANY
        ms = st["methods"].get(n)
        if ms != None and name in ms:
            return method_type(st, s, n, name, ctx, level)
        if ms != None:
            report(st, ctx, show(s) + " has no method '" + name + "'" + hint(name, ms.keys()))
            return T_ANY
    report(st, ctx, show(s) + " has no field or method '" + name + "'", _origin_note(ctx, t, "comes from here", show(s)))
    return T_ANY

def row_get(st, s, name, ctx, level):
    """The type of field `name` of the record type s: the first field of
    that name (scoped labels), looked up as the paper's lookup judgment."""
    items = flatten(s["row"])
    status, j, blocker = _lookup(items, name, [], False)
    if status == "found":
        return items[j]["type"]
    if status == "extend":
        v = items[j]
        ft = new_var(st, "type", v["level"])
        bind(st, v, row([field(lit(name), ft, ctx), new_var(st, "row", v["level"])]), ctx)
        return ft
    nm = new_namer(False)
    if status == "missing":
        have = _field_names(items)
        msg = "struct has no field '" + name + "'" + hint(name, have)
        if have:
            msg += "; it has " + ", ".join(["'" + h + "'" for h in have])
        if j >= 0:
            msg += " and whatever '" + (items[j]["name"] or "?") + "' stands for"
        notes = []
        o = origin_of(s)
        if o != None and not _same_place(o, ctx):
            r = o.get("role")
            notes.append(note_at(o, "the struct is " + show(s, nm) + (" (" + r + ")" if r else "")))
        report(st, ctx, msg, notes)
        return T_ANY
    # stuck: something before the field may shadow it
    what = "a field whose name is not known yet" if blocker["kind"] == "label" else "other fields, which may include one named '" + name + "'"
    report(st, ctx, "cannot tell which field '" + name + "' of " + show(s, nm) + " this is: before it come " + what +
                    ", and the first field of a name is the one that counts")
    return T_ANY

# ---------------------------------------------------------------- schemes

def generalize(st, t, level, ctx):
    """Quantify the variables of t that belong to a def at nesting depth
    level + 1 (or deeper): they become GENERIC, and instantiate gives each
    use of the def its own copy. A string literal's type settles as str."""
    default_pending(st, level)
    _generalize(st, resolve(t), level, ctx)
    return t

def _generalize(st, t, level, ctx):
    k = t["k"]
    if k == "var":
        if t["level"] == GENERIC or t["level"] <= level:
            return
        if t["lit"] != None:
            t["ref"] = con("str", [], t["at"])
            return
        if t["num"]:
            t["ref"] = con("int", [], t["at"])
            return
        t["level"] = GENERIC
        t["rigid"] = False
        keep = []
        for p in t["preds"]:
            if p["kind"] == "rows":
                nm = new_namer(False)
                report(st, p["ctx"], "cannot decide whether " + show(p["args"][0], nm) + " and " + show(p["args"][1], nm) +
                                     " are the same struct type: it depends on fields that are not known here")
                continue
            keep.append(p)
            for x in _pred_types(p):
                _generalize(st, resolve(x), level, ctx)
        t["preds"] = keep
    elif k == "con":
        for a in t["args"]:
            _generalize(st, resolve(a), level, ctx)
    elif k == "fn":
        for p in t["params"]:
            _generalize(st, resolve(p["type"]), level, ctx)
        _generalize(st, resolve(t["ret"]), level, ctx)
    elif k == "rec":
        for it in flatten(t["row"]):
            if it["k"] == "f":
                _generalize(st, resolve_label(it["label"]), level, ctx)
                _generalize(st, resolve(it["type"]), level, ctx)
            else:
                _generalize(st, it, level, ctx)
    elif k == "lab":
        _generalize(st, resolve_label(t["label"]), level, ctx)

def has_generic(t):
    return _has_generic(resolve(t))

def _has_generic(t):
    k = t["k"]
    if k == "var":
        return t["level"] == GENERIC
    if k == "con":
        for a in t["args"]:
            if _has_generic(resolve(a)):
                return True
    elif k == "fn":
        for p in t["params"]:
            if _has_generic(resolve(p["type"])):
                return True
        return _has_generic(resolve(t["ret"]))
    elif k == "rec":
        for it in flatten(t["row"]):
            if it["k"] == "f":
                if _has_generic(resolve_label(it["label"])) or _has_generic(resolve(it["type"])):
                    return True
            elif it["level"] == GENERIC:
                return True
    elif k == "lab":
        return _has_generic(resolve_label(t["label"]))
    return False

def instantiate(st, t, level, memo = None):
    """A copy of scheme t with fresh variables (at level) for its
    quantified ones, constraints included. memo: the copies so far, by the
    quantified variable's id (to instantiate several types together)."""
    if memo == None:
        if not has_generic(t):
            return t
        memo = {}
    return _inst(st, resolve(t), level, memo)

def _inst(st, t, level, memo):
    k = t["k"]
    if k == "var":
        if t["level"] != GENERIC:
            return t
        v = memo.get(t["id"])
        if v != None:
            return v
        v = new_var(st, t["kind"], level)
        v["name"] = t["name"]
        memo[t["id"]] = v
        for p in t["preds"]:
            q = dict(p)
            st["next"] += 1
            q["id"] = st["next"]
            q["subj"] = _inst(st, resolve(p["subj"]), level, memo)
            q["args"] = [_inst(st, resolve(x), level, memo) for x in p["args"]]
            if p["kind"] == "binop" or p["kind"] == "rbinop":
                for key in ["l", "r", "res"]:
                    q[key] = _inst(st, resolve(p[key]), level, memo)
                st["pending"].append(q)
            v["preds"].append(q)
        return v
    if k == "con":
        if not t["args"]:
            return t
        return con(t["name"], [_inst(st, resolve(a), level, memo) for a in t["args"]], t["at"])
    if k == "fn":
        ps = [param(p["name"], _inst(st, resolve(p["type"]), level, memo), p["opt"], p["star"], p["kw"]) for p in t["params"]]
        return fn(ps, _inst(st, resolve(t["ret"]), level, memo), t["at"])
    if k == "rec":
        items = []
        for it in flatten(t["row"]):
            if it["k"] == "f":
                items.append(field(_inst(st, resolve_label(it["label"]), level, memo), _inst(st, resolve(it["type"]), level, memo), it.get("at")))
            else:
                items.append(_inst(st, it, level, memo))
        return rec(row(items), t["at"])
    if k == "lab":
        return lab(_inst(st, resolve_label(t["label"]), level, memo), t.get("at"))
    return t
