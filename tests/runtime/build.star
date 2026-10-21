# Builds tests/runtime/expect.star by hand as Wasm calls into the runtime.
# This is roughly what the milestone-3 compiler will emit.
#
#   bin/starhost tests/runtime/build.star out/runtime_test.wasm
#
# Exports: main (the differential program) and err_* (each should fail).

load("../../lib/wasm.star", "EQREF", "I32", "add_func", "encode", "new_module", "ref")
load("../../lib/runtime.star", "S", "add_runtime", "vi")
load("../../lib/builtins.star", "add_builtins")
load("../../lib/dsl.star", "arr_fixed", "as_", "call", "for_i32", "get", "gget", "i32", "new", "op", "set")

m = new_module()
add_runtime(m)
add_builtins(m)  # the runtime calls a few of them (e.g. struct + struct)

V = EQREF

# ---- tiny "codegen" vocabulary
def pr(v):
    return call("rt_print", v)

def s(x):
    return S(m, x)

def add(a, b):
    return call("rt_add", a, b)

def sub(a, b):
    return call("rt_sub", a, b)

def mul(a, b):
    return call("rt_mul", a, b)

def lst(*e):
    return new("List", i32(len(e)), arr_fixed("Vals", *e), i32(0))

def tup(*e):
    return new("Tuple", arr_fixed("Vals", *e))

def dict_():
    return call("rt_dict_new")

def boolean(code):
    return call("rt_bool", code)

def eq(a, b):
    return boolean(call("rt_eq", a, b))

def lt(a, b):
    return boolean(call("rt_lt", a, b))

def in_(a, b):
    return boolean(call("rt_in", a, b))

def idx(x, i):
    return call("rt_index", x, i)

def setidx(x, i, v):
    return call("rt_setindex", x, i, v)

def length(x):
    return call("rt_len", x)

def type_(x):
    return call("rt_type", x)

def not_(x):
    return call("rt_not", x)

def int_of(local):
    """Starlark int from an i32 loop counter."""
    return call("rt_int", op("i64.extend_i32_s", get(local)))

NONE = gget("None")
TRUE = gget("True")

