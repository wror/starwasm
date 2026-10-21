# codegen.star — AST to a Wasm module, via the runtime in lib/.
#
# Model:
#   - Each top-level `def f` becomes Wasm function "f_f" (all params and the
#     result eqref). Calls naming a top-level def directly are resolved at
#     compile time (keyword args, defaults, *args, **kwargs): no runtime
#     argument matching.
#   - Every function is also usable as a value: a $Func struct with a
#     dynamic entry point "dyn_..." (type $Code) that matches arguments at
#     run time with rt_bind and then calls the body. Calls through values
#     (closures, parameters, f(*args), ...) go via rt_call -> call_ref.
#   - Nested defs and lambdas compile to body functions whose first param is
#     "%env": the captured cells. Captured variables (see resolve.star) live
#     in $Cell structs, so closures see later assignments (late binding).
#   - Defaults are evaluated when the def/lambda executes. For top-level
#     defs they're kept in globals "d_<func>_<param>"; for closures, in the
#     $Func's defaults array.
#   - Module-level variables are mutable eqref globals "g_<name>"; function
#     locals are eqref locals; both null until assigned, and reading a null
#     variable fails with "... referenced before assignment".
#   - Module-level statements run in the exported function "main".
#
#   - load(): every module reachable from the main file is compiled into the
#     same Wasm module. Module-level names are qualified per module
#     ("m<id>.name"; main module unqualified). Loaded names resolve at
#     compile time to the defining module's def or global, so calls to
#     loaded functions stay static. Each module's top level is a function
#     init<id> that runs once, at its first load().
#
#   - Builtins are values too: generated ones get a wrapper function
#     ("bi_<name>") and a $Func created on first use; builtins written in
#     Starlark (lib/prelude.star) are ordinary functions. Their Sig.kind is
#     nonzero, so they print as "<built-in function len>".
#   - x.name that is not called compiles to the prelude's _attr(x, "name"):
#     a struct field, or a bound method ($Bound) whose function comes from
#     the method table "method_funcs" that main fills in (only methods the
#     program may take as values).
#
# Not yet supported (clear compile errors): keyword args to generated
# builtins other than sorted(), floats.

load("../lib/wasm.star", "EQREF", "I32", "I64", "add_custom", "add_func", "add_global", "encode", "new_module", "ref", "uleb", "utf8")
load(
    "../lib/dsl.star",
    "and_",
    "arr_fixed",
    "arr_get",
    "arr_len",
    "as_",
    "block",
    "br",
    "br_if",
    "call",
    "drop",
    "eqz",
    "field",
    "get",
    "gget",
    "gset",
    "i32",
    "i64",
    "if_",
    "inc",
    "loop",
    "new",
    "non_null",
    "null",
    "op",
    "or_",
    "ret",
    "select_",
    "set",
    "setfield",
    "tee",
)
load("../lib/runtime.star", "S", "add_runtime", "add_unicode_tables", "vi")
load("../lib/builtins.star", "METHODS", "add_builtins", "add_test_builtins")
load("parser.star", "parse_file")
load("resolve.star", "collect_bindings", "resolve_module", "target_names")
load("spell.star", "nearest")
load("../lib/prelude.star", "PRELUDE")

V = EQREF
NONE = gget("None")

# Runtime function for each binary operator (value result).
ARITH = {
    "+": "rt_add",
    "-": "rt_sub",
    "*": "rt_mul",
    "//": "rt_floordiv",
    "/": "rt_div",
    "%": "rt_percent",  # string formatting or int modulo
    "&": "rt_and",
    "|": "rt_or",
    "^": "rt_xor",
    "<<": "rt_shl",
    ">>": "rt_shr",
}

# Comparisons: runtime function returning i32, and whether to negate it.
COMPARE = {
    "==": ("rt_eq", False),
    "!=": ("rt_eq", True),
    "<": ("rt_lt", False),
    ">": ("rt_gt", False),
    "<=": ("rt_le", False),
    ">=": ("rt_ge", False),
    "in": ("rt_in", False),
    "not in": ("rt_in", True),
}

# Builtin functions: name -> (min args, max args).
BUILTINS = {
    "print": (0, 1000),
    "fail": (0, 1000),
    "len": (1, 1),
    "str": (1, 1),
    "repr": (1, 1),
    "type": (1, 1),
    "bool": (0, 1),
    "list": (0, 1),
    "tuple": (0, 1),
    "range": (1, 3),
    "enumerate": (1, 2),
    "ord": (1, 1),
    "chr": (1, 1),
    "abs": (1, 1),
    "read_file": (1, 1),
    "write_file": (2, 2),
    "sorted": (1, 1),  # plus key= and reverse= keywords
    "hash": (1, 1),
    "float": (0, 1),
    # Primitives for lib/prelude.star only (names starting with "_" are not
    # visible to user code):
    "_error": (1, 1),
    "_error_plain": (1, 1),
    "_find": (4, 4),
    "_rfind": (4, 4),
    "_bytes_to_str": (1, 1),
    "_frozen": (1, 1),
    "_iterating": (1, 1),
    "_set_new": (0, 0),
    "_int_of": (1, 1),
    "_case": (2, 2),
    "_classify": (2, 2),
    "_absent": (0, 0),
    "_is_absent": (1, 1),
    "_set_dict": (1, 1),
    "_unhashable": (1, 1),
    "_to_bytes": (1, 1),
    "_struct_new": (1, 1),
    "_struct_dict": (1, 1),
    "_bound": (2, 2),
    "_nearest": (2, 2),
    # Test-only builtins (programs compiled with --test; see TEST_BUILTINS):
    "test_catch": (1, 1),
    "test_error": (1, 1),
    "test_matches": (2, 2),
    "test_freeze": (1, 1),
    "test_floateq": (2, 2),
}

# Builtins visible only when compiling with --test (tests/upstream/ runs
# starlark-go's own test files with them; add_test_builtins in
# lib/builtins.star documents them). Other programs get "undefined".
TEST_BUILTINS = {"test_catch": True, "test_error": True, "test_matches": True, "test_freeze": True, "test_floateq": True}

SIMPLE_BUILTINS = {
    "len": "rt_len",
    "str": "rt_str",
    "repr": "rt_repr",
    "type": "rt_type",
    "ord": "rt_ord",
    "chr": "rt_chr",
    "abs": "rt_abs",
    "read_file": "rt_read_file",
    "write_file": "rt_write_file",
    "hash": "rt_hash_builtin",
    "_error": "rt_error",
    "_error_plain": "rt_error_plain",
    "_find": "rt_find",
    "_rfind": "rt_rfind",
    "_bytes_to_str": "rt_bytes_to_str",
    "_frozen": "rt_frozen",
    "_iterating": "rt_iterating",
    "_set_new": "rt_set_new",
    "_int_of": "rt_int_of",
    "_case": "rt_case_v",
    "_classify": "rt_class_v",
    "_absent": "rt_absent",
    "_is_absent": "rt_is_absent",
    "_set_dict": "rt_set_dict",
    "_unhashable": "rt_unhashable",
    "_to_bytes": "rt_to_bytes",
    "_struct_new": "rt_struct_new",
    "_struct_dict": "rt_struct_dict",
    "_bound": "rt_bound",
    "_nearest": "rt_nearest_v",
    "test_catch": "rt_test_catch",
    "test_error": "rt_test_error",
    "test_matches": "rt_test_matches",
    "test_freeze": "rt_test_freeze",
    "test_floateq": "rt_test_floateq",
}

# Predeclared values: name -> Wasm global. argv (a list of strings, as in
# bin/starhost) is filled in at the start of main.
CONSTANTS = {"None": "None", "True": "True", "False": "False", "argv": "argv"}

MAX_I64 = 9223372036854775807

# starlark-go fails a call with "Starlark stack overflow" when the thread's
# stack already holds this many frames (counting the module's top level).
MAX_CALL_DEPTH = 100000

# ---------------------------------------------------------------- errors

def cerr(mc, posn, msg):
    fail(mc["file"] + ":" + str(posn[0]) + ":" + str(posn[1]) + ": " + msg)

# ---------------------------------------------------------------- contexts

def new_fc(name, fscope, has_env):
    return {
        "name": name,
        "is_module": fscope == None,
        "fscope": fscope,  # resolver scope of this function (None: module)
        "has_env": has_env,  # has a "%env" param holding captured cells
        "wlocals": [],  # Wasm locals besides params: (name, type)
        "ntemp": 0,
        "scopes": [],  # active comprehension scopes, innermost last
        "loops": 0,
        "iters": [],  # loop_setup infos of the enclosing for loops (for return)
        "depth": False,  # counts itself in call_depth (see gen_function)
    }

def temp(fc, typ):
    name = "%t" + str(fc["ntemp"])
    fc["ntemp"] += 1
    fc["wlocals"].append((name, typ))
    return name

def cell_local(name):
    return "%cell." + name

def lookup(mc, fc, name, posn, early = None):
    """Resolve a name for reading. Returns (kind, x):
      scope   comprehension variable, x = Wasm local (always bound)
      param   function parameter, x = Wasm local (always bound)
      local   function local, x = Wasm local
      cell    captured variable bound here, x = Wasm local holding the $Cell
      free    variable captured from an enclosing function, x = index in %env
      func    top-level def, x = name
      global  module variable, x = Wasm global
      const   predeclared value, x = Wasm global
      builtin builtin function, x = name
    early: for a top-level use before any binding of the name
    (resolve.star), the top-level names bound so far: module variables
    don't count yet."""
    scopes = fc["scopes"]
    for i in range(len(scopes) - 1, -1, -1):
        w = scopes[i]["wasm"].get(name)
        if w != None:
            return w
    fs = fc["fscope"]
    if fs != None:
        b = fs["bindings"].get(name)
        if b != None:
            if b["cell"]:
                return ("cell", cell_local(name))
            if b["param"]:
                return ("param", name)
            return ("local", name)
        idx = fs["free_index"].get(name)
        if idx != None:
            return ("free", idx)
    r = None if early != None else lookup_module(mc, mc["mod"], name)
    if r != None:
        return r
    if CONSTANTS.get(name) != None:
        return ("const", CONSTANTS[name])
    in_prelude = mc["mod"].get("prelude", False)
    pre = mc["prelude"]
    if not in_prelude and not name.startswith("_") and pre["funcs"].get(name) != None:
        return ("func", pre["funcs"][name])  # a builtin written in Starlark
    if BUILTINS.get(name) != None and (in_prelude or not name.startswith("_")) and (mc["test"] or not TEST_BUILTINS.get(name, False)):
        return ("builtin", name)
    cerr(mc, posn, "undefined: " + name + spell_hint(name, early if early != None else visible_names(mc, fc)))

