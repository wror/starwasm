# ext/dir.star — dir() with no arguments, as in Python (EXTENSIONS.md).
#
# starlark-go's dir takes exactly one argument. Here dir() lists the names
# bound in the current scope, sorted: called directly (direct_call) or
# through a value such as `f = dir; f()` (dynamic_call). The names a scope
# can hold are known statically, so the list is built with one boundness
# test per name: no frames or name tables at run time.

load(
    "../../lib/dsl.star",
    "arr_fixed",
    "as_",
    "call",
    "field",
    "get",
    "gget",
    "i32",
    "if_",
    "null",
    "op",
    "set",
)
load("../../lib/runtime.star", "S")
load("../../lib/wasm.star", "EQREF")

V = EQREF

def _dir_key(mc):
    """The Wasm name of the prelude's dir, or None if the program never
    mentions dir (then it can't be called, directly or as a value)."""
    if mc["mod"].get("prelude", False):
        return None  # the prelude never means this dir()
    return mc["prelude"]["funcs"].get("dir")

def direct_call(cg, mc, fc, e, kind, w):
    """`dir()` naming the builtin."""
    fn = e["fn"]
    key = _dir_key(mc)
    if key == None or e["args"] or fn["kind"] != "name" or fn["id"] != "dir" or kind != "func" or w != key:
        return None
    return gen_dir(cg, mc, fc)

def dynamic_call(cg, mc, fc, callee, e):
    """f() through a value with no arguments, in a program that mentions
    dir: if f is dir, list this call site's scope; else an ordinary call."""
    key = _dir_key(mc)
    if key == None or e["args"]:
        return None
    f = cg["temp"](fc, V)
    return [
        set(f, callee),
        if_(op("ref.eq", get(f), gget("fv_" + key)), gen_dir(cg, mc, fc),
            cg["callat"](mc, e["lparen"], "rt_call", get(f), arr_fixed("Vals"), null("eq")), result = V),
    ]

def gen_dir(cg, mc, fc):
    """A sorted list of the names bound at this point in the current scope.
    In a function: its parameters and locals that have been assigned, plus
    the variables it captures from enclosing functions (those it or its
    inner functions use) that are bound; at top level: the module's
    globals, defs and loaded names bound so far. Inside a comprehension
    its variables are included too (as Python >= 3.12). Builtins never
    are."""
    m = mc["m"]
    names = {}
    if fc["fscope"] != None:
        for name in fc["fscope"]["bindings"]:
            names[name] = True
        for name in fc["fscope"]["free"]:
            names[name] = True
    else:
        mod = mc["mod"]
        for d in [mod["funcs"], mod["globals"], mod["aliases"]]:
            for name in d:
                names[name] = True
    for sc in fc["scopes"]:
        for name in sc["wasm"]:
            names[name] = True
    res = cg["temp"](fc, V)
    code = [set(res, call("rt_list_new", i32(0)))]
    for name in sorted(names):
        kind, w = cg["lookup"](mc, fc, name, None)
        app = call("rt_list_append", as_("List", get(res)), S(m, name))
        if kind == "scope" or kind == "param":
            code.append(app)
            continue
        if kind == "local" or kind == "scope_u":
            v = get(w)
        elif kind == "cell":
            v = field("Cell", "v", get(w))
        elif kind == "free":
            v = field("Cell", "v", cg["free_cell"](w))
        elif kind == "global":
            v = gget(w)
        elif kind == "func":
            v = gget("fv_" + w)
        else:
            fail("internal error: dir() of " + kind + " " + name)
        code.append(if_(op("i32.eqz", op("ref.is_null", v)), app))
    code.append(get(res))
    return code
