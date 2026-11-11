# stubs.star — the type language of .start (annotations written by the
# programmer) and .starit (types inferred by the checker) files: parsing,
# and conversion of the parsed types to the checker's types (types.star).
# EXTENSIONS.md ("Static types") documents the language.
#
#   file    = { decl }
#   decl    = NAME ":" type                                  a variable
#           | "def" NAME [tparams] "(" [params] ")" ["->" type] [":" body]
#           | "type" NAME [tparams] "=" type                 an alias
#   body    = "..." | "pass" | NEWLINE INDENT { decl } DEDENT
#             (the declarations of the def's locals and nested defs)
#   tparams = "[" tparam { "," tparam } "]"
#   tparam  = NAME [":" bounds] | "**" NAME
#   bounds  = "str"                                          a field name
#           | bound { "&" bound }
#   bound   = NAME ["[" (STRING | type) { "," type } "]"]    Iterable[T], ...
#           | "(" NAME { "," NAME } ")"                      one of these types
#   params  = param { "," param }
#   param   = NAME [":" type] ["=" "..."] | "*" [NAME [":" type]]
#           | "**" NAME [":" type]
#   type    = prim { "|" prim }                              only T | None
#   prim    = NAME ["[" type { "," type } ["," "..."] "]"]   int, list[T], ...
#           | "tuple" "[" "(" ")" "]"
#           | "struct" "[" [ field { "," field } ] "]"
#           | "Literal" "[" STRING "]"
#           | "(" [fparams] ")" "->" type                    a function
#           | "(" type ")"
#   field   = (NAME | STRING) ":" type | "**" NAME
#   fparams = as params, but a parameter may be just a type (positional)
#
# The tokens are Starlark's (compiler/lexer.star), so comments, strings and
# indentation are as in the program. A syntax error stops the checker
# (fail), as a syntax error in the program does.
#
# Parsed types ("type ASTs") are dicts with "t" and "pos":
#   name {name, args (or None)}   struct {fields: ("f", name, type, pos) |
#   ("row", name, pos)}   literal {val}   fn {params, ret}   opt {arg}
#   ellipsis   unit (the "()" of tuple[()])   group {types} ([A, B], for Callable)
# Declarations: {d: "var", name, type, pos}
#   {d: "def", name, tparams, params, ret (or None), body (or None), pos}
#   {d: "alias", name, tparams, type, pos}
#   tparam: {name, kind: "type" | "row" | "label", bounds: [...], pos}
#   bound: ("among", [names], pos) | ("proto", name, [arg type ASTs or strings], pos)
#   param: {name (or None), type (or None), opt, star, kw, pos}

load("../compiler/lexer.star", "lex")
load("../compiler/parser.star", "token_name")
load("../compiler/spell.star", "nearest")
load(
    "types.star",
    "BINOP_NAMES",
    "T_ANY",
    "con",
    "field",
    "flatten",
    "fn",
    "lab",
    "lit",
    "mk_opt",
    "new_var",
    "param",
    "rec",
    "resolve",
    "resolve_label",
    "row",
)
load("unify.star", "report")

# ---------------------------------------------------------------- parsing

def _tok(p):
    return p["toks"][p["i"]]["kind"]

def _peek(p, k = 0):
    i = p["i"] + k
    toks = p["toks"]
    return toks[i] if i < len(toks) else toks[-1]

def _advance(p):
    t = p["toks"][p["i"]]
    if t["kind"] != "eof":
        p["i"] += 1
    return t

def _pos(t):
    return (t["line"], t["col"])

def _error(p, t, msg):
    fail(p["file"] + ":" + str(t["line"]) + ":" + str(t["col"]) + ": " + msg)

def _want(p, kind):
    if _tok(p) != kind:
        _error(p, _peek(p), "got " + token_name(_tok(p)) + ", want " + token_name(kind))
    return _advance(p)

def _is_name(p, name, k = 0):
    t = _peek(p, k)
    return t["kind"] == "name" and t["val"] == name