def spell_hint(name, names):
    """ " (did you mean x?)" for the name nearest to name, or ""."""
    n = nearest(name, sorted(names))
    return "" if n == "" else " (did you mean " + n + "?)"

def visible_names(mc, fc):
    """Names a spelling hint for an undefined name may suggest, as
    starlark-go's resolver: those of the enclosing blocks and module
    globals (not builtins)."""
    names = {}
    for sc in fc["scopes"]:
        for n in sc["wasm"]:
            names[n] = True
    fs = fc["fscope"]
    for _ in range(1000):
        if fs == None:
            break
        for n in fs["bindings"]:
            names[n] = True
        fs = fs["parent"]
    mod = mc["mod"]
    for d in [mod["funcs"], mod["globals"], mod["aliases"]]:
        for n in d:
            names[n] = True
    return names.keys()

def lookup_module(mc, mod, name):
    """A module-level name of mod: ("func", key) for a top-level def,
    ("global", Wasm global) for a variable, following load() aliases into
    other modules; None if mod has no such name."""
    key = mod["funcs"].get(name)
    if key != None:
        return ("func", key)
    g = mod["globals"].get(name)
    if g != None:
        return ("global", g)
    a = mod["aliases"].get(name)
    if a != None:
        return lookup_module(mc, mc["mods"][a[0]], a[1])
    return None

def at(mc, posn, builtin = "", dotpos = None):
    """Source marker for the next instruction (see starwasm.marks): when a
    runtime error happens inside the call that follows, the host reports
    this position. `builtin` names the builtin being called, for starlark-go
    style "Error in <builtin>: ..." messages."""
    key = mc["file"] + ":" + str(posn[0]) + ":" + str(posn[1]) + ":" + builtin
    if dotpos != None:
        key += ":" + str(dotpos[0]) + ":" + str(dotpos[1])
    tag = mc["tags"].get(key)
    if tag == None:
        fi = mc["fileidx"].get(mc["file"])
        if fi == None:
            fi = len(mc["files"])
            mc["files"].append(mc["file"])
            mc["fileidx"][mc["file"]] = fi
        bi = -1
        if builtin != "":
            bi = mc["builtinidx"].get(builtin)
            if bi == None:
                bi = len(mc["builtins"])
                mc["builtins"].append(builtin)
                mc["builtinidx"][builtin] = bi
        tag = len(mc["poslist"])
        # dotpos: where attribute errors ("int has no .x field or method")
        # are reported for a method call, as starlark-go does
        dl, dc = (0, 0) if dotpos == None else dotpos
        mc["poslist"].append((fi, posn[0], posn[1], bi, dl, dc))
        mc["tags"][key] = tag
    return ("@pos", tag)

def callat(mc, posn, f, *args):
    """call(f, *args) with a source marker right before the call."""
    return [list(args), at(mc, posn), ("call", f)]

def callbi(mc, posn, builtin, f, *args):
    """callat for the implementation of builtin `builtin`."""
    return [list(args), at(mc, posn, builtin), ("call", f)]

def callmeth(mc, posn, dotpos, method, f, *args):
    """callbi for a method call x.method(...): attribute errors are
    reported at the dot."""
    return [list(args), at(mc, posn, method, dotpos), ("call", f)]

def checked(mc, get_code, kind, name, posn):
    """Read a variable that might be unbound; fail with its name if so."""
    return [
        ("block", ref("eq"), "bound"),
        get_code,
        ("br_on_non_null", "bound"),
        S(mc["m"], name),
        at(mc, posn),
        call("rt_unbound_" + kind),
        "unreachable",
        "end",
    ]

def free_cell(idx):
    return as_("Cell", arr_get("Vals", get("%env"), i32(idx)))

def cell_ref(mc, fc, name, posn):
    """Code for the $Cell of a captured variable, to hand to a closure."""
    kind, w = lookup(mc, fc, name, posn)
    if kind == "cell":
        return get(w)
    if kind == "free":
        return arr_get("Vals", get("%env"), i32(w))
    cerr(mc, posn, "internal error: " + name + " is not a captured variable here (" + kind + ")")

# ---------------------------------------------------------------- expressions

def gen(mc, fc, e):
    m = mc["m"]
    k = e["kind"]
    if k == "int":
        return vi(e["val"])
    if k == "string":
        return S(m, e["val"])
    if k == "bytes":
        return new("Bytes", i32(0), arr_fixed("U8", *[i32(b) for b in e["val"]]))
    if k == "float":
        return float_const(mc, e["val"])
    if k == "%code":
        return e["code"]  # already generated (see gen_call)
    if k == "name":
        return gen_name(mc, fc, e)
    if k == "list":
        elems = [gen(mc, fc, x) for x in e["elems"]]
        return new("List", i32(len(elems)), arr_fixed("Vals", *elems), i32(0))
    if k == "tuple":
        return new("Tuple", arr_fixed("Vals", *[gen(mc, fc, x) for x in e["elems"]]))
    if k == "dict":
        d = temp(fc, V)
        code = [set(d, call("rt_dict_new"))]
        for i, (key, val) in enumerate(e["entries"]):
            # a repeated key is an error, as in starlark-go (SETDICTUNIQ)
            code.append(callat(mc, e["colons"][i], "rt_dict_set_uniq", as_("Dict", get(d)), gen(mc, fc, key), gen(mc, fc, val)))
        code.append(get(d))
        return code
    if k == "binop":
        return gen_binop(mc, fc, e)
    if k == "unop":
        op_ = e["op"]
        x = gen(mc, fc, e["x"])
        if op_ == "-":
            return callat(mc, e["pos"], "rt_neg", x)
        if op_ == "+":
            return callat(mc, e["pos"], "rt_pos", x)
        if op_ == "~":
            return callat(mc, e["pos"], "rt_invert", x)
        return call("rt_not", x)
    if k == "cond":
        return if_(gen_cond(mc, fc, e["test"]), gen(mc, fc, e["then"]), gen(mc, fc, e["else_"]), result = V)
    if k == "call":
        return gen_call(mc, fc, e)
    if k == "index":
        return callat(mc, e["pos"], "rt_index", gen(mc, fc, e["x"]), gen(mc, fc, e["i"]))
    if k == "slice":
        parts = [gen(mc, fc, e["x"])]
        for part in [e["lo"], e["hi"], e["step"]]:
            parts.append(null("eq") if part == None else gen(mc, fc, part))
        # starlark-go reports a slice error at the last position recorded
        # while evaluating its operands (else at the "[")
        posn = e["pos"]
        for part in [e["x"], e["lo"], e["hi"], e["step"]]:
            if part != None:
                q = last_leaf(mc, fc, part)
                if q != None:
                    posn = q
        return callat(mc, posn, "rt_slice", *parts)
    if k == "comp":
        return gen_comp(mc, fc, e)
    if k == "lambda":
        return gen_closure(mc, fc, e, "lambda", e["params"])
    if k == "dot":
        # x.name: a struct field or a bound method; errors are reported
        # plainly, at the "."
        key = mc["prelude"]["funcs"]["_attr"]
        return callmeth(mc, e["pos"], e["pos"], "", "f_" + key, gen(mc, fc, e["x"]), S(m, e["name"]))
    cerr(mc, e["pos"], "internal error: unknown expression kind " + k)

def float_const(mc, text):
    """Code for the float literal `text`: parsed by the runtime (and the
    host) the first time it is evaluated, then kept in a global, so the
    compiler needs no float arithmetic of its own."""
    m = mc["m"]
    fn = mc["floats"].get(text)
    if fn == None:
        idx = len(mc["floats"])
        g = "flt" + str(idx)
        fn = "fltconst" + str(idx)
        add_global(m, g, V, True, [null("eq")])
        add_func(m, fn, [], [V], [
            if_(op("ref.is_null", gget(g)), gset(g, call("rt_parse_float", as_("Str", S(m, text))))),
            gget(g),
        ])
        mc["floats"][text] = fn
    return call(fn)

def gen_name(mc, fc, e):
    m = mc["m"]
    name = e["id"]
    kind, w = lookup(mc, fc, name, e["pos"], e.get("early"))
    if kind == "scope" or kind == "param":
        return get(w)
    posn = e["pos"]
    if kind == "scope_u":  # a comprehension variable not bound yet
        return checked(mc, get(w), "local", name, posn)
    if kind == "local":
        return checked(mc, get(w), "local", name, posn)
    if kind == "cell":
        return checked(mc, field("Cell", "v", get(w)), "local", name, posn)
    if kind == "free":
        return checked(mc, field("Cell", "v", free_cell(w)), "local", name, posn)
    if kind == "global":
        return checked(mc, gget(w), "global", name, posn)
    if kind == "const":
        return gget(w)
    if kind == "func":
        return checked(mc, gget("fv_" + w), "global", name, posn)
    return builtin_value(mc, name, e["pos"])

def bparam(name, star = "", default = None):
    """A parameter of a builtin's wrapper function (shaped like the
    parser's). default: code for its default value, or None."""
    return {"name": name, "default": default, "star": star, "pos": (0, 0)}

ABSENT = gget("Absent")

def unabsent(name):
    """A wrapper parameter, with "omitted" turned into null (what rt_*
    functions expect for an optional argument)."""
    return select_(op("ref.eq", get(name), ABSENT), null("eq"), get(name), V)

