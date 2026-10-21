# dsl.star — expression-style builders over lib/wasm.star instructions.
#
# Each helper returns a code fragment (nested lists of instructions) that
# leaves its result on the Wasm stack, so code reads as a tree:
#
#     call("rt_add", get("a"), vi(1))
#     if_(is_("Str", get("x")), ret(get("x")))
#
# Remember the two stages: Starlark control flow here decides WHAT CODE
# to emit; the emitted if_/while_ decide at Wasm run time.

load("wasm.star", "ref")

# ---- locals, globals, constants

def get(x):
    return ("local.get", x)

def set(x, v):
    return [v, ("local.set", x)]

def tee(x, v):
    return [v, ("local.tee", x)]

def gget(g):
    return ("global.get", g)

def gset(g, v):
    return [v, ("global.set", g)]

def i32(n):
    return ("i32.const", n)

def i64(n):
    return ("i64.const", n)

# ---- generic

def op(name, *args):
    """Evaluate args left to right, then apply instruction `name`."""
    return [list(args), (name,)]

def call(f, *args):
    return [list(args), ("call", f)]

def ret(*vals):
    return [list(vals), "return"]

def drop(v):
    return [v, "drop"]

def eqz(v):
    return op("i32.eqz", v)

def inc(x, n = 1):
    """x += n for an i32 local."""
    return set(x, op("i32.add", get(x), i32(n)))

# ---- control flow

def if_(cond, then, else_ = None, result = None, label = None):
    head = ("if", result) if label == None else ("if", result, label)
    out = [cond, head, then]
    if else_ != None:
        out += ["else", else_]
    return out + ["end"]

def select_(cond, a, b, result):
    """cond ? a : b as an expression of type `result`."""
    return if_(cond, a, b, result = result)

def and_(a, b):
    """Short-circuit i32 `a && b`."""
    return if_(a, b, i32(0), result = 0x7f)

def or_(a, b):
    """Short-circuit i32 `a || b`."""
    return if_(a, i32(1), b, result = 0x7f)

def block(label, body, result = None):
    return [("block", result, label), body, "end"]

def loop(label, body, result = None):
    return [("loop", result, label), body, "end"]

def br(label):
    return ("br", label)

def br_if(label, cond):
    return [cond, ("br_if", label)]

def while_(cond, body, label = "loop"):
    """while cond: body. Inside body, br(label + "_break") breaks and
    br(label) continues."""
    brk = label + "_break"
    return block(brk, loop(label, [
        br_if(brk, eqz(cond)),
        body,
        br(label),
    ]))

def for_i32(var, start, end, body, label = "for"):
    """for var in range(start, end): body   (i32 local var; `end` is
    re-evaluated each iteration, so pass a local or constant)."""
    return [
        set(var, start),
        while_(op("i32.lt_s", get(var), end), [body, inc(var)], label = label),
    ]

def unreachable():
    return "unreachable"

# ---- GC structs and arrays

def new(T, *fields):
    return [list(fields), ("struct.new", T)]

def field(T, f, obj):
    return [obj, ("struct.get", T, f)]

def setfield(T, f, obj, v):
    return [obj, v, ("struct.set", T, f)]

def arr_new(T, init, n):
    return [init, n, ("array.new", T)]

def arr_new_default(T, n):
    return [n, ("array.new_default", T)]

def arr_fixed(T, *elems):
    return [list(elems), ("array.new_fixed", T, len(elems))]

def arr_get(T, a, i):
    return [a, i, ("array.get", T)]

def arr_get_u(T, a, i):
    return [a, i, ("array.get_u", T)]

def arr_set(T, a, i, v):
    return [a, i, v, ("array.set", T)]

def arr_len(a):
    return [a, "array.len"]

def arr_copy(T, dst, di, src, si, n):
    return [dst, di, src, si, n, ("array.copy", T, T)]

# ---- references

def null(ht):
    return ("ref.null", ht)

def is_null(v):
    return op("ref.is_null", v)

def non_null(v):
    return op("ref.as_non_null", v)

def ref_eq(a, b):
    return op("ref.eq", a, b)

def is_(T, v):
    """i32: does v hold a (non-null) T?  T: type name or abstract heap type."""
    return [v, ("ref.test", ref(T))]

def as_(T, v):
    """Cast v to (ref T); traps if it isn't one."""
    return [v, ("ref.cast", ref(T))]
