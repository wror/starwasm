# types.star — the type checker's types, and how they are printed.
#
# The type system is Hindley-Milner with the record calculus of
# "Infix-Extensible Record Types for Tabular Data" (Paszke & Xie, TyDe '23):
# struct types are records over rows with scoped labels, rows can be
# concatenated anywhere (struct + struct), and field names are first-class
# (getattr). EXTENSIONS.md ("Static types") describes it from the outside;
# typecheck/unify.star has the unification algorithm (the paper's Fig. 10).
#
# Types are dicts with a "k" (never compare two with ==: that is structural;
# variables are compared by "id"):
#
#   con   {name, args, at}     int float str bytes bool None Any range,
#                              list[T] dict[K, V] set[T], tuple (args: the
#                              elements), vtuple (tuple[T, ...]) and
#                              opt (T | None)
#   fn    {params, ret, at}    params: {name (or None), type, opt (has a
#                              default), star ("", "*", "**"), kw
#                              (keyword-only)}
#   rec   {row, at}            a struct: the record {row}
#   lab   {label, at}          the type of a field name (the paper's
#                              singleton label type): Literal["x"], or L
#                              for a label variable
#   var   a unification variable of kind "type", "row" or "label" (below)
#
# Rows and labels are not types (they have their own kinds):
#   row   {items}              a concatenation: each item is a field
#                              {k: "f", label, type, at} or a row (variable)
#   lit   {name}               a label literal; the other labels are
#                              variables of kind "label"
#
# A variable is {k: "var", id, kind, ref, level, preds, lit, rigid, name, at}:
#   ref     what it was solved to (None: unsolved)
#   level   the nesting depth of the def it belongs to: a def generalizes
#           the variables deeper than itself. GENERIC marks a quantified
#           variable of a type scheme (instantiate copies those).
#   preds   constraints waiting for it to be solved (unify.star)
#   lit     for the type of a string literal "x": the text. It becomes
#           Literal["x"] where a field name is wanted and str otherwise.
#   num     the type of an int literal: it becomes float where a float is
#           wanted (so `total = 0` can go on as `total += 1.5`), else int.
#   rigid   a type parameter of an annotation while the annotated def is
#           being checked: it unifies only with itself.
#   at      where it was solved: an origin
#
# An origin says where a type comes from, for error messages:
# {file, pos, role} (role: a few words, e.g. "argument 'n' of f()").

GENERIC = 1000000000

def new_var(st, kind, level):
    st["next"] += 1
    return {
        "k": "var",
        "id": st["next"],
        "kind": kind,
        "ref": None,
        "level": level,
        "preds": [],
        "lit": None,
        "num": False,
        "rigid": False,
        "name": None,
        "at": None,
    }

def con(name, args = [], at = None):
    return {"k": "con", "name": name, "args": args, "at": at}

def fn(params, ret, at = None):
    return {"k": "fn", "params": params, "ret": ret, "at": at}

def param(name, type, opt = False, star = "", kw = False):
    return {"name": name, "type": type, "opt": opt, "star": star, "kw": kw}

def rec(row, at = None):
    return {"k": "rec", "row": row, "at": at}

def row(items):
    return {"k": "row", "items": items}

def field(label, type, at = None):
    return {"k": "f", "label": label, "type": type, "at": at}

def lit(name):
    return {"k": "lit", "name": name}

def lab(label, at = None):
    return {"k": "lab", "label": label, "at": at}

T_ANY = con("Any")

def is_con(t, name):
    return t["k"] == "con" and t["name"] == name

def resolve(t):
    """t with solved variables followed; T | None is kept normal (never
    around None, Any or another optional)."""
    for _ in range(1 << 30):
        if t["k"] == "var" and t["ref"] != None:
            t = t["ref"]
        else:
            break
    if t["k"] == "con" and t["name"] == "opt":
        a = resolve(t["args"][0])
        if a["k"] == "con" and (a["name"] == "opt" or a["name"] == "None" or a["name"] == "Any"):
            return a
    return t

def resolve_label(l):
    for _ in range(1 << 30):
        if l["k"] == "var" and l["ref"] != None:
            l = l["ref"]
        else:
            break
    return l

def mk_opt(t, at = None):
    r = resolve(t)
    if r["k"] == "con" and (r["name"] == "opt" or r["name"] == "None" or r["name"] == "Any"):
        return r
    return con("opt", [t], at)

def flatten(r):
    """The items of row r, in order, with solved row variables expanded:
    fields and unsolved row variables. Labels are scoped: the first field
    of a name is the one a struct has, and since Starlark has no way to
    remove a field, a later field of that name can never be seen: it is
    dropped here. (The paper keeps such fields, for its restriction
    operator.)"""
    items = []
    _flatten(r, items)
    seen = {}
    out = []
    for it in items:
        if it["k"] == "f":
            l = resolve_label(it["label"])
            if l["k"] == "lit":
                if l["name"] in seen:
                    continue
                seen[l["name"]] = True
        out.append(it)
    return out