def is_absent(name):
    return op("ref.eq", get(name), ABSENT)

def builtin_wrapper(mc, name):
    """(params, Sig kind, body) of the function wrapping builtin `name` when
    it is used as a value."""
    lo, hi = BUILTINS[name]
    if name == "print":
        params = [bparam("args", "*"), bparam("sep", default = ABSENT)]
        return params, 2, [call("rt_print_args", field("Tuple", "items", as_("Tuple", get("args"))), unabsent("sep")), NONE]
    if name == "fail":
        params = [bparam("args", "*"), bparam("sep", default = ABSENT)]
        return params, 2, [call("rt_fail_args", field("Tuple", "items", as_("Tuple", get("args"))), unabsent("sep")), "unreachable"]
    if name == "enumerate":
        return [bparam("x"), bparam("start", default = ABSENT)], 1, [call("rt_enumerate", get("x"), unabsent("start"))]
    if name == "str" or name == "type":
        # starlark-go's own messages: "str: got 2 arguments, want exactly 1"
        m = mc["m"]
        items = field("Tuple", "items", as_("Tuple", get("args")))
        return [bparam("args", "*"), bparam("kwargs", "**")], 2, [
            if_(field("Dict", "len", as_("Dict", get("kwargs"))), [S(m, name + " does not accept keyword arguments"), call("rt_fail"), "unreachable"]),
            if_(op("i32.ne", arr_len(items), i32(1)), [
                S(m, name + ": got "), call("rt_str", call("rt_len", get("args"))), call("rt_str_concat"),
                S(m, " arguments, want exactly 1"), call("rt_str_concat"), call("rt_fail"), "unreachable",
            ]),
            call(SIMPLE_BUILTINS[name], arr_get("Vals", items, i32(0))),
        ]
    if name == "sorted":
        params = [bparam("iterable"), bparam("key", default = ABSENT), bparam("reverse", default = gget("False"))]
        return params, 2, [call("rt_sorted", get("iterable"), get("key"), call("rt_truth", get("reverse")), i32(0))]
    if name == "bool":
        return [bparam("x", default = ABSENT)], 1, [
            if_(is_absent("x"), gget("False"), call("rt_bool", call("rt_truth", get("x"))), result = V),
        ]
    if name == "float":
        # float(*args): starlark-go's own message for extra arguments
        items = field("Tuple", "items", as_("Tuple", get("args")))
        return [bparam("args", "*")], 1, [
            if_(op("i32.gt_u", arr_len(items), i32(1)), [
                S(mc["m"], "float got "), call("rt_str", call("rt_len", get("args"))), call("rt_str_concat"),
                S(mc["m"], " arguments, wants 1"), call("rt_str_concat"), call("rt_fail"), "unreachable",
            ]),
            if_(eqz(arr_len(items)), call("rt_float", op("f64.convert_i64_s", i64(0))), call("rt_float_of", arr_get("Vals", items, i32(0))), result = V),
        ]
    if name == "list":
        return [bparam("x", default = ABSENT)], 1, [
            if_(is_absent("x"), call("rt_list_new", i32(0)), call("rt_list_of", get("x")), result = V),
        ]
    if name == "tuple":
        return [bparam("x", default = ABSENT)], 1, [
            if_(is_absent("x"), new("Tuple", arr_fixed("Vals")), call("rt_tuple_of", get("x")), result = V),
        ]
    if name == "range":
        params = [bparam("a"), bparam("b", default = ABSENT), bparam("c", default = ABSENT)]
        return params, 1, [
            if_(is_absent("b"), call("rt_range", vi(0), get("a"), vi(1), i32(1)),
                if_(is_absent("c"), call("rt_range", get("a"), get("b"), vi(1), i32(2)),
                    call("rt_range", get("a"), get("b"), get("c"), i32(3)), result = V), result = V),
        ]
    if SIMPLE_BUILTINS.get(name) != None and lo == hi:
        params = [bparam("x" + str(i)) for i in range(lo)]
        return params, 1, [call(SIMPLE_BUILTINS[name], *[get(p["name"]) for p in params])]
    return None

def defaults_code(shape):
    """Code for a $Func's defaults array (null if no parameter has one);
    the parameters' defaults are code."""
    vals = []
    has = False
    for p in shape["slots"]:
        if p["default"] != None:
            has = True
            vals.append(p["default"])
        else:
            vals.append(null("eq"))
    return arr_fixed("Vals", *vals) if has else null("Vals")

def add_wrapper(mc, wname, display, params, kind, recv, body):
    """A hidden function wname (plus its dynamic entry and Sig) wrapping
    runtime code, for a builtin or method used as a value. Returns the code
    creating its $Func."""
    shape = param_slots(params)
    add_func(mc["m"], wname, [(p["name"], V) for p in shape["slots"]], [V], body)
    gen_dyn_entry(mc, "dyn_" + wname, wname, False, len(shape["slots"]))
    add_sig(mc, "sig_" + wname, display, shape, kind, recv)
    mc["funcinfo"].append((wname, "hidden", display, -1))
    mc["funcinfo"].append(("dyn_" + wname, "hidden", display, -1))
    return make_func("dyn_" + wname, "sig_" + wname, null("Vals"), defaults_code(shape))

def builtin_value(mc, name, posn):
    """A function value wrapping a generated builtin, created on first use."""
    m = mc["m"]
    g = "bv_" + name
    if not mc["builtin_values"].get(name):
        w = builtin_wrapper(mc, name)
        if w == None:
            cerr(mc, posn, name + " cannot be used as a value")
        params, kind, body = w
        mc["builtin_values"][name] = add_wrapper(mc, "bi_" + name, name, params, kind, 0, body)
        add_global(m, g, V, True, [null("eq")])
    return [
        if_(op("ref.is_null", gget(g)), gset(g, mc["builtin_values"][name])),
        gget(g),
    ]

def method_func(mc, name):
    """Code for the $Func behind bound methods x.<name>: the prelude's
    _m_<name>, or a wrapper around generated method rt_m_<name> (created on
    first use, in global mv_<name>)."""
    key = mc["prelude"]["funcs"].get("_m_" + name)
    if METHODS.get(name) == None:
        return gget("fv_" + key)
    g = "mv_" + name
    if not mc["builtin_values"].get("." + name):
        lo, hi = METHODS[name]
        names = ["a", "b"][:hi]
        params = [bparam("x")] + [bparam(n, default = ABSENT if i >= lo else None) for i, n in enumerate(names)]
        body = [call("rt_m_" + name, get("x"), *[unabsent(n) for n in names])]
        mc["builtin_values"]["." + name] = add_wrapper(mc, "bm_" + name, name, params, 1, 1, body)
        add_global(mc["m"], g, V, True, [null("eq")])
    return [
        if_(op("ref.is_null", gget(g)), gset(g, mc["builtin_values"]["." + name])),
        gget(g),
    ]

def gen_binop(mc, fc, e):
    op_ = e["op"]
    if op_ == "and" or op_ == "or":
        t = temp(fc, V)
        x = call("rt_truth", tee(t, gen(mc, fc, e["x"])))
        y = gen(mc, fc, e["y"])
        if op_ == "and":
            return if_(x, y, get(t), result = V)
        return if_(x, get(t), y, result = V)
    if COMPARE.get(op_) != None:
        return call("rt_bool", gen_cond(mc, fc, e))
    return callat(mc, e["pos"], ARITH[op_], gen(mc, fc, e["x"]), gen(mc, fc, e["y"]))

def gen_cond(mc, fc, e):
    """Code leaving an i32 truth value."""
    k = e["kind"]
    if k == "binop":
        op_ = e["op"]
        cmp = COMPARE.get(op_)
        if cmp != None:
            fn, negate = cmp
            c = callat(mc, e["pos"], fn, gen(mc, fc, e["x"]), gen(mc, fc, e["y"]))
            return eqz(c) if negate else c
        if op_ == "and":
            return and_(gen_cond(mc, fc, e["x"]), gen_cond(mc, fc, e["y"]))
        if op_ == "or":
            return or_(gen_cond(mc, fc, e["x"]), gen_cond(mc, fc, e["y"]))
    if k == "unop" and e["op"] == "not":
        return eqz(gen_cond(mc, fc, e["x"]))
    return call("rt_truth", gen(mc, fc, e))

# ---------------------------------------------------------------- calls

def check_plain_args(mc, e, what):
    for a in e["args"]:
        if a["star"] != "":
            cerr(mc, a["pos"], "*args/**kwargs are not supported in calls to " + what)
        if a["name"] != None:
            cerr(mc, a["pos"], what + " does not accept keyword arguments")

def has_star_args(e):
    for a in e["args"]:
        if a["star"] != "":
            return True
    return False

def gen_call(mc, fc, e):
    fn = e["fn"]
    args = e["args"]
    if fn["kind"] == "dot":
        name = fn["name"]
        m = mc["m"]
        known = METHODS.get(name) != None or mc["prelude"]["funcs"].get("_m_" + name) != None
        if not known:
            # x.name(...) where name is no method: a struct field (or an
            # error at run time: "list has no .frobnicate field or method")
            callee = callmeth(mc, fn["pos"], fn["pos"], "", "f_" + mc["prelude"]["funcs"]["_attr"], gen(mc, fc, fn["x"]), S(m, name))
            return gen_dynamic_call(mc, fc, callee, e)
        if not mc["has_struct"]:
            return gen_method_call(mc, fc, e, gen(mc, fc, fn["x"]))
        # Structs are about: a struct's field shadows the method.
        t = temp(fc, V)
        field_call = gen_dynamic_call(mc, fc, callmeth(mc, fn["pos"], fn["pos"], "", "rt_struct_attr", get(t), S(m, name)), e)
        return [
            set(t, gen(mc, fc, fn["x"])),
            if_(is_struct(get(t)), field_call, gen_method_call(mc, fc, e, get(t)), result = V),
        ]
    if fn["kind"] == "name":
        kind, w = lookup(mc, fc, fn["id"], fn["pos"])
        if kind == "func" and not has_star_args(e):
            fdef = mc["allfuncs"][w]
            code = gen_user_call(mc, fc, fdef, e, fdef["name"] if fdef.get("prelude", False) else "")
            if code != None:
                return code
        if kind == "builtin":
            code = gen_builtin_call(mc, fc, w, e)
            if code != None:
                return code
            return gen_dynamic_call(mc, fc, builtin_value(mc, w, fn["pos"]), e)
    return gen_dynamic_call(mc, fc, gen(mc, fc, fn), e)