def parse_stubs(src, filename):
    """The declarations of a .start or .starit file."""
    p = {"toks": lex(src, filename), "i": 0, "file": filename}
    decls = []
    for _ in range(len(p["toks"]) + 1):
        if _tok(p) == "eof":
            break
        if _tok(p) == "newline":
            _advance(p)
            continue
        decls.append(_parse_decl(p))
    return decls

def _end_line(p):
    if _tok(p) != "eof" and _tok(p) != "dedent":
        _want(p, "newline")

def _parse_decl(p):
    t = _peek(p)
    if t["kind"] == "def":
        return _parse_def(p)
    if t["kind"] != "name":
        _error(p, t, "got " + token_name(t["kind"]) + ", want a declaration: `name: type`, `def name(...) -> type` or `type Name = type`")
    if t["val"] == "type" and _peek(p, 1)["kind"] == "name":
        _advance(p)
        nt = _advance(p)
        d = {"d": "alias", "name": nt["val"], "pos": _pos(nt), "tparams": _parse_tparams(p)}
        _want(p, "=")
        d["type"] = _parse_type(p)
        _end_line(p)
        return d
    _advance(p)
    if _tok(p) != ":":
        _error(p, _peek(p), "got " + token_name(_tok(p)) + " after " + t["val"] + ", want ':' and its type (`" + t["val"] + ": type`)")
    _advance(p)
    d = {"d": "var", "name": t["val"], "pos": _pos(t), "type": _parse_type(p)}
    _end_line(p)
    return d

def _parse_def(p):
    _advance(p)
    nt = _want(p, "name")
    d = {"d": "def", "name": nt["val"], "pos": _pos(nt), "tparams": _parse_tparams(p), "ret": None, "body": None}
    _want(p, "(")
    d["params"] = _parse_params(p, False)
    _want(p, ")")
    if _tok(p) == "-":
        _advance(p)
        _want(p, ">")
        d["ret"] = _parse_type(p)
    if _tok(p) == ":":
        _advance(p)
        if _tok(p) == "pass":
            _advance(p)
        elif _tok(p) == ".":
            _ellipsis(p)
        else:
            _want(p, "newline")
            _want(p, "indent")
            body = []
            for _ in range(len(p["toks"])):
                if _tok(p) == "dedent" or _tok(p) == "eof":
                    break
                if _tok(p) == "pass":
                    _advance(p)
                    _end_line(p)
                    continue
                if _tok(p) == ".":
                    _ellipsis(p)
                    _end_line(p)
                    continue
                body.append(_parse_decl(p))
            _want(p, "dedent")
            d["body"] = body
            return d
    _end_line(p)
    return d

def _ellipsis(p):
    _want(p, ".")
    _want(p, ".")
    _want(p, ".")

def _parse_tparams(p):
    out = []
    if _tok(p) != "[":
        return out
    _advance(p)
    for _ in range(len(p["toks"])):
        if _tok(p) == "]":
            break
        if out:
            _want(p, ",")
            if _tok(p) == "]":
                break
        if _tok(p) == "**":
            _advance(p)
            nt = _want(p, "name")
            out.append({"name": nt["val"], "kind": "row", "bounds": [], "pos": _pos(nt)})
            continue
        nt = _want(p, "name")
        tp = {"name": nt["val"], "kind": "type", "bounds": [], "pos": _pos(nt)}
        if _tok(p) == ":":
            _advance(p)
            if _is_name(p, "str") and _peek(p, 1)["kind"] != "&":
                _advance(p)
                tp["kind"] = "label"
            else:
                for _ in range(len(p["toks"])):
                    if _tok(p) == "(":
                        bt = _advance(p)
                        names = [_want(p, "name")["val"]]
                        for _ in range(len(p["toks"])):
                            if _tok(p) != ",":
                                break
                            _advance(p)
                            names.append(_want(p, "name")["val"])
                        _want(p, ")")
                        tp["bounds"].append(("among", names, _pos(bt)))
                    else:
                        bt = _want(p, "name")
                        args = []
                        if _tok(p) == "[":
                            _advance(p)
                            for _ in range(len(p["toks"])):
                                if _tok(p) == "]":
                                    break
                                if args:
                                    _want(p, ",")
                                if _tok(p) == "string":
                                    args.append(_advance(p)["val"])
                                else:
                                    args.append(_parse_type(p))
                            _want(p, "]")
                        tp["bounds"].append(("proto", bt["val"], args, _pos(bt)))
                    if _tok(p) != "&":
                        break
                    _advance(p)
        out.append(tp)
    _want(p, "]")
    return out