def _flatten(r, out):
    if r["k"] == "var":
        if r["ref"] != None:
            _flatten(r["ref"], out)
        else:
            out.append(r)
    elif r["k"] == "row":
        for it in r["items"]:
            if it["k"] == "f":
                out.append(it)
            else:
                _flatten(it, out)
    else:
        out.append(r)

def origin_of(t):
    """Where t's shape was decided: where the last variable on the way to
    it was solved, else where the type itself was made."""
    at = None
    for _ in range(1 << 30):
        if t["k"] == "var" and t["ref"] != None:
            if t["at"] != None:
                at = t["at"]
            t = t["ref"]
        else:
            break
    if at != None:
        return at
    return t.get("at")

# ---------------------------------------------------------------- printing

BINOP_NAMES = {
    "+": "Add",
    "-": "Sub",
    "*": "Mul",
    "/": "Div",
    "//": "FloorDiv",
    "%": "Mod",
    "|": "Or",
    "&": "And",
    "^": "Xor",
    "<<": "LShift",
    ">>": "RShift",
}

TYPE_NAMES = ["T", "U", "V", "W", "X", "Y", "Z"]

def new_namer(sig):
    """Names for the variables of the types printed together. sig: a
    signature is being printed (a .starit file): quantified variables get
    names (T, U, ...; rows R, R2, ...; labels L, L2, ...) and anything else
    unsolved is Any. Otherwise (an error message) unknown types are "_" and
    an open row ends in "..."."""
    return {"sig": sig, "names": {}, "order": [], "n": {"type": 0, "row": 0, "label": 0}, "used": {}}

def var_name(nm, v):
    name = nm["names"].get(v["id"])
    if name != None:
        return name
    for _ in range(1 << 30):
        if v["name"] != None and not nm["used"].get(v["name"], False):
            name = v["name"]
            break
        n = nm["n"][v["kind"]]
        nm["n"][v["kind"]] = n + 1
        if v["kind"] == "type":
            name = TYPE_NAMES[n] if n < len(TYPE_NAMES) else "T" + str(n - len(TYPE_NAMES) + 1)
        elif v["kind"] == "row":
            name = "R" if n == 0 else "R" + str(n + 1)
        else:
            name = "L" if n == 0 else "L" + str(n + 1)
        if not nm["used"].get(name, False):
            break
    nm["used"][name] = True
    nm["names"][v["id"]] = name
    nm["order"].append(v)
    return name

def _named(nm, v):
    """Does v print as a named variable (rather than as unknown)? Once
    the namer is closed (a signature's parameter list has been printed),
    only the variables named so far do."""
    if nm.get("closed", False):
        return v["id"] in nm["names"]
    if nm.get("all", False):
        return v["lit"] == None and not v["num"]  # every unknown gets a name
    return v["rigid"] or v["level"] == GENERIC or v["id"] in nm["names"]

def show(t, nm = None):
    if nm == None:
        nm = new_namer(False)
    return _show(resolve(t), nm, 0)

def _show(t, nm, prec):
    # prec 1: inside a union (function types need parentheses)
    k = t["k"]
    if k == "var":
        if t["lit"] != None:
            return "str"
        if t["num"]:
            return "int"
        if _named(nm, t):
            return var_name(nm, t)
        return "Any" if nm["sig"] else "_"
    if k == "con":
        name = t["name"]
        args = t["args"]
        if name == "opt":
            a0 = resolve(args[0])
            if nm["sig"] and a0["k"] == "var" and a0["lit"] == None and not a0["num"] and not _named(nm, a0):
                return "None"  # nothing but None was ever seen
            return _show(a0, nm, 1) + " | None"
        if name == "tuple":
            if not args:
                return "tuple[()]"
            return "tuple[" + ", ".join([_show(resolve(a), nm, 0) for a in args]) + "]"
        if name == "vtuple":
            return "tuple[" + _show(resolve(args[0]), nm, 0) + ", ...]"
        if not args:
            return name
        return name + "[" + ", ".join([_show(resolve(a), nm, 0) for a in args]) + "]"
    if k == "fn":
        s = "(" + show_params(t["params"], nm) + ") -> " + _show(resolve(t["ret"]), nm, 0)
        return "(" + s + ")" if prec > 0 else s
    if k == "rec":
        return "struct[" + show_row(t["row"], nm) + "]"
    if k == "lab":
        l = resolve_label(t["label"])
        if l["k"] == "lit":
            return "Literal[" + repr(l["name"]) + "]"
        if _named(nm, l):
            return var_name(nm, l)
        return "str"
    return "?" + k

def show_label(l, nm):
    l = resolve_label(l)
    if l["k"] == "lit":
        return l["name"]
    if _named(nm, l):
        return var_name(nm, l)
    return "Any" if nm["sig"] else "_"