def is_struct(code):
    return [code, ("ref.test", ref("Struct"))]

def gen_method_call(mc, fc, e, recv):
    """x.name(args) for a method of a builtin type; recv: code for x."""
    fn = e["fn"]
    name = fn["name"]
    args = e["args"]
    arity = METHODS.get(name)
    if arity == None:
        # A method written in Starlark: call _m_<name>(receiver, args...).
        key = mc["prelude"]["funcs"]["_m_" + name]
        if not has_star_args(e):
            rx = {"name": None, "star": "", "value": {"kind": "%code", "code": recv, "pos": fn["x"]["pos"]}, "pos": fn["x"]["pos"]}
            mcall = {"kind": "call", "fn": fn, "args": [rx] + args, "pos": e["pos"], "lparen": e["lparen"], "dot": fn["pos"]}
            code = gen_user_call(mc, fc, mc["allfuncs"][key], mcall, name)
            if code != None:
                return code
        return gen_bound_call(mc, fc, e, recv)
    plain = not has_star_args(e)
    for a in args:
        if a["name"] != None:
            plain = False
    if not plain or len(args) < arity[0] or len(args) > arity[1]:
        return gen_bound_call(mc, fc, e, recv)
    code = [recv]
    for a in args:
        code.append(gen(mc, fc, a["value"]))
    for _ in range(arity[1] - len(args)):
        code.append(null("eq"))
    return callmeth(mc, e["lparen"], fn["pos"], name, "rt_m_" + name, *code)

def gen_bound_call(mc, fc, e, recv):
    """x.name(args) through the bound method value: argument errors (wrong
    count, keywords, *args) then come from rt_bind at run time, with
    starlark-go's messages ("split: got 3 arguments, want at most 2")."""
    name = e["fn"]["name"]
    callee = new("Bound", recv, as_("Func", method_func(mc, name)), S(mc["m"], name))
    return gen_dynamic_call(mc, fc, callee, e)

def gen_dynamic_call(mc, fc, callee, e):
    """Call through a function value: rt_call(f, positional, kwargs)."""
    m = mc["m"]
    args = e["args"]
    simple = True
    for a in args:
        if a["star"] != "" or a["name"] != None:
            simple = False
    if simple:
        return callat(mc, e["lparen"], "rt_call", callee, arr_fixed("Vals", *[gen(mc, fc, a["value"]) for a in args]), null("eq"))

    # General case: build the positional list and keyword dict in source
    # order (Starlark evaluates arguments left to right).
    f = temp(fc, V)
    pos = temp(fc, V)
    kw = temp(fc, V)
    code = [set(f, callee), set(pos, call("rt_list_new", i32(0))), set(kw, null("eq"))]
    for a in args:
        val = gen(mc, fc, a["value"])
        if a["star"] == "*":
            code.append(callat(mc, e["lparen"], "rt_star_args", as_("List", get(pos)), val))
        elif a["star"] == "**" or a["name"] != None:
            code.append(if_(op("ref.is_null", get(kw)), set(kw, call("rt_dict_new"))))
            if a["star"] == "**":
                code.append(callat(mc, e["lparen"], "rt_kwargs_update", get(kw), val, get(f)))
            else:
                code.append(callat(mc, e["lparen"], "rt_kwargs_update", get(kw), call("rt_dict_from_pairs", arr_fixed("Vals", S(m, a["name"]), val)), get(f)))
        else:
            code.append(call("rt_list_append", as_("List", get(pos)), val))
    code.append(callat(mc, e["lparen"], "rt_call", get(f), call("rt_vals_of_list", get(pos)), get(kw)))
    return code

def gen_sorted(mc, fc, e):
    """sorted(x, key=None, reverse=False)"""
    pos = []
    key = null("eq")
    rev = i32(0)
    for a in e["args"]:
        if a["star"] != "":
            return None
        if a["name"] == None:
            pos.append(gen(mc, fc, a["value"]))
        elif a["name"] == "key":
            key = gen(mc, fc, a["value"])
        elif a["name"] == "reverse":
            rev = call("rt_truth", gen(mc, fc, a["value"]))
        else:
            return None
    if len(pos) != 1:
        return None
    t = temp(fc, V)
    k = temp(fc, V)
    r = temp(fc, I32)
    return [set(t, pos[0]), set(k, key), set(r, rev), callbi(mc, e["lparen"], "sorted", "rt_sorted", get(t), get(k), get(r), i32(1))]

def gen_print(mc, fc, e, name):
    """print(*args, sep=" ") or fail(*args, sep=" ")"""
    vals = []
    sep = null("eq")
    for a in e["args"]:
        if a["star"] != "":
            return None
        if a["name"] == None:
            vals.append(gen(mc, fc, a["value"]))
        elif a["name"] == "sep":
            sep = gen(mc, fc, a["value"])  # keyword arguments come last
        else:
            return None
    return [callbi(mc, e["lparen"], name, "rt_print_args" if name == "print" else "rt_fail_args", arr_fixed("Vals", *vals), sep),
            NONE if name == "print" else "unreachable"]

def gen_builtin_call(mc, fc, name, e):
    if name == "sorted":
        return gen_sorted(mc, fc, e)
    if name == "print" or name == "fail":
        return gen_print(mc, fc, e, name)
    # Anything but plain positional arguments in range: None (a dynamic
    # call through the builtin's value reports the error at run time).
    if has_star_args(e):
        return None
    for a in e["args"]:
        if a["name"] != None:
            return None
    lo, hi = BUILTINS[name]
    n = len(e["args"])
    if n < lo or n > hi:
        return None
    vals = [gen(mc, fc, a["value"]) for a in e["args"]]
    lp = e["lparen"]
    if name == "enumerate":
        return callbi(mc, lp, name, "rt_enumerate", vals[0], vals[1] if n == 2 else null("eq"))
    if SIMPLE_BUILTINS.get(name) != None:
        return callbi(mc, lp, name, SIMPLE_BUILTINS[name], *vals)
    if name == "bool":
        if n == 0:
            return gget("False")
        return call("rt_bool", call("rt_truth", vals[0]))
    if name == "float":
        if n == 0:
            return call("rt_float", op("f64.convert_i64_s", i64(0)))
        return callbi(mc, lp, name, "rt_float_of", vals[0])
    if name == "list":
        if n == 0:
            return call("rt_list_new", i32(0))
        return callbi(mc, lp, name, "rt_list_of", vals[0])
    if name == "tuple":
        if n == 0:
            return new("Tuple", arr_fixed("Vals"))
        return callbi(mc, lp, name, "rt_tuple_of", vals[0])
    if name == "range":
        if n == 1:
            return callbi(mc, lp, name, "rt_range", vi(0), vals[0], vi(1), i32(1))
        if n == 2:
            return callbi(mc, lp, name, "rt_range", vals[0], vals[1], vi(1), i32(2))
        return callbi(mc, lp, name, "rt_range", vals[0], vals[1], vals[2], i32(3))
    cerr(mc, e["pos"], "internal error: builtin " + name)

def param_slots(params):
    """Parameters in slot order with the bare `*` marker removed, and the
    shape: npos, varargs, nkw, kwargs."""
    slots = []
    npos = 0
    va = 0
    nkw = 0
    kwf = 0
    seen_star = False
    for p in params:
        if p["star"] == "**":
            kwf = 1
            slots.append(p)
        elif p["star"] == "*":
            seen_star = True
            if p["name"] != None:
                va = 1
                slots.append(p)
        elif seen_star:
            nkw += 1
            slots.append(p)
        else:
            npos += 1
            slots.append(p)
    return {"slots": slots, "npos": npos, "varargs": va, "nkw": nkw, "kwargs": kwf}

def gen_user_call(mc, fc, fdef, e, builtin = ""):
    """Direct call of a top-level def, with arguments matched statically.
    builtin: the builtin/method name when fdef is a prelude function (for
    "Error in <builtin>" messages). Returns None when the arguments don't
    match (or are keywords to a positional-only builtin): the caller then
    makes a dynamic call, whose argument binding fails at run time with
    starlark-go's message, as it would only if the call is reached."""
    m = mc["m"]
    if fdef.get("prelude", False) and prelude_kind(fdef) == 1:
        for a in e["args"]:
            if a["name"] != None:
                return None
    fname = fdef.get("display", fdef["name"])
    shape = param_slots(fdef["params"])
    slots = shape["slots"]
    positional = slots[:shape["npos"]]
    named = []  # parameters a keyword argument may name
    varargs = None
    kwargs = None
    for i, p in enumerate(slots):
        if i == 0 and e.get("dot") != None:
            continue  # a method's receiver is positional-only
        if p["star"] == "*":
            varargs = p
        elif p["star"] == "**":
            kwargs = p
        else:
            named.append(p)

    assigned = {}  # param name -> arg
    extra_pos = []
    extra_kw = []
    pi = 0
    seen_kw = False
    for a in e["args"]:
        if a["name"] == None:
            if seen_kw:
                cerr(mc, a["pos"], "positional argument follows keyword argument")
            if pi < len(positional):
                assigned[positional[pi]["name"]] = a
                pi += 1
            elif varargs != None:
                extra_pos.append(a)
            else:
                return None  # too many arguments
        else:
            seen_kw = True
            known = False
            for p in named:
                if p["name"] == a["name"]:
                    known = True
            if not known:
                if kwargs == None:
                    return None
                for b in extra_kw:
                    if b["name"] == a["name"]:
                        return None
                extra_kw.append(a)
            else:
                if assigned.get(a["name"]) != None:
                    return None
                assigned[a["name"]] = a

    # Evaluate arguments in source order. With keyword arguments the
    # parameter order may differ, so go through temporaries.
    argcode = {}
    pre = []
    for a in e["args"]:
        code = gen(mc, fc, a["value"])
        if seen_kw:
            t = temp(fc, V)
            pre.append(set(t, code))
            code = get(t)
        argcode[id_of(a)] = code

    out = []
    for p in slots:
        if p["star"] == "*":
            out.append(new("Tuple", arr_fixed("Vals", *[argcode[id_of(a)] for a in extra_pos])))
        elif p["star"] == "**":
            kv = []
            for a in extra_kw:
                kv.append(S(m, a["name"]))
                kv.append(argcode[id_of(a)])
            out.append(call("rt_dict_from_pairs", arr_fixed("Vals", *kv)))
        else:
            a = assigned.get(p["name"])
            if a != None:
                out.append(argcode[id_of(a)])
            elif p["default"] != None:
                out.append(gget("d_" + fdef["fkey"] + "_" + p["name"]))
            else:
                return None
    if builtin != "" and e.get("dot") != None:
        return [pre, callmeth(mc, e["lparen"], e["dot"], builtin, "f_" + fdef["fkey"], *out)]
    if builtin != "":
        return [pre, callbi(mc, e["lparen"], builtin, "f_" + fdef["fkey"], *out)]
    return [pre, callat(mc, e["lparen"], "f_" + fdef["fkey"], *out)]