def _parse_params(p, in_type):
    """Parameters up to the ")". in_type: of a function type, where a
    parameter may be just its type."""
    out = []
    kw = False
    for _ in range(len(p["toks"])):
        if _tok(p) == ")":
            break
        if out or kw:
            _want(p, ",")
            if _tok(p) == ")":
                break
        t = _peek(p)
        if t["kind"] == "*" or t["kind"] == "**":
            _advance(p)
            if t["kind"] == "*" and _tok(p) != "name":
                kw = True  # a bare "*": the parameters after it are keyword-only
                continue
            nt = _want(p, "name")
            ty = None
            if _tok(p) == ":":
                _advance(p)
                ty = _parse_type(p)
            out.append({"name": nt["val"], "type": ty, "opt": False, "star": t["kind"], "kw": False, "pos": _pos(nt)})
            if t["kind"] == "*":
                kw = True
            continue
        name = None
        ty = None
        if t["kind"] == "name" and (not in_type or _peek(p, 1)["kind"] == ":"):
            name = _advance(p)["val"]
            if _tok(p) == ":":
                _advance(p)
                ty = _parse_type(p)
        else:
            ty = _parse_type(p)
        opt = False
        if _tok(p) == "=":
            _advance(p)
            _ellipsis(p)
            opt = True
        out.append({"name": name, "type": ty, "opt": opt, "star": "", "kw": kw, "pos": _pos(t)})
    return out

def _parse_type(p):
    t = _peek(p)
    x = _parse_prim(p)
    for _ in range(len(p["toks"])):
        if _tok(p) != "|":
            break
        bar = _advance(p)
        y = _parse_prim(p)
        xn = x["t"] == "name" and x["name"] == "None" and x["args"] == None
        yn = y["t"] == "name" and y["name"] == "None" and y["args"] == None
        if not xn and not yn:
            _error(p, bar, "the only union types are `T | None`: a value that may be None")
        x = {"t": "opt", "arg": y if xn else x, "pos": _pos(t)}
    return x