def show_row(r, nm):
    parts = []
    for it in flatten(r):
        if it["k"] == "f":
            l = resolve_label(it["label"])
            name = show_label(l, nm)
            if l["k"] == "lit" and nm["used"].get(name, False):
                name = repr(name)  # not the type parameter of that name
            parts.append(name + ": " + _show(resolve(it["type"]), nm, 0))
        elif _named(nm, it):
            parts.append("**" + var_name(nm, it))
        elif nm["sig"]:
            parts.append("**Any")
        else:
            parts.append("...")
    return ", ".join(parts)

def show_params(params, nm):
    parts = []
    star_seen = False
    for p in params:
        t = _show(resolve(p["type"]), nm, 0)
        if p["star"] != "":
            if p["star"] == "*":
                star_seen = True
            parts.append(p["star"] + (p["name"] or ("args" if p["star"] == "*" else "kwargs")) + ": " + t)
            continue
        if p["kw"] and not star_seen:
            parts.append("*")
            star_seen = True
        s = t if p["name"] == None else p["name"] + ": " + t
        if p["opt"]:
            s += " = ..."
        parts.append(s)
    return ", ".join(parts)

def show_pred(p, nm):
    """A pending constraint, as the bound of its subject."""
    k = p["kind"]
    a = [_show(resolve(x), nm, 0) for x in p["args"]]
    if k == "iter":
        return "Iterable[" + a[0] + "]"
    if k == "getitem":
        return "GetItem[" + a[0] + ", " + a[1] + "]"
    if k == "setitem":
        return "SetItem[" + a[0] + ", " + a[1] + "]"
    if k == "sized":
        return "Sized"
    if k == "contains":
        return "Container[" + a[0] + "]"
    if k == "slice":
        return "Sliceable[" + a[0] + "]"
    if k == "ordered":
        return "Ordered"
    if k == "among":
        return "(" + ", ".join(p["op"]) + ")"
    if k == "binop":
        return BINOP_NAMES[p["op"]] + "[" + a[0] + ", " + a[1] + "]"
    if k == "rbinop":
        return "R" + BINOP_NAMES[p["op"]] + "[" + a[0] + ", " + a[1] + "]"
    if k == "hasattr":
        return "HasAttr[" + repr(p["op"]) + ", " + a[0] + "]"
    return "?" + k

def describe_pred(p):
    """What a constraint asks of a type, for error messages."""
    k = p["kind"]
    if k == "iter":
        return "iterable"
    if k == "getitem":
        return "indexable"
    if k == "setitem":
        return "assignable by index"
    if k == "sized":
        return "something with a length"
    if k == "contains":
        return "a container"
    if k == "slice":
        return "sliceable"
    if k == "ordered":
        return "ordered"
    if k == "among":
        return " or ".join(p["op"])
    if k == "binop" or k == "rbinop":
        return "an operand of " + p["op"]
    if k == "hasattr":
        return "something with ." + p["op"]
    return k

def collect_generic(t, nm):
    """Name the quantified variables of t in order of appearance (those of
    the bounds of each included)."""
    _collect(resolve(t), nm, {})

def _collect(t, nm, seen):
    k = t["k"]
    if k == "var":
        if t["level"] == GENERIC or t["rigid"] or (nm.get("all", False) and t["lit"] == None and not t["num"]):
            if t["id"] in seen:
                return
            seen[t["id"]] = True
            var_name(nm, t)
            for p in t["preds"]:
                for a in p["args"]:
                    _collect(resolve(a), nm, seen)
    elif k == "con":
        for a in t["args"]:
            _collect(resolve(a), nm, seen)
    elif k == "fn":
        for p in t["params"]:
            _collect(resolve(p["type"]), nm, seen)
        _collect(resolve(t["ret"]), nm, seen)
    elif k == "rec":
        for it in flatten(t["row"]):
            if it["k"] == "f":
                _collect(resolve_label(it["label"]), nm, seen)
                _collect(resolve(it["type"]), nm, seen)
            else:
                _collect(it, nm, seen)
    elif k == "lab":
        _collect(resolve_label(t["label"]), nm, seen)

def show_tparams(nm, start = 0):
    """The type parameter list "[T, U: Iterable[T], **R, L: str]" for the
    variables named from index start on (after collect_generic), or ""."""
    parts = []
    for _ in range(1 << 30):
        # printing a bound can name more variables: go on until none is new
        if start >= len(nm["order"]):
            break
        v = nm["order"][start]
        start += 1
        name = nm["names"][v["id"]]
        if v["kind"] == "row":
            parts.append("**" + name)
        elif v["kind"] == "label":
            parts.append(name + ": str")
        else:
            bounds = []
            for p in v["preds"]:
                b = show_pred(p, nm)
                if p["kind"] != "rows" and b not in bounds:
                    bounds.append(b)
            parts.append(name + (": " + " & ".join(bounds) if bounds else ""))
    return "[" + ", ".join(parts) + "]" if parts else ""