def id_of(a):
    return str(a["pos"][0]) + ":" + str(a["pos"][1])

# ---------------------------------------------------------------- functions as values

def const_str(s):
    """A constant expression building string s (for global initializers)."""
    b = utf8(s)
    return [i32(0), [i32(x) for x in b], ("array.new_fixed", "U8", len(b)), ("struct.new", "Str")]

def add_sig(mc, gname, display, shape, kind = 0, recv = 0):
    """Global gname: the $Sig of a function. kind: 0 for Starlark functions,
    1/2 for builtins (see lib/runtime.star); recv: slot 0 is a receiver."""
    names = [const_str(p["name"]) for p in shape["slots"]]
    add_global(mc["m"], gname, ref("Sig"), False, [
        const_str(display),
        names,
        ("array.new_fixed", "Vals", len(names)),
        i32(shape["npos"]),
        i32(shape["varargs"]),
        i32(shape["nkw"]),
        i32(shape["kwargs"]),
        i32(kind),
        i32(recv),
        ("struct.new", "Sig"),
    ])

# Prelude builtins whose parameters may be passed by keyword (starlark-go
# unpacks them with UnpackArgs), besides those with keyword-only or
# **kwargs parameters.
KEYWORD_PRELUDE = {"int": True}

def prelude_kind(fdef):
    """Sig.kind of a prelude function: 1 positional-only, 2 keywords too."""
    shape = param_slots(fdef["params"])
    if shape["nkw"] or shape["kwargs"] or KEYWORD_PRELUDE.get(fdef["name"], False):
        return 2
    return 1

def gen_function(mc, node, wasm_name, has_env, is_lambda):
    """Compile the body of a def or lambda as Wasm function wasm_name."""
    fs = node["scope"]
    fc = new_fc(wasm_name, fs, has_env)
    params = []
    if has_env:
        params.append(("%env", ref("Vals", True)))
    for p in param_slots(node["params"])["slots"]:
        params.append((p["name"], V))
    prologue = []
    for name in fs["bindings"]:
        b = fs["bindings"][name]
        if not b["param"]:
            fc["wlocals"].append((name, V))
        if b["cell"]:
            fc["wlocals"].append((cell_local(name), ref("Cell", True)))
            prologue.append(set(cell_local(name), new("Cell", get(name) if b["param"] else null("eq"))))
    display = "lambda" if is_lambda else node.get("display", node["name"])
    # prelude code is hidden in tracebacks, like builtins in starlark-go
    hidden = mc["mod"].get("prelude", False)
    mc["funcinfo"].append((wasm_name, "hidden" if hidden else "body", display, -1))
    # Argument-binding errors are reported in the callee's frame, at its
    # first instruction (as starlark-go does).
    node["entry_tag"] = at(mc, first_pos(mc, fc, node))[1]
    # Call depth, as starlark-go's limit (MAX_CALL_DEPTH): counted on entry,
    # uncounted on every way out but an error (which ends the program, or
    # is caught by test_catch, which restores the count).
    if not hidden:
        fc["depth"] = True
        prologue.append([
            gset("call_depth", op("i32.add", gget("call_depth"), i32(1))),
            if_(op("i32.gt_s", gget("call_depth"), i32(MAX_CALL_DEPTH)), [
                S(mc["m"], "Starlark stack overflow"),
                at(mc, first_pos(mc, fc, node)),
                call("rt_fail"),
                "unreachable",
            ]),
        ])
    if is_lambda:
        t = temp(fc, V)
        body = [set(t, gen(mc, fc, node["body"])), depth_leave(fc), get(t)]
    else:
        body = [gen_block(mc, fc, node["body"]), depth_leave(fc), NONE]
    add_func(mc["m"], wasm_name, params, [V], [prologue, body], locals = fc["wlocals"])

def depth_leave(fc):
    """Code that uncounts this call in call_depth, if it counts."""
    if not fc["depth"]:
        return []
    return gset("call_depth", op("i32.sub", gget("call_depth"), i32(1)))

def first_pos(mc, fc, node):
    """Position starlark-go gives a function's first instruction: the first
    variable read in evaluation order, or else the def/lambda keyword."""
    if node["kind"] == "lambda":
        p = first_leaf(mc, fc, node["body"])
    else:
        p = first_stmt_leaf(mc, fc, node["body"])
    return node["pos"] if p == None else p

def first_stmt_leaf(mc, fc, stmts):
    if not stmts:
        return None
    s = stmts[0]
    k = s["kind"]
    if k == "expr":
        return first_leaf(mc, fc, s["x"])
    if k == "assign":
        if s["op"] == "=":
            return first_leaf(mc, fc, s["rhs"])
        if s["lhs"]["kind"] == "name":
            return first_leaf(mc, fc, s["lhs"])
        return first_leaf(mc, fc, s["lhs"]["x"])
    if k == "return":
        return None if s["value"] == None else first_leaf(mc, fc, s["value"])
    if k == "if" or k == "while":
        return first_leaf(mc, fc, s["test"])
    if k == "for":
        return first_leaf(mc, fc, s["iter"])
    return None

def first_leaf(mc, fc, e):
    k = e["kind"]
    if k == "name":
        kind = lookup(mc, fc, e["id"], e["pos"])[0]
        if kind == "const" or kind == "builtin":
            return None  # predeclared values carry no position
        return e["pos"]
    if k == "list" or k == "tuple":
        return first_leaf(mc, fc, e["elems"][0]) if e["elems"] else None
    if k == "dict":
        return first_leaf(mc, fc, e["entries"][0][0]) if e["entries"] else None
    if k == "binop" or k == "unop" or k == "index" or k == "slice" or k == "dot":
        return first_leaf(mc, fc, e["x"])
    if k == "cond":
        return first_leaf(mc, fc, e["test"])
    if k == "call":
        return first_leaf(mc, fc, e["fn"])
    if k == "comp":
        return first_leaf(mc, fc, e["clauses"][0]["iter"])
    return None

def last_leaf(mc, fc, e):
    """Position of the last instruction with a source position that
    starlark-go runs to evaluate e, or None."""
    k = e["kind"]
    if k == "name":
        kind = lookup(mc, fc, e["id"], e["pos"])[0]
        return None if kind == "const" or kind == "builtin" else e["pos"]
    if k == "list" or k == "tuple":
        for i in range(len(e["elems"]) - 1, -1, -1):
            q = last_leaf(mc, fc, e["elems"][i])
            if q != None:
                return q
        return None
    if k == "dict":
        return e["colons"][-1] if e["entries"] else None
    if k == "binop":
        if e["op"] == "and" or e["op"] == "or":
            q = last_leaf(mc, fc, e["y"])
            return q if q != None else last_leaf(mc, fc, e["x"])
        return e["pos"]
    if k == "unop":
        return last_leaf(mc, fc, e["x"]) if e["op"] == "not" else e["pos"]
    if k == "call":
        return e["lparen"]
    if k == "index" or k == "dot":
        return e["pos"]
    if k == "slice":
        q = None
        for part in [e["x"], e["lo"], e["hi"], e["step"]]:
            if part != None:
                r = last_leaf(mc, fc, part)
                if r != None:
                    q = r
        return e["pos"] if q == None else q
    return None

def gen_dyn_entry(mc, dyn_name, body_name, has_env, nslots, node = None):
    """Dynamic entry point: bind arguments with rt_bind, call the body."""
    if node != None:
        display = "lambda" if node["kind"] == "lambda" else node.get("display", node["name"])
        kind = "hidden" if mc["mod"].get("prelude", False) else "dyn"
        mc["funcinfo"].append((dyn_name, kind, display, node["entry_tag"]))
    args = []
    if has_env:
        args.append(field("Func", "env", get("f")))
    for i in range(nslots):
        args.append(arr_get("Vals", get("a"), i32(i)))
    add_func(
        mc["m"],
        dyn_name,
        [("f", ref("Func")), ("args", ref("Vals")), ("kw", V)],
        [V],
        [set("a", call("rt_bind", get("f"), get("args"), get("kw"))), call(body_name, *args)],
        locals = [("a", ref("Vals"))],
        typ = "Code",
    )

def make_func(dyn_name, sig_name, env, defaults):
    return new("Func", ("ref.func", dyn_name), gget(sig_name), env, defaults, call("rt_next_id"), i32(0))