def _parse_prim(p):
    t = _peek(p)
    k = t["kind"]
    if k == "(":
        # a function type "(params) -> type", or a parenthesized type
        depth = 0
        j = p["i"]
        toks = p["toks"]
        for _ in range(len(toks)):
            kk = toks[j]["kind"]
            if kk == "(" or kk == "[" or kk == "{":
                depth += 1
            elif kk == ")" or kk == "]" or kk == "}":
                depth -= 1
                if depth == 0:
                    break
            elif kk == "eof":
                break
            j += 1
        is_fn = j + 2 < len(toks) and toks[j + 1]["kind"] == "-" and toks[j + 2]["kind"] == ">"
        _advance(p)
        if is_fn:
            params = _parse_params(p, True)
            _want(p, ")")
            _want(p, "-")
            _want(p, ">")
            return {"t": "fn", "params": params, "ret": _parse_type(p), "pos": _pos(t)}
        if _tok(p) == ")":
            _advance(p)
            return {"t": "unit", "pos": _pos(t)}
        x = _parse_type(p)
        _want(p, ")")
        return x
    if k == "[":
        _advance(p)
        types = []
        for _ in range(len(p["toks"])):
            if _tok(p) == "]":
                break
            if types:
                _want(p, ",")
            types.append(_parse_type(p))
        _want(p, "]")
        return {"t": "group", "types": types, "pos": _pos(t)}
    if k == ".":
        _ellipsis(p)
        return {"t": "ellipsis", "pos": _pos(t)}
    if k != "name":
        _error(p, t, "got " + token_name(k) + ", want a type")
    _advance(p)
    name = t["val"]
    if name == "struct" and _tok(p) == "[":
        _advance(p)
        fields = []
        for _ in range(len(p["toks"])):
            if _tok(p) == "]":
                break
            if fields:
                _want(p, ",")
                if _tok(p) == "]":
                    break
            ft = _peek(p)
            if ft["kind"] == "**":
                _advance(p)
                nt = _want(p, "name")
                fields.append(("row", nt["val"], _pos(nt)))
                continue
            if ft["kind"] != "name" and ft["kind"] != "string":
                _error(p, ft, "got " + token_name(ft["kind"]) + ", want a field `name: type` or `**R`")
            _advance(p)
            _want(p, ":")
            fields.append(("f", ft["val"], _parse_type(p), _pos(ft), ft["kind"] == "string"))
        _want(p, "]")
        return {"t": "struct", "fields": fields, "pos": _pos(t)}
    if name == "Literal" and _tok(p) == "[":
        _advance(p)
        s = _want(p, "string")
        _want(p, "]")
        return {"t": "literal", "val": s["val"], "pos": _pos(t)}
    args = None
    if _tok(p) == "[":
        _advance(p)
        args = []
        for _ in range(len(p["toks"])):
            if _tok(p) == "]":
                break
            if args:
                _want(p, ",")
                if _tok(p) == "]":
                    break
            args.append(_parse_type(p))
        _want(p, "]")
    return {"t": "name", "name": name, "args": args, "pos": _pos(t)}

# ---------------------------------------------------------------- conversion

SIMPLE = {"int": True, "float": True, "str": True, "bytes": True, "bool": True, "None": True, "Any": True, "range": True}
ARITY = {"list": 1, "set": 1, "dict": 2}
KNOWN = ["int", "float", "str", "bytes", "bool", "None", "Any", "range", "list", "set", "dict", "tuple", "struct", "Literal", "Optional", "Callable"]
# PEP 484's capitalized names for the builtin generic types
SYNONYMS = {"List": "list", "Dict": "dict", "Set": "set", "Tuple": "tuple"}
MISNOMERS = {
    "string": "str",
    "integer": "int",
    "boolean": "bool",
    "number": "float",
    "double": "float",
    "NoneType": "None",
    "object": "Any",
    "any": "Any",
    "function": "(...) -> ...",
}
PROTOS = {
    "Iterable": ("iter", 1),
    "GetItem": ("getitem", 2),
    "SetItem": ("setitem", 2),
    "Sized": ("sized", 0),
    "Container": ("contains", 1),
    "Sliceable": ("slice", 1),
    "Ordered": ("ordered", 0),
}
BINOP_BY_NAME = {name: op for op, name in BINOP_NAMES.items()}

def new_scope(st, file, aliases, level):
    """What type names mean while converting: cv = {st, file, aliases:
    name -> alias declaration, tvars: name -> {kind, val}, level}."""
    return {"st": st, "file": file, "aliases": aliases, "tvars": {}, "level": level, "expanding": {}}

def child_scope(cv):
    c = dict(cv)
    c["tvars"] = dict(cv["tvars"])
    return c

def _at(cv, pos, role = "declared here"):
    return {"file": cv["file"], "pos": pos, "role": role}

def _err(cv, pos, msg):
    report(cv["st"], _at(cv, pos, None), msg)