main = [
    # ints
    pr(vi(42)),
    pr(vi(-7)),
    pr(add(vi(1073741823), vi(1))),
    pr(sub(vi(-1073741824), vi(1))),
    pr(sub(vi(1073741824), vi(1))),
    pr(eq(sub(vi(1073741824), vi(1)), vi(1073741823))),
    pr(mul(vi(123456789), vi(1000))),
    pr(call("rt_floordiv", vi(-7), vi(2))),
    pr(call("rt_mod", vi(-7), vi(2))),
    pr(call("rt_mod", vi(7), vi(-2))),
    pr(call("rt_floordiv", vi(7), vi(-2))),
    pr(call("rt_shl", vi(1), vi(40))),
    pr(call("rt_shr", vi(-1), vi(3))),
    pr(call("rt_or", call("rt_and", vi(0xff), vi(0x0f)), call("rt_xor", vi(0x100), vi(1)))),
    pr(vi(9223372036854775807)),
    pr(sub(vi(-9223372036854775807), vi(1))),
    pr(call("rt_str", vi(-1234567890123))),
    pr(call("rt_neg", vi(5))),

    # strings
    pr(add(add(s("hello"), s(" ")), s("world"))),
    pr(call("rt_repr", s("tab\there \"q\" \\ \x01 é"))),
    pr(mul(s("ab"), vi(3))),
    pr(idx(s("hello"), vi(1))),
    pr(in_(s("lo"), s("hello"))),
    pr(in_(s("x"), s("hello"))),
    pr(length(s("héllo"))),
    pr(call("rt_str", tup(vi(1), s("a")))),
    pr(call("rt_repr", s("x"))),
    pr(call("rt_str", s("x"))),

    # containers
    pr(lst(vi(1), s("a"), NONE, TRUE, tup(vi(2)), tup(vi(3), vi(4)), lst(), dict_())),
    pr(add(lst(vi(1)), lst(vi(2), vi(3)))),
    pr(add(tup(vi(1)), tup(vi(2)))),
    pr(mul(lst(vi(0)), vi(3))),
    pr(mul(vi(2), tup(vi(1), s("x")))),
    pr(in_(vi(2), lst(vi(1), vi(2), vi(3)))),
    pr(idx(lst(vi(10), vi(20), vi(30)), vi(-1))),
    pr(idx(tup(vi(10), vi(20), vi(30)), vi(0))),

    # dicts
    set("d", dict_()),
    setidx(get("d"), s("b"), vi(1)),
    setidx(get("d"), s("a"), vi(2)),
    setidx(get("d"), vi(3), s("three")),
    setidx(get("d"), tup(vi(1), vi(2)), NONE),
    setidx(get("d"), s("b"), vi(10)),
    setidx(get("d"), call("rt_shl", vi(1), vi(40)), s("big")),
    pr(get("d")),
    pr(length(get("d"))),
    pr(idx(get("d"), s("a"))),
    pr(in_(s("a"), get("d"))),
    pr(in_(s("z"), get("d"))),
    pr(idx(get("d"), call("rt_floordiv", call("rt_shl", vi(1), vi(41)), vi(2)))),

    # growth
    set("d2", dict_()),
    for_i32("i", i32(0), i32(100), [
        setidx(get("d2"), mul(int_of("i"), vi(7)), call("rt_str", int_of("i"))),
    ]),
    pr(length(get("d2"))),
    pr(idx(get("d2"), vi(693))),
    pr(idx(get("d2"), vi(0))),
    set("l", call("rt_list_new", i32(0))),
    for_i32("i", i32(0), i32(50), [
        call("rt_list_append", as_("List", get("l")), mul(int_of("i"), int_of("i"))),
    ]),
    pr(idx(get("l"), vi(49))),
    pr(idx(get("l"), vi(-1))),
    pr(length(get("l"))),
    set("s", vi(0)),
    set("t", call("rt_iter", get("d2"))),
    for_i32("i", i32(0), op("array.len", [get("t"), ("struct.get", "Tuple", "items")]), [
        set("s", add(get("s"), [get("t"), ("struct.get", "Tuple", "items"), get("i"), ("array.get", "Vals")])),
    ]),
    pr(get("s")),

    # equality and ordering
    pr(eq(lst(vi(1), tup(vi(2), s("x"))), lst(vi(1), tup(vi(2), s("x"))))),
    pr(eq(lst(vi(1), tup(vi(2), s("x"))), lst(vi(1), tup(vi(2), s("y"))))),
    pr(lt(tup(vi(1), vi(2)), tup(vi(1), vi(3)))),
    pr(lt(lst(vi(1), vi(2)), lst(vi(1), vi(2), vi(0)))),
    pr(lt(s("abc"), s("abd"))),
    pr(lt(s("b"), s("abc"))),
    set("d", dict_()),
    setidx(get("d"), s("a"), vi(1)),
    setidx(get("d"), s("b"), vi(2)),
    set("d2", dict_()),
    setidx(get("d2"), s("b"), vi(2)),
    setidx(get("d2"), s("a"), vi(1)),
    pr(eq(get("d"), get("d2"))),

    # type() and truthiness
    pr(type_(vi(1))),
    pr(type_(vi(1 << 40))),
    pr(type_(s("s"))),
    pr(type_(lst())),
    pr(type_(tup())),
    pr(type_(dict_())),
    pr(type_(NONE)),
    pr(type_(TRUE)),
    pr(not_(lst())),
    pr(not_(lst(vi(0)))),
    pr(not_(s(""))),
    pr(not_(vi(0))),
    pr(not_(NONE)),
]

add_func(m, "main", [], [], main, locals = [
    ("d", V),
    ("d2", V),
    ("l", V),
    ("s", V),
    ("t", ref("Tuple", True)),
    ("i", I32),
], export = True)

# Each of these must print one error line and exit with status 1.
errors = {
    "err_shift": call("rt_shl", vi(1), vi(512)),
    "err_type": add(vi(1), s("a")),
    "err_key": idx(dict_(), s("z")),
    "err_index": idx(lst(vi(1)), vi(5)),
    "err_unhashable": [setidx(dict_(), lst(vi(1)), vi(1)), NONE],
    "err_divzero": call("rt_floordiv", vi(1), vi(0)),
    "err_compare": lt(vi(1), s("a")),
    "err_len": length(vi(3)),
}
for fname, code in errors.items():
    add_func(m, fname, [], [], [pr(code)], export = True)

write_file(argv[0], encode(m))