def gen_closure(mc, fc, node, display, params):
    """Code creating a closure for a nested def or lambda, evaluated where
    it appears: defaults are computed now, captured cells collected now."""
    uid = str(mc["nfunc"])
    mc["nfunc"] += 1
    base = fc["name"] + "." + display + "#" + uid
    body_name = base
    dyn_name = "dyn_" + base
    sig_name = "sig_" + base
    shape = param_slots(params)
    gen_function(mc, node, body_name, True, node["kind"] == "lambda")
    gen_dyn_entry(mc, dyn_name, body_name, True, len(shape["slots"]), node)
    add_sig(mc, sig_name, display, shape)

    free = node["scope"]["free"]
    if free:
        env = arr_fixed("Vals", *[cell_ref(mc, fc, n, node["pos"]) for n in free])
    else:
        env = null("Vals")
    defaults = null("Vals")
    has_default = False
    for p in shape["slots"]:
        if p["default"] != None:
            has_default = True
    if has_default:
        dvals = []
        for p in shape["slots"]:
            dvals.append(null("eq") if p["default"] == None else gen(mc, fc, p["default"]))
        defaults = arr_fixed("Vals", *dvals)
    return make_func(dyn_name, sig_name, env, defaults)

# ---------------------------------------------------------------- comprehensions and loops

def loop_setup(mc, fc, iter_e, posn):
    """Prepare a for-loop over iter_e. Returns a dict with code pieces:
    setup (run once), done (i32: loop finished), elem (current element),
    advance (step to the next element)."""
    m = mc["m"]
    if iter_e["kind"] == "call" and iter_e["fn"]["kind"] == "name" and \
       iter_e["fn"]["id"] == "range" and not has_star_args(iter_e) and \
       lookup(mc, fc, "range", iter_e["fn"]["pos"])[0] == "builtin":
        args = iter_e["args"]
        check_plain_args(mc, iter_e, "range()")
        if len(args) < 1 or len(args) > 3:
            cerr(mc, iter_e["pos"], "range() takes 1..3 arguments")
        vals = [as_i64(mc, fc, a["value"], iter_e["lparen"], i + 1) for i, a in enumerate(args)]
        if len(vals) == 1:
            vals = [i64(0), vals[0], i64(1)]
        elif len(vals) == 2:
            vals = [vals[0], vals[1], i64(1)]
        i = temp(fc, I64)
        end = temp(fc, I64)
        st = temp(fc, I64)
        setup = [set(i, vals[0]), set(end, vals[1]), set(st, vals[2])]
        if len(args) == 3:
            if args[2]["value"]["kind"] == "int" and args[2]["value"]["val"] == 0:
                cerr(mc, iter_e["pos"], "range: step argument must not be zero")
            setup.append(if_(op("i64.eqz", get(st)), [
                S(m, "range: step argument must not be zero"),
                at(mc, iter_e["lparen"], "range"),
                call("rt_fail"),
                "unreachable",
            ]))
        return {
            "setup": setup,
            "done": eqz(select_(
                op("i64.gt_s", get(st), i64(0)),
                op("i64.lt_s", get(i), get(end)),
                op("i64.gt_s", get(i), get(end)),
                I32,
            )),
            "elem": call("rt_int", get(i)),
            "advance": set(i, op("i64.add", get(i), get(st))),
            "iterable": None,
        }
    # Anything else: a range is counted through lazily (no matter its
    # length); other iterables are snapshotted as a tuple by rt_iter.
    v = temp(fc, V)
    r = temp(fc, ref("Range", True))
    items = temp(fc, ref("Vals", True))
    k = temp(fc, I64)
    cnt = temp(fc, I64)
    return {
        "setup": [
            set(v, gen(mc, fc, iter_e)),
            if_([get(v), ("ref.test", ref("Range"))], [
                set(r, as_("Range", get(v))),
                set(cnt, call("rt_range_len", non_null(get(r)))),  # -1 (too long) counts as unsigned max
            ], if_([get(v), ("ref.test", ref("List"))], [
                # a list is iterated in place: it can't change meanwhile
                set(items, field("List", "items", as_("List", get(v)))),
                set(cnt, op("i64.extend_i32_u", field("List", "len", as_("List", get(v))))),
                call("rt_iter_track", get(v), i32(2)),
            ], [
                set(items, field("Tuple", "items", callat(mc, posn, "rt_iter", get(v)))),
                set(cnt, op("i64.extend_i32_u", arr_len(get(items)))),
                # a list/dict/set being looped over may not change meanwhile
                call("rt_iter_track", get(v), i32(2)),
            ])),
            set(k, i64(0)),
        ],
        "done": op("i64.ge_u", get(k), get(cnt)),
        "elem": if_(op("ref.is_null", get(r)),
                    arr_get("Vals", get(items), op("i32.wrap_i64", get(k))),
                    call("rt_int", op("i64.add", field("Range", "start", non_null(get(r))),
                                      op("i64.mul", get(k), field("Range", "step", non_null(get(r)))))),
                    result = V),
        "advance": set(k, op("i64.add", get(k), i64(1))),
        "iterable": v,  # Wasm local; the loop must end with iter_end(info)
    }

def iter_end(info):
    """Code ending a loop's iteration of its iterable (see loop_setup)."""
    if info["iterable"] == None:
        return []
    return call("rt_iter_track", get(info["iterable"]), i32(-2))

def as_i64(mc, fc, e, posn, param):
    """An argument of range() in a for loop, as an i64 (param: its index,
    for "range: for parameter 2: got string, want int")."""
    if e["kind"] == "int" and e["val"] <= MAX_I64:
        return i64(e["val"])
    if e["kind"] == "unop" and e["op"] == "-" and e["x"]["kind"] == "int" and e["x"]["val"] <= MAX_I64:
        return i64(-e["x"]["val"])
    return callbi(mc, posn, "range", "rt_range_arg", gen(mc, fc, e), i32(param))

def loop_code(info, assign_code, body_code):
    """block $brk { loop $top { if done break; target = elem;
    block $cont { body }; advance; continue } }; end iteration"""
    return [
        info["setup"],
        block("brk", loop("top", [
            br_if("brk", info["done"]),
            assign_code,
            block("cont", body_code),
            info["advance"],
            br("top"),
        ])),
        iter_end(info),
    ]

def gen_comp(mc, fc, e):
    cs = e["scope"]
    res = temp(fc, V)
    init = call("rt_list_new", i32(0)) if e["comp"] == "list" else call("rt_dict_new")
    # Wasm locals for the comprehension's variables; captured ones get a
    # fresh cell each time the comprehension runs.
    cells = []
    for name in cs["bindings"]:
        w = "%c" + str(fc["ntemp"]) + "." + name
        fc["ntemp"] += 1
        if cs["bindings"][name]["cell"]:
            fc["wlocals"].append((w, ref("Cell", True)))
            cs["wasm"][name] = ("cell", w)
            cells.append(set(w, new("Cell", null("eq"))))
        else:
            # unbound until its for clause binds it ("scope_u": reads are
            # checked); reset each time the comprehension runs
            fc["wlocals"].append((w, V))
            cs["wasm"][name] = ("scope_u", w)
            cells.append(set(w, null("eq")))
    code = [set(res, init), cells, gen_clauses(mc, fc, e, 0, res), get(res)]
    fc["scopes"].pop()
    return code

def gen_clauses(mc, fc, e, i, res):
    clauses = e["clauses"]
    if i == len(clauses):
        if e["comp"] == "list":
            return call("rt_list_append", as_("List", get(res)), gen(mc, fc, e["body"]))
        k, v = e["body"]
        return callat(mc, e["colon"], "rt_dict_set", as_("Dict", get(res)), gen(mc, fc, k), gen(mc, fc, v))
    c = clauses[i]
    if c["kind"] == "if":
        return if_(gen_cond(mc, fc, c["test"]), gen_clauses(mc, fc, e, i + 1, res))
    info = loop_setup(mc, fc, c["iter"], c["pos"])
    if i == 0:
        fc["scopes"].append(e["scope"])  # the first iterable sees outer bindings only
    # the target's variables are bound from here on (later clauses, body)
    names = []
    target_names(c["target"], names)
    for n in names:
        w = e["scope"]["wasm"].get(n)
        if w != None and w[0] == "scope_u":
            e["scope"]["wasm"][n] = ("scope", w[1])
    assign_code = gen_assign(mc, fc, c["target"], info["elem"], c["pos"])
    return loop_code(info, assign_code, gen_clauses(mc, fc, e, i + 1, res))

# ---------------------------------------------------------------- statements

def gen_assign(mc, fc, t, value, posn):
    """Code assigning `value` (code for an eqref) to target t. posn: where
    to report a failed tuple unpacking."""
    k = t["kind"]
    if k == "name":
        name = t["id"]
        scopes = fc["scopes"]
        for i in range(len(scopes) - 1, -1, -1):
            w = scopes[i]["wasm"].get(name)
            if w != None:
                if w[0] == "cell":
                    return setfield("Cell", "v", get(w[1]), value)
                return set(w[1], value)
        fs = fc["fscope"]
        if fs != None:
            b = fs["bindings"][name]
            if b["cell"]:
                return setfield("Cell", "v", get(cell_local(name)), value)
            return set(name, value)
        mod = mc["mod"]
        if mod["funcs"].get(name) != None:
            cerr(mc, t["pos"], "cannot reassign function " + name)
        if mod["aliases"].get(name) != None:
            cerr(mc, t["pos"], "cannot reassign " + name + ", which was loaded from another module")
        return gset(mod["globals"][name], value)
    if k == "index":
        v = temp(fc, V)
        return [
            set(v, value),
            callat(mc, t["pos"], "rt_setindex", gen(mc, fc, t["x"]), gen(mc, fc, t["i"]), get(v)),
        ]
    if k == "tuple" or k == "list":
        vals = temp(fc, ref("Vals", True))
        code = [set(vals, callat(mc, posn, "rt_unpack", value, i32(len(t["elems"]))))]
        for i, sub in enumerate(t["elems"]):
            code.append(gen_assign(mc, fc, sub, arr_get("Vals", get(vals), i32(i)), posn))
        return code
    cerr(mc, t["pos"], "cannot assign to this expression")