def declare_tparams(cv, tparams, level):
    """Bind a def's type parameters in cv as fresh variables at level
    (GENERIC: the variables of a type scheme). Returns them."""
    out = []
    for tp in tparams:
        if tp["name"] in SIMPLE or tp["name"] in ARITY or tp["name"] in ["tuple", "struct"]:
            _err(cv, tp["pos"], "type parameter '" + tp["name"] + "' has the name of a type")
        v = new_var(cv["st"], tp["kind"], level)
        v["name"] = tp["name"]
        cv["tvars"][tp["name"]] = {"kind": tp["kind"], "val": v}
        out.append(v)
    for i, tp in enumerate(tparams):
        v = out[i]
        for b in tp["bounds"]:
            if b[0] == "among":
                for n in b[1]:
                    if n not in SIMPLE and n not in ARITY and n != "tuple":
                        _err(cv, b[2], "unknown type '" + n + "' in the bound of " + tp["name"])
                v["preds"].append({"kind": "among", "subj": v, "args": [], "op": b[1], "ctx": _at(cv, b[2])})
                continue
            _, name, args, pos = b
            ctx = _at(cv, pos, "bound of " + tp["name"])
            if name == "HasAttr":
                if len(args) != 2 or type(args[0]) != "string" or type(args[1]) == "string":
                    _err(cv, pos, "HasAttr takes a field name and a type: HasAttr[\"name\", T]")
                    continue
                v["preds"].append({"kind": "hasattr", "subj": v, "args": [to_type(cv, args[1])], "op": args[0], "ctx": ctx})
                continue
            if len([a for a in args if type(a) == "string"]) > 0:
                _err(cv, pos, "unexpected string in the bound " + name)
                continue
            proto = PROTOS.get(name)
            rname = name[1:] if name.startswith("R") else ""
            if proto != None:
                if len(args) != proto[1]:
                    _err(cv, pos, name + " takes " + str(proto[1]) + " type argument" + ("" if proto[1] == 1 else "s"))
                    continue
                v["preds"].append({"kind": proto[0], "subj": v, "args": [to_type(cv, a) for a in args], "op": None, "ctx": ctx})
            elif name in BINOP_BY_NAME or rname in BINOP_BY_NAME:
                if len(args) != 2:
                    _err(cv, pos, name + " takes 2 type arguments: the other operand and the result")
                    continue
                a = [to_type(cv, x) for x in args]
                if name in BINOP_BY_NAME:
                    v["preds"].append({"kind": "binop", "op": BINOP_BY_NAME[name], "l": v, "r": a[0], "res": a[1], "subj": v, "args": a, "ctx": ctx})
                else:
                    v["preds"].append({"kind": "rbinop", "op": BINOP_BY_NAME[rname], "l": a[0], "r": v, "res": a[1], "subj": v, "args": a, "ctx": ctx})
            else:
                cands = list(PROTOS.keys()) + list(BINOP_BY_NAME.keys()) + ["R" + n for n in BINOP_BY_NAME.keys()] + ["HasAttr"]
                n = nearest(name, cands)
                _err(cv, pos, "unknown bound '" + name + "'" + (" (did you mean '" + n + "'?)" if n else "") +
                              "; the bounds are " + ", ".join(sorted(PROTOS.keys())) + ", HasAttr, the operators (Add, Sub, Mul, ...) and `(type, type, ...)`")
    return out

def to_type(cv, a):
    """The checker's type for type AST a. Errors are reported (the result
    is then Any where it went wrong)."""
    st = cv["st"]
    k = a["t"]
    pos = a["pos"]
    if k == "opt":
        return mk_opt(to_type(cv, a["arg"]), _at(cv, pos))
    if k == "literal":
        return lab(lit(a["val"]), _at(cv, pos))
    if k == "fn":
        return fn(to_params(cv, a["params"], None), to_type(cv, a["ret"]), _at(cv, pos))
    if k == "struct":
        items = []
        for f in a["fields"]:
            if f[0] == "row":
                tv = cv["tvars"].get(f[1])
                if tv == None or tv["kind"] != "row":
                    _err(cv, f[2], "'" + f[1] + "' is not a row parameter: declare it as `**" + f[1] + "` in the def's type parameters, e.g. def f[**" + f[1] + "](...)")
                    items.append(new_var(st, "row", cv["level"]))
                else:
                    items.append(tv["val"])
                continue
            _, name, ft, fpos, quoted = f
            tv = cv["tvars"].get(name)
            if tv != None and tv["kind"] == "label" and not quoted:
                label = tv["val"]
            else:
                label = lit(name)
                for it in items:
                    if it["k"] == "f" and it["label"]["k"] == "lit" and it["label"]["name"] == name:
                        _err(cv, fpos, "field '" + name + "' is repeated")
            items.append(field(label, to_type(cv, ft), _at(cv, fpos)))
        return rec(row(items), _at(cv, pos))
    if k == "unit":
        _err(cv, pos, "`()` is not a type (the empty tuple type is tuple[()])")
        return T_ANY
    if k == "ellipsis":
        _err(cv, pos, "`...` is not a type here (it goes last in tuple[T, ...])")
        return T_ANY
    if k == "group":
        _err(cv, pos, "a bracketed list of types is only for Callable[[A, B], R]")
        return T_ANY
    name = SYNONYMS.get(a["name"], a["name"])
    args = a["args"]
    tv = cv["tvars"].get(a["name"])
    if tv != None:
        name = a["name"]
    if tv != None:
        if args != None:
            _err(cv, pos, "type parameter '" + name + "' takes no arguments")
        if tv["kind"] == "row":
            _err(cv, pos, "'" + name + "' is a row parameter: it stands for fields, so it goes in a struct type as struct[**" + name + "]")
            return T_ANY
        if tv["kind"] == "label":
            return lab(tv["val"], _at(cv, pos))
        return tv["val"]
    alias = cv["aliases"].get(name)
    if alias != None:
        want = len(alias["tparams"])
        if len(args or []) != want:
            _err(cv, pos, "'" + name + "' takes " + str(want) + " type argument" + ("" if want == 1 else "s"))
            return T_ANY
        if cv["expanding"].get(name, False):
            _err(cv, pos, "type alias '" + name + "' is defined in terms of itself")
            return T_ANY
        inner = dict(cv)
        inner["tvars"] = {}
        inner["expanding"] = dict(cv["expanding"])
        inner["expanding"][name] = True
        for i, tp in enumerate(alias["tparams"]):
            if tp["kind"] != "type" or tp["bounds"]:
                _err(cv, tp["pos"], "the parameters of a type alias are plain type parameters")
            inner["tvars"][tp["name"]] = {"kind": "type", "val": to_type(cv, args[i])}
        return to_type(inner, alias["type"])
    if name in SIMPLE:
        if args != None:
            _err(cv, pos, name + " takes no type arguments")
        return con(name, [], _at(cv, pos))
    if name in ARITY:
        n = ARITY[name]
        if args == None:
            return con(name, [T_ANY] * n, _at(cv, pos))
        if len(args) != n:
            _err(cv, pos, name + " takes " + str(n) + " type argument" + ("" if n == 1 else "s") + ": " + ("dict[K, V]" if n == 2 else name + "[T]"))
            return T_ANY
        return con(name, [to_type(cv, x) for x in args], _at(cv, pos))
    if name == "tuple":
        if args == None:
            return con("vtuple", [T_ANY], _at(cv, pos))
        if len(args) == 1 and args[0]["t"] == "unit":
            return con("tuple", [], _at(cv, pos))
        if len(args) == 2 and args[1]["t"] == "ellipsis":
            return con("vtuple", [to_type(cv, args[0])], _at(cv, pos))
        return con("tuple", [to_type(cv, x) for x in args], _at(cv, pos))
    if name == "struct":
        return _bare_struct(cv, pos)
    if name == "Optional":
        if args == None or len(args) != 1:
            _err(cv, pos, "Optional takes 1 type argument: Optional[T], which is T | None")
            return T_ANY
        return mk_opt(to_type(cv, args[0]), _at(cv, pos))
    if name == "Callable":
        if args == None or len(args) != 2 or args[0]["t"] != "group":
            _err(cv, pos, "Callable is written Callable[[A, B], R], which is (A, B) -> R")
            return T_ANY
        ps = [param(None, to_type(cv, x)) for x in args[0]["types"]]
        return fn(ps, to_type(cv, args[1]), _at(cv, pos))
    cands = KNOWN + list(cv["tvars"].keys()) + list(cv["aliases"].keys())
    n = nearest(name, cands)
    msg = "unknown type '" + name + "'"
    if name in MISNOMERS:
        msg += " (did you mean '" + MISNOMERS[name] + "'?)"
    elif n != "":
        msg += " (did you mean '" + n + "'?)"
    elif len(name) <= 2 and name.upper() == name:
        msg += " (a type parameter must be declared in brackets after the def's name: def f[" + name + "](...))"
    _err(cv, pos, msg)
    return T_ANY