def gen_block(mc, fc, stmts):
    return [gen_stmt(mc, fc, s) for s in stmts]

def gen_stmt(mc, fc, s):
    k = s["kind"]
    if k == "expr":
        return drop(gen(mc, fc, s["x"]))
    if k == "assign":
        if s["op"] == "=":
            return gen_assign(mc, fc, s["lhs"], gen(mc, fc, s["rhs"]), s["oppos"])
        return gen_augassign(mc, fc, s)
    if k == "if":
        els = None
        if s["else_"]:
            els = gen_block(mc, fc, s["else_"])
        return if_(gen_cond(mc, fc, s["test"]), gen_block(mc, fc, s["body"]), els)
    if k == "while":
        fc["loops"] += 1
        body = gen_block(mc, fc, s["body"])
        fc["loops"] -= 1
        return block("brk", loop("cont", [
            br_if("brk", eqz(gen_cond(mc, fc, s["test"]))),
            body,
            br("cont"),
        ]))
    if k == "for":
        info = loop_setup(mc, fc, s["iter"], s["pos"])
        assign_code = gen_assign(mc, fc, s["target"], info["elem"], s["pos"])
        fc["loops"] += 1
        fc["iters"].append(info)
        body = gen_block(mc, fc, s["body"])
        fc["iters"].pop()
        fc["loops"] -= 1
        return loop_code(info, assign_code, body)
    if k == "return":
        if fc["is_module"]:
            cerr(mc, s["pos"], "return statement not within a function")
        # leaving enclosing for loops ends their iterations (after the
        # value is computed, which may not change those iterables either)
        ends = [iter_end(info) for info in reversed(fc["iters"])]
        leave = depth_leave(fc)
        if s["value"] == None:
            return [ends, leave, ret(NONE)]
        if not fc["iters"] and not leave:
            return ret(gen(mc, fc, s["value"]))
        t = temp(fc, V)
        return [set(t, gen(mc, fc, s["value"])), ends, leave, ret(get(t))]
    if k == "break" or k == "continue":
        if fc["loops"] == 0:
            cerr(mc, s["pos"], k + " not in a loop")
        return br("brk" if k == "break" else "cont")
    if k == "pass":
        return []
    if k == "def":
        if fc["is_module"]:
            return gen_toplevel_def_stmt(mc, fc, s)
        target = {"kind": "name", "id": s["name"], "pos": s["pos"]}
        return gen_assign(mc, fc, target, gen_closure(mc, fc, s, s["name"], s["params"]), s["pos"])
    if k == "load":
        if not fc["is_module"]:
            cerr(mc, s["pos"], "load() must be at the top level")
        # run the module once; names were bound statically, except those
        # that are module variables here (see declare_module)
        code = [callat(mc, s["pos"], "init" + str(s["mod"]))]
        child = mc["mods"][s["mod"]]
        for local, remote in s.get("rebind", []):
            kind, x = lookup_module(mc, child, remote)
            value = gget("fv_" + x) if kind == "func" else gget(x)
            code.append(gset(mc["mod"]["globals"][local], value))
        return code
    cerr(mc, s["pos"], "internal error: unknown statement kind " + k)

def gen_toplevel_def_stmt(mc, fc, s):
    """Executing a top-level def: evaluate its defaults, create its value."""
    name = s["fkey"]
    code = []
    dvals = []
    has_default = False
    for p in param_slots(s["params"])["slots"]:
        if p["default"] != None:
            has_default = True
            g = "d_" + name + "_" + p["name"]
            code.append(gset(g, gen(mc, fc, p["default"])))
            dvals.append(gget(g))
        else:
            dvals.append(null("eq"))
    defaults = arr_fixed("Vals", *dvals) if has_default else null("Vals")
    code.append(gset("fv_" + name, make_func("dyn_" + name, "sig_" + name, null("Vals"), defaults)))
    return code

def gen_augassign(mc, fc, s):
    op_ = s["op"][:-1]
    fn = {"+": "rt_iadd", "|": "rt_ior"}.get(op_, ARITH.get(op_))
    t = s["lhs"]
    if t["kind"] == "name":
        return gen_assign(mc, fc, t, callat(mc, s["oppos"], fn, gen_name(mc, fc, t), gen(mc, fc, s["rhs"])), s["oppos"])
    if t["kind"] == "index":
        tx = temp(fc, V)
        ti = temp(fc, V)
        return [
            set(tx, gen(mc, fc, t["x"])),
            set(ti, gen(mc, fc, t["i"])),
            callat(mc, t["pos"], "rt_setindex", get(tx), get(ti),
                   callat(mc, s["oppos"], fn, callat(mc, t["pos"], "rt_index", get(tx), get(ti)), gen(mc, fc, s["rhs"]))),
        ]
    cerr(mc, t["pos"], "cannot use " + s["op"] + " on this target")

# ---------------------------------------------------------------- module

def path_parts(p):
    parts = []
    cur = ""
    for c in p.elems():
        if c == "/":
            parts.append(cur)
            cur = ""
        else:
            cur += c
    parts.append(cur)
    return parts

def path_join(from_file, rel):
    """Path of module `rel`, loaded from file `from_file`, normalized."""
    absolute = rel.startswith("/") or (from_file.startswith("/") and not rel.startswith("/"))
    if rel.startswith("/"):
        parts = path_parts(rel)
    else:
        parts = path_parts(from_file)[:-1] + path_parts(rel)
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

def qualify(mod, name):
    """Wasm-level name of a module-level symbol: plain for the main module,
    "m<id>.name" for loaded ones."""
    if mod["id"] == 0:
        return name
    return "m" + str(mod["id"]) + "." + name

def discover(mc, path, src):
    """Parse a module and, recursively, everything it loads. Modules get
    ids in discovery order (main = 0); mc["order"] lists them with
    dependencies first."""
    stmts = parse_file(src, path)
    mod = {"id": len(mc["mods"]), "path": path, "stmts": stmts, "funcs": {}, "globals": {}, "aliases": {}, "loading": True}
    mc["mods"].append(mod)
    mc["modpath"][path] = mod
    for s in stmts:
        if s["kind"] == "load":
            child_path = path_join(path, s["module"])
            child = mc["modpath"].get(child_path)
            if child == None:
                child = discover(mc, child_path, read_file(child_path))
            elif child["loading"]:
                mc["file"] = path
                cerr(mc, s["pos"], "cycle in load graph: " + child_path)
            s["mod"] = child["id"]
    mod["loading"] = False
    mc["order"].append(mod)
    return mod

def check_loads(mc, stmts, within):
    """starlark-go's resolver checks of load statements, in source order:
    only at the top level (within: "" or "function", "loop", "conditional"),
    no empty names, no names with leading underscores."""
    for s in stmts:
        k = s["kind"]
        if k == "load":
            if within != "":
                cerr(mc, s["pos"], "load statement within a " + within)
            for i, (_, remote) in enumerate(s["names"]):
                if remote == "":
                    cerr(mc, s["namepos"][i], "load: empty identifier")
                if remote.startswith("_"):
                    cerr(mc, s["namepos"][i], "load: names with leading underscores are not exported: " + remote)
        elif k == "def":
            check_loads(mc, s["body"], "function")
        elif k == "for" or k == "while":
            check_loads(mc, s["body"], within or "loop")
        elif k == "if":
            check_loads(mc, s["body"], within or "conditional")
            check_loads(mc, s["else_"], within or "conditional")

def declare_module(mc, mod):
    """Module-level symbols of mod: its defs, globals and loaded names."""
    m = mc["m"]
    mc["mod"] = mod
    mc["file"] = mod["path"]
    stmts = mod["stmts"]
    check_loads(mc, stmts, "")
    resolve_module(stmts, mod["path"])
    bound = {}
    collect_bindings(stmts, bound)
    # A loaded name is normally an alias for the other module's symbol. One
    # that is also assigned, or loaded twice, is a module variable instead,
    # set by each load (bin/starhost allows reassigning it, globalreassign).
    nloads = {}
    for s in stmts:
        if s["kind"] == "load":
            for local, _ in s["names"]:
                nloads[local] = nloads.get(local, 0) + 1
    for s in stmts:
        if s["kind"] == "def":
            if mod["funcs"].get(s["name"]) != None:
                cerr(mc, s["pos"], "function " + s["name"] + " defined twice")
            key = qualify(mod, s["name"])
            s["fkey"] = key
            if mod.get("prelude", False):
                s["prelude"] = True
                if s["name"].startswith("_m_"):
                    s["display"] = s["name"][3:]  # method name, for messages
            mod["funcs"][s["name"]] = key
            mc["allfuncs"][key] = s
        elif s["kind"] == "load":
            child = mc["mods"][s["mod"]]
            for local, remote in s["names"]:
                if lookup_module(mc, child, remote) == None:
                    cerr(mc, s["pos"], "load: name " + remote + " not found in module " + s["module"] +
                         spell_hint(remote, list(child["funcs"].keys()) + list(child["globals"].keys())))
                if mod["funcs"].get(local) != None:
                    cerr(mc, s["pos"], "load: " + local + " is already defined")
                if nloads[local] > 1 or bound.get(local) != None:
                    s.setdefault("rebind", []).append((local, remote))
                    if mod["globals"].get(local) == None:
                        g = "g_" + qualify(mod, local)
                        mod["globals"][local] = g
                        add_global(m, g, V, True, [null("eq")])
                else:
                    mod["aliases"][local] = (child["id"], remote)
    for name in bound:
        if mod["funcs"].get(name) == None:
            if mod["globals"].get(name) != None:
                continue  # a loaded name that is reassigned (see above)
            g = "g_" + qualify(mod, name)
            mod["globals"][name] = g
            add_global(m, g, V, True, [null("eq")])