def _bare_struct(cv, pos):
    _err(cv, pos, "struct needs its fields: struct[name: type, ...] (struct[] has none; struct[**R] has any, in a def with type parameter **R)")
    return T_ANY

def to_params(cv, params, missing):
    """The checker's parameters for parsed ones. A parameter with no type
    gets the type `missing` (None: it is then an error, for function types)."""
    out = []
    for q in params:
        if q["type"] != None:
            t = to_type(cv, q["type"])
        elif missing == None:
            _err(cv, q["pos"], "parameter '" + (q["name"] or "?") + "' of a function type needs a type")
            t = T_ANY
        else:
            t = missing
        out.append(param(q["name"], t, q["opt"], q["star"], q["kw"]))
    return out

def tail_check(cv, tparams, vars, t):
    """The paper's tail check (Fig. 7), for a declared signature t: a row
    parameter must end some struct type, and a field-name parameter must be
    the type of some value or name the last field of some struct type, or
    how they are instantiated would not decide the types of the fields
    after them."""
    ok = {}
    used = {}
    _tails(resolve(t), ok, used)
    for i, tp in enumerate(tparams):
        v = vars[i]
        if v["id"] in used and v["id"] not in ok:
            if tp["kind"] == "row":
                _err(cv, tp["pos"], "row parameter '" + tp["name"] + "' never ends a struct type (as in struct[x: int, **" + tp["name"] +
                                    "]): where it is used, fields follow it, and it may hide them")
            elif tp["kind"] == "label":
                _err(cv, tp["pos"], "field name parameter '" + tp["name"] + "' is neither the type of a parameter (name: " + tp["name"] +
                                    ") nor the last field of a struct type: nothing says which field it is")

def _tails(t, ok, used):
    k = t["k"]
    if k == "con":
        for a in t["args"]:
            _tails(resolve(a), ok, used)
    elif k == "fn":
        for p in t["params"]:
            _tails(resolve(p["type"]), ok, used)
        _tails(resolve(t["ret"]), ok, used)
    elif k == "lab":
        l = resolve_label(t["label"])
        if l["k"] == "var":
            ok[l["id"]] = True
            used[l["id"]] = True
    elif k == "rec":
        items = flatten(t["row"])
        for i, it in enumerate(items):
            last = i == len(items) - 1
            if it["k"] == "var":
                used[it["id"]] = True
                if last:
                    ok[it["id"]] = True
            else:
                l = resolve_label(it["label"])
                if l["k"] == "var":
                    used[l["id"]] = True
                    if last:
                        ok[l["id"]] = True
                _tails(resolve(it["type"]), ok, used)

def split_decls(cv, decls, where):
    """Sort declarations into (vars, defs, aliases) by name, reporting
    names declared twice. where: "" or the enclosing def's name."""
    vars = {}
    defs = {}
    aliases = {}
    for d in decls:
        name = d["name"]
        if name in vars or name in defs or name in aliases:
            _err(cv, d["pos"], "'" + name + "' is declared twice" + (" in " + where if where else ""))
            continue
        if d["d"] == "var":
            vars[name] = d
        elif d["d"] == "def":
            defs[name] = d
        else:
            aliases[name] = d
    return vars, defs, aliases