def compile_module_funcs(mc, mod):
    m = mc["m"]
    mc["mod"] = mod
    mc["file"] = mod["path"]
    for s in mod["stmts"]:
        if s["kind"] == "def":
            key = s["fkey"]
            shape = param_slots(s["params"])
            for p in shape["slots"]:
                if p["default"] != None:
                    add_global(m, "d_" + key + "_" + p["name"], V, True, [null("eq")])
            add_global(m, "fv_" + key, V, True, [null("eq")])
            if mod.get("prelude", False):
                add_sig(mc, "sig_" + key, s.get("display", s["name"]), shape, prelude_kind(s), 1 if s["name"].startswith("_m_") else 0)
            else:
                add_sig(mc, "sig_" + key, s["name"], shape)
            gen_function(mc, s, "f_" + key, False, False)
            gen_dyn_entry(mc, "dyn_" + key, "f_" + key, False, len(shape["slots"]), s)

def compile_module_init(mc, mod):
    """The module's top-level code, as function init<id>; runs at most once
    (at the first load() of it, or from main for the main module)."""
    m = mc["m"]
    mc["mod"] = mod
    mc["file"] = mod["path"]
    flag = "inited" + str(mod["id"])
    add_global(m, flag, I32, True, [i32(0)])
    fc = new_fc("init" + str(mod["id"]), None, False)
    mc["funcinfo"].append(("init" + str(mod["id"]), "hidden" if mod.get("prelude", False) else "body", "<toplevel>", -1))
    body = [
        if_(gget(flag), ret()),
        gset(flag, i32(1)),
        gen_block(mc, fc, mod["stmts"]),
    ]
    if mod["id"] != 0:
        # A loaded module's values are frozen once it has run.
        for name in mod["globals"]:
            body.append(call("rt_freeze", gget(mod["globals"][name])))
        for name in mod["funcs"]:
            body.append(call("rt_freeze", gget("fv_" + mod["funcs"][name])))
    add_func(m, "init" + str(mod["id"]), [], [], body, locals = fc["wlocals"])

def new_refs():
    return {"names": {}, "methods": {}, "attrs": {}, "getattr_uses": 0, "getattr_literal": 0}

def collect_refs(x, refs):
    """Record what AST x uses: identifiers (names), names called as methods
    (methods), names taken as attributes, x.name or getattr(x, "name")
    (attrs), and how many uses of getattr are not such literal calls."""
    t = type(x)
    if t == "list" or t == "tuple":
        for e in x:
            collect_refs(e, refs)
    elif t == "dict":
        k = x.get("kind")
        if k == "name":
            refs["names"][x["id"]] = True
            if x["id"] == "getattr":
                refs["getattr_uses"] += 1
        elif k == "call":
            fn = x["fn"]
            args = x["args"]
            if fn["kind"] == "dot":
                refs["methods"][fn["name"]] = True
                collect_refs(fn["x"], refs)
                collect_refs(args, refs)
                return
            if fn["kind"] == "name" and fn["id"] == "getattr" and len(args) >= 2 and \
               args[1]["value"]["kind"] == "string" and args[1]["name"] == None and args[1]["star"] == "":
                refs["attrs"][args[1]["value"]["val"]] = True
                refs["getattr_literal"] += 1
        elif k == "dot":
            refs["attrs"][x["name"]] = True
        for key in x:
            if key != "scope":
                collect_refs(x[key], refs)

def add_prelude(mc):
    """Add lib/prelude.star (builtins and methods written in Starlark) as a
    module, keeping only the functions the program can reach, so every
    program doesn't carry the whole prelude. Also decides which methods the
    program may take as values (mc["method_values"]) and whether it may
    have structs (mc["has_struct"])."""
    stmts = parse_file(PRELUDE, "lib/prelude.star")
    defs = {}  # name -> the def or top-level assignment that binds it
    rest = []  # other top-level statements (always kept)
    for s in stmts:
        if s["kind"] == "def":
            defs[s["name"]] = s
        elif s["kind"] == "assign" and s["op"] == "=" and s["lhs"]["kind"] == "name":
            defs[s["lhs"]["id"]] = s
        else:
            rest.append(s)
    used = {}  # names of the defs/assignments kept
    work = []

    def want(n):
        if defs.get(n) != None and not used.get(n, False):
            used[n] = True
            work.append(n)

    def want_refs(node, user):
        refs = new_refs()
        collect_refs(node, refs)
        for n in refs["names"]:
            if not (user and n.startswith("_")):
                want(n)
        for meth in refs["methods"]:
            want("_m_" + meth)
        return refs

    # every method name: generated ones and _m_<name> in the prelude
    universe = {}
    for name in METHODS:
        universe[name] = True
    for name in defs:
        if name.startswith("_m_"):
            universe[name[3:]] = True

    user = new_refs()
    for mod in mc["mods"]:
        r = want_refs(mod["stmts"], True)
        for key in ["names", "methods", "attrs"]:
            for n in r[key]:
                user[key][n] = True
        user["getattr_uses"] += r["getattr_uses"]
        user["getattr_literal"] += r["getattr_literal"]
    attrs = user["attrs"]
    if user["getattr_uses"] > user["getattr_literal"]:
        attrs = universe  # getattr(x, name) with any name
    values = {}
    for name in attrs:
        if universe.get(name, False):
            values[name] = True
            want("_m_" + name)
    mc["method_values"] = sorted(values.keys())
    mc["has_struct"] = user["names"].get("struct", False)
    if attrs or mc["has_struct"]:
        want("_attr")
    for meth in user["methods"]:
        if not universe.get(meth, False):
            want("_attr")  # x.unknown(...): a struct field, or an error at run time
    want_refs(rest, False)
    while work:
        want_refs(defs[work.pop()], False)

    kept = []
    for s in stmts:
        if s["kind"] == "def":
            if used.get(s["name"], False):
                kept.append(s)
        elif s["kind"] == "assign" and s["op"] == "=" and s["lhs"]["kind"] == "name":
            if used.get(s["lhs"]["id"], False):
                kept.append(s)
        else:
            kept.append(s)
    mod = {"id": len(mc["mods"]), "path": "lib/prelude.star", "stmts": kept, "funcs": {}, "globals": {},
           "aliases": {}, "loading": False, "prelude": True}
    mc["mods"].append(mod)
    mc["prelude"] = mod
    mc["order"] = [mod] + mc["order"]

def compile_program(src, filename, test = False):
    m = new_module()
    add_runtime(m, test)
    add_builtins(m)
    if test:
        add_test_builtins(m)
    mc = {
        "m": m,
        "test": test,  # test-only builtins visible (TEST_BUILTINS)
        "file": filename,
        "mods": [],  # by id
        "modpath": {},  # normalized path -> module
        "order": [],  # dependencies first
        "mod": None,  # module being compiled
        "allfuncs": {},  # function key -> def node
        "nfunc": 0,
        "builtin_values": {},
        # debug info (see at() and debug_section())
        "files": [],
        "fileidx": {},
        "builtins": [],
        "builtinidx": {},
        "poslist": [],  # tag -> (file index, line, col, builtin index or -1)
        "tags": {},
        "funcinfo": [],  # (Wasm function name, "body" | "dyn" | "hidden", display name, entry tag)
        "prelude": None,  # the prelude module
        "method_values": [],  # methods that may be taken as values (see add_prelude)
        "has_struct": False,  # the program may create structs
        "floats": {},  # float literal text -> getter function
    }
    discover(mc, filename, src)
    add_prelude(mc)
    for mod in mc["order"]:
        declare_module(mc, mod)
    # the class and case tables, if a method that needs them is kept
    pfuncs = mc["prelude"]["funcs"]
    if pfuncs.get("_casefn") != None or pfuncs.get("_classfn") != None:
        add_unicode_tables(m)
    for mod in mc["order"]:
        compile_module_funcs(mc, mod)
    for mod in mc["order"]:
        compile_module_init(mc, mod)
    add_global(m, "argv", V, True, [null("eq")])
    add_global(m, "call_depth", I32, True, [i32(1)])  # the top level counts, as in starlark-go
    main_body = [gset("argv", call("rt_argv")), call("init" + str(mc["prelude"]["id"]))]
    if mc["prelude"]["funcs"].get("_attr") != None:
        # the method table for bound methods (after the prelude's defs ran)
        main_body.append(gset("method_funcs", call("rt_dict_new")))
        for name in mc["method_values"]:
            main_body.append(call("rt_dict_set", non_null(gget("method_funcs")), S(m, name), method_func(mc, name)))
    main_body.append(call("init0"))
    add_func(m, "main", [], [], main_body, export = True)
    add_custom(m, "starwasm.debug", debug_section(mc))
    add_custom(m, "starwasm.pos", pos_section(mc))
    return m

def pos_section(mc):
    """Per marker tag: file index, line, column, builtin index + 1 (0: none),
    dot line, dot column (0 0: none), as LEB128 numbers after a count."""
    out = uleb(len(mc["poslist"]))
    for fi, line, col, bi, dl, dc in mc["poslist"]:
        out += uleb(fi) + uleb(line) + uleb(col) + uleb(bi + 1) + uleb(dl) + uleb(dc)
    return out

def debug_section(mc):
    """JSON for the host's traceback printer (positions are in starwasm.pos):
      files     source file names
      builtins  builtin names (for "Error in <builtin>: ...")
      funcs     [Wasm function index, kind, display name, entry tag]:
                "body" frames map their stack offset through starwasm.marks;
                "dyn" entries are argument-binding frames shown at entry tag"""
    m = mc["m"]
    funcs = []
    for wname, kind, display, entry in mc["funcinfo"]:
        funcs.append("[" + str(m["func_index"][wname]) + "," + repr(kind) + "," + repr(display) + "," + str(entry) + "]")
    text = "".join([
        "{\"files\":[", ",".join([repr(f) for f in mc["files"]]),
        "],\"builtins\":[", ",".join([repr(b) for b in mc["builtins"]]),
        "],\"funcs\":[", ",".join(funcs), "]}",
    ])
    return list(text.elem_ords())

def compile(src, filename, test = False):
    """Compile a Starlark program (and the modules it loads, read relative
    to filename) to Wasm bytes (a list of ints). test: make the test-only
    builtins (TEST_BUILTINS) visible."""
    return encode(compile_program(src, filename, test))
