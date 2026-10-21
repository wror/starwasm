# runtime.star — the Starlark runtime, generated as WasmGC code.
#
# add_runtime(m) declares the value types, globals and host imports, and
# defines every rt_* function in module m. Nothing here is hand-written
# WAT: each function is ordinary Starlark data built with lib/dsl.star.
#
# ---------------------------------------------------------------------------
# Value representation. Every Starlark value is an `eqref` (V below):
#
#   int        i31ref when -2^30 <= n < 2^30, else (ref $Int) boxing an i64,
#              else (ref $Big) = {neg, mag: $I32A limbs} (unbounded; see
#              "big ints"). Always normalized, so equal ints have equal
#              representations.
#   None       the single (ref $NoneType) in global $None
#   bool       (ref $Bool); exactly two instances, globals $True / $False
#   float      (ref $Float) = {v: f64}; operations follow starlark-go
#              (ints and floats compare exactly; NaN == NaN, NaN > +inf).
#              Formatting, parsing and fmod come from the host (shortest
#              round-trip digits are JavaScript's).
#   string     (ref $Str) = {hash: mut i32 (0 = not yet computed), b: $U8}
#              bytes are UTF-8; len/index are by byte, as in starlark-go
#   tuple      (ref $Tuple) = {items: $Vals}
#   list       (ref $List)  = {len: mut i32, items: mut $Vals} (capacity grows x2)
#   dict       (ref $Dict), insertion-ordered, open addressing:
#                index:  $I32A, power-of-two size S, slot -> entry or -1
#                keys/vals/hashes: entry arrays of capacity S/2
#                deleted entries would have a null key (tombstone)
#   set        (ref $Set) = {d: $Dict}: the elements are the dict's keys (values
#              None), so sets share the dict's insertion order, hashing and
#              frozen flag.
#   The "frozen" field of lists and dicts holds two things: bit 0 is the
#   frozen flag; the rest counts the for loops (and other iterations that
#   run Starlark code) currently going over the value, which may not change
#   it meanwhile ("cannot append to list during iteration").
#   bytes      (ref $Bytes) = {hash, b: $U8}, the same layout as $Str (a
#              distinct type); many operations wrap the array in a $Str and
#              reuse the string code.
#   struct     (ref $Struct) = {d: $Dict}: field name -> value, keys sorted
#   function   (ref $Func) (see below); builtins used as values are $Funcs
#              too, with Sig.kind != 0
#   bound method  (ref $Bound) = {recv, fn: $Func, name}: x.method as a
#              value; calling it calls fn with recv prepended
#   range      (ref $Range) = {start, stop, step: i64}: lazy, like starlark-go
#   lazy string sequences: (ref $Lazy) = {kind, s: $Str}, what s.elems(),
#              s.elem_ords(), s.codepoints(), s.codepoint_ords() and
#              b.elems() return (kinds LAZY_*; for bytes, s shares b's array)
#   null       "no value": unbound variable / missing dict entry. Never a
#              Starlark value.
#
# Errors print "Error: <msg>" to stderr and call host.exit(1).
# ---------------------------------------------------------------------------

load(
    "wasm.star",
    "EQREF",
    "F64",
    "I32",
    "I64",
    "I8",
    "add_data",
    "add_func",
    "add_global",
    "add_memory",
    "add_type",
    "array_type",
    "import_func",
    "ref",
    "struct_type",
    "utf8",
)
load("unicode_tables.star", "CASE_RANGES", "CLASS_RANGES", "PRINT_RANGES")
load(
    "dsl.star",
    "and_",
    "arr_copy",
    "arr_fixed",
    "arr_get",
    "arr_get_u",
    "arr_len",
    "arr_new",
    "arr_new_default",
    "arr_set",
    "as_",
    "br",
    "br_if",
    "call",
    "eqz",
    "field",
    "for_i32",
    "get",
    "gget",
    "gset",
    "i32",
    "i64",
    "if_",
    "inc",
    "is_",
    "is_null",
    "loop",
    "new",
    "non_null",
    "null",
    "op",
    "or_",
    "ref_eq",
    "ret",
    "select_",
    "set",
    "setfield",
    "while_",
)

V = EQREF
STR = ref("Str")
LIST = ref("List")
TUPLE = ref("Tuple")
DICT = ref("Dict")
BUF = ref("Buf")
VALS = ref("Vals")
U8A = ref("U8")
I32A = ref("I32A")

MIN_I64 = -9223372036854775807 - 1  # not -(1 << 63): must also work compiled
SMALL_MIN = -(1 << 30)
SMALL_MAX = (1 << 30) - 1

# ---------------------------------------------------------------- emit-time helpers

def S(m, s):
    """Code producing the (interned) string constant s, as (ref $Str).

    All constant bytes live in one passive data segment; each constant gets
    a lazily-initialized global and a tiny getter function, so a use site
    is a single call."""
    pool = m["strpool"]
    if s not in pool["consts"]:
        b = utf8(s)
        off = len(pool["bytes"])
        pool["bytes"].extend(b)
        idx = len(pool["consts"])
        g = "str%d" % idx
        fn = "strconst%d" % idx
        add_global(m, g, ref("Str", True), True, [null("Str")])
        add_func(m, fn, [], [STR], [
            if_(is_null(gget(g)), gset(g, call("rt_str_from_data", i32(off), i32(len(b))))),
            non_null(gget(g)),
        ])
        pool["consts"][s] = fn
    return call(pool["consts"][s])

MAX_I64 = 9223372036854775807

# The longest array V8 will allocate (2**27 - 4 elements): the most
# elements a list, tuple or materialized range can hold.
MAX_ARRAY = 134217724

def vi(n):
    """Code for the int constant n, normalized like rt_int / rt_big_make."""
    if n >= SMALL_MIN and n <= SMALL_MAX:
        return op("ref.i31", i32(n))
    if n >= MIN_I64 and n <= MAX_I64:
        return new("Int", i64(n))
    x = -n if n < 0 else n
    limbs = []
    while x > 0:
        limb = x % 4294967296
        limbs.append(i32(limb - 4294967296 if limb >= 2147483648 else limb))
        x = x // 4294967296
    return new("Big", i32(1 if n < 0 else 0), arr_fixed("I32A", *limbs))

# $Lazy kinds: s.elems(), s.elem_ords(), s.codepoints(), s.codepoint_ords(),
# b.elems()
LAZY_ELEMS = 0
LAZY_ELEM_ORDS = 1
LAZY_CODEPOINTS = 2
LAZY_CODEPOINT_ORDS = 3
LAZY_BYTES_ELEMS = 4

def check_mutable(m, flag, frozen_msg, iter_msg):
    """Fail if a list/dict with this frozen field (code) is frozen or being
    iterated."""
    return [
        if_(op("i32.and", flag, i32(1)), fail_(m, frozen_msg)),
        if_(op("i32.shr_u", flag, i32(1)), fail_(m, iter_msg)),
    ]

def fail_(m, msg):
    return [S(m, msg), call("rt_fail"), "unreachable"]

def type_err1(m, pre, v, post):
    return [S(m, pre), v, S(m, post), call("rt_fail_type1"), "unreachable"]

def type_err2(m, pre, a, mid, b, post):
    return [S(m, pre), a, S(m, mid), b, S(m, post), call("rt_fail_type2"), "unreachable"]

def forever(label, body):
    """Infinite loop; leave it with ret() or br to an outer label."""
    return [loop(label, [body, br(label)]), "unreachable"]

def both(T, a, b):
    return and_(is_(T, a), is_(T, b))

def _mix32(h):
    """h = murmur3-style finalizer of h (i32 local)."""
    return [
        set(h, op("i32.xor", get(h), op("i32.shr_u", get(h), i32(16)))),
        set(h, op("i32.mul", get(h), i32(0x7feb352d))),
        set(h, op("i32.xor", get(h), op("i32.shr_u", get(h), i32(15)))),
        set(h, op("i32.mul", get(h), i32(0x846ca68b))),
        set(h, op("i32.xor", get(h), op("i32.shr_u", get(h), i32(16)))),
    ]

def _i64lt0(x):
    return op("i64.lt_s", x, i64(0))

# ---------------------------------------------------------------- declarations

def _declare(m, test = False):
    add_type(m, "U8", array_type(I8, True))
    add_type(m, "I32A", array_type(I32, True))
    add_type(m, "Vals", array_type(V, True))
    add_type(m, "NoneType", struct_type([]))
    add_type(m, "Bool", struct_type([("v", I32, False)]))
    add_type(m, "Int", struct_type([("v", I64, False)]))
    add_type(m, "Float", struct_type([("v", F64, False)]))
    add_type(m, "Big", struct_type([("neg", I32, False), ("mag", I32A, False)]))
    add_type(m, "Str", struct_type([("hash", I32, True), ("b", U8A, False)]))
    add_type(m, "Tuple", struct_type([("items", VALS, False)]))
    add_type(m, "List", struct_type([("len", I32, True), ("items", VALS, True), ("frozen", I32, True)]))
    add_type(m, "Dict", struct_type([
        ("len", I32, True),  # live entries
        ("used", I32, True),  # entries used, including tombstones
        ("keys", VALS, True),
        ("vals", VALS, True),
        ("hashes", I32A, True),
        ("index", I32A, True),
        ("frozen", I32, True),
    ]))
    add_type(m, "Buf", struct_type([("len", I32, True), ("b", U8A, True)]))
    add_type(m, "Set", struct_type([("d", DICT, False)]))
    add_type(m, "Bytes", struct_type([("hash", I32, True), ("b", U8A, False)]))
    add_type(m, "Struct", struct_type([("d", DICT, False)]))
    add_type(m, "Range", struct_type([("start", I64, False), ("stop", I64, False), ("step", I64, False)]))
    add_type(m, "Lazy", struct_type([("kind", I32, False), ("s", STR, False)]))

    # Functions as values. A captured variable lives in a Cell shared by the
    # defining function and its closures. A Func pairs a dynamic entry point
    # (type Code) with its signature, captured cells and default values.
    add_type(m, "Cell", struct_type([("v", V, True)]))
    add_type(m, "Sig", struct_type([
        ("name", STR, False),
        ("names", VALS, False),  # parameter names in slot order
        ("npos", I32, False),  # positional parameters
        ("varargs", I32, False),  # 1 if there is a *args slot (after positional)
        ("nkw", I32, False),  # keyword-only parameters (after *args)
        ("kwargs", I32, False),  # 1 if there is a **kwargs slot (last)
        # 0: a Starlark function; 1: a builtin whose parameters are
        # positional-only; 2: a builtin with keyword parameters (1 and 2
        # differ in starlark-go's argument error messages)
        ("kind", I32, False),
        ("recv", I32, False),  # 1 if slot 0 is a method's receiver
    ]))
    add_type(m, "Func", struct_type([
        ("code", ref("Code"), False),
        ("sig", ref("Sig"), False),
        ("env", ref("Vals", True), False),  # captured cells, or null
        ("defaults", ref("Vals", True), False),  # per slot (null = none), or null
        ("id", I32, False),  # identity, for hashing
        ("frozen", I32, True),
    ]))
    # Dynamic entry: (function, positional args, kwargs dict or null) -> result
    add_type(m, "Code", ("func", (ref("Func"), VALS, V), (V,)))
    add_type(m, "Bound", struct_type([("recv", V, False), ("fn", ref("Func"), False), ("name", STR, False)]))

    import_func(m, "host", "write", [I32, I32, I32], [], as_name = "host_write")
    import_func(m, "host", "exit", [I32], [], as_name = "host_exit")
    # fail(ptr, len, plain): a Starlark error with this message; the host
    # prints it with a traceback (mapping the engine's stack through
    # starwasm.marks) and exits with status 1. Never returns. plain=1: never
    # say "Error in <builtin>" (e.g. attribute errors).
    import_func(m, "host", "fail", [I32, I32, I32], [], as_name = "host_fail")
    # Files and arguments (used by builtins.star). Strings cross the
    # boundary through the same linear-memory staging buffer:
    #   file_size(ptr, len) -> size or -1   loads the file named by the bytes
    #   file_chunk(off, ptr, n)             copies loaded bytes into memory
    #   out_begin(ptr, len) / out_end()     write(3, ...) appends to that file
    #   arg_count() / arg_len(i) / arg_copy(i, ptr)
    import_func(m, "host", "file_size", [I32, I32], [I32], as_name = "host_file_size")
    import_func(m, "host", "file_chunk", [I32, I32, I32], [], as_name = "host_file_chunk")
    import_func(m, "host", "out_begin", [I32, I32], [], as_name = "host_out_begin")
    import_func(m, "host", "out_end", [], [], as_name = "host_out_end")
    import_func(m, "host", "arg_count", [], [I32], as_name = "host_arg_count")
    import_func(m, "host", "arg_len", [I32], [I32], as_name = "host_arg_len")
    import_func(m, "host", "arg_copy", [I32, I32], [], as_name = "host_arg_copy")
    # Floats: float_fmt(x, conv) writes x formatted like Go's
    # strconv.FormatFloat (conv 'g'/'G': shortest; 'e'/'E'/'f': precision 6)
    # at memory 0 and returns its length; float_parse(ptr, len) parses a
    # float literal, stores the f64 at memory 0 and returns 0 (ok), 1
    # (invalid) or 2 (too large); float_mod(x, y) is C's fmod.
    import_func(m, "host", "float_fmt", [F64, I32], [I32], as_name = "host_float_fmt")
    import_func(m, "host", "float_parse", [I32, I32], [I32], as_name = "host_float_parse")
    import_func(m, "host", "float_mod", [F64, F64], [F64], as_name = "host_float_mod")
    if test:
        # Test-only builtins (compile with --test; see add_test_builtins in
        # builtins.star and tests/upstream/). Strings use memory as above.
        #   catch(f) -> -1, or the length of f()'s error message (at 0);
        #               the host calls f through the test_call0 export
        #   test_error(ptr, len)   report a test failure with a traceback
        #   matches(plen, slen) -> 0/1: does the string at plen match the
        #               regular expression at 0
        #   floateq(x, y) -> 0/1: equal within 1 ULP (both NaN counts)
        import_func(m, "host", "catch", [EQREF], [I32], as_name = "host_catch")
        import_func(m, "host", "test_error", [I32, I32], [], as_name = "host_test_error")
        import_func(m, "host", "matches", [I32, I32], [I32], as_name = "host_matches")
        import_func(m, "host", "floateq", [F64, F64], [I32], as_name = "host_floateq")
    add_memory(m, 1, export = "memory")  # I/O staging buffer for host_write

    m["strpool"] = {"bytes": [], "consts": {}}
    add_data(m, "strings", m["strpool"]["bytes"])

    add_global(m, "None", ref("NoneType"), False, [("struct.new", "NoneType")])
    add_global(m, "True", ref("Bool"), False, [i32(1), ("struct.new", "Bool")])
    add_global(m, "False", ref("Bool"), False, [i32(0), ("struct.new", "Bool")])
    # second results of rt_mag_divsmall / rt_mag_divmod (the remainder)
    add_global(m, "big_rem", I64, True, [i64(0)])
    add_global(m, "big_remm", ref("I32A", True), True, [null("I32A")])
    # Default value of a builtin's optional parameter when it is used as a
    # value: "argument omitted" (never visible to Starlark code).
    add_global(m, "Absent", ref("Cell"), False, [null("eq"), ("struct.new", "Cell")])
    # Method name -> $Func taking (receiver, args...), for x.method values;
    # filled in by the compiled program's main (see compiler/codegen.star).
    add_global(m, "method_funcs", ref("Dict", True), True, [null("Dict")])

# ---------------------------------------------------------------- byte buffers, I/O, errors

def _buffers(m):
    add_func(m, "rt_buf_new", [], [BUF], [new("Buf", i32(0), arr_new_default("U8", i32(16)))])

    add_func(m, "rt_buf_reserve", [("b", BUF), ("n", I32)], [], locals = [
        ("need", I32),
        ("cap", I32),
        ("na", U8A),
    ], body = [
        set("need", op("i32.add", field("Buf", "len", get("b")), get("n"))),
        set("cap", arr_len(field("Buf", "b", get("b")))),
        if_(op("i32.gt_s", get("need"), get("cap")), [
            if_(op("i32.gt_s", op("i32.shl", get("cap"), i32(1)), get("need")),
                set("need", op("i32.shl", get("cap"), i32(1)))),
            set("na", arr_new_default("U8", get("need"))),
            arr_copy("U8", get("na"), i32(0), field("Buf", "b", get("b")), i32(0), field("Buf", "len", get("b"))),
            setfield("Buf", "b", get("b"), get("na")),
        ]),
    ])

    add_func(m, "rt_buf_byte", [("b", BUF), ("x", I32)], [], [
        call("rt_buf_reserve", get("b"), i32(1)),
        arr_set("U8", field("Buf", "b", get("b")), field("Buf", "len", get("b")), get("x")),
        setfield("Buf", "len", get("b"), op("i32.add", field("Buf", "len", get("b")), i32(1))),
    ])

    add_func(m, "rt_buf_bytes", [("b", BUF), ("src", U8A), ("start", I32), ("n", I32)], [], [
        call("rt_buf_reserve", get("b"), get("n")),
        arr_copy("U8", field("Buf", "b", get("b")), field("Buf", "len", get("b")), get("src"), get("start"), get("n")),
        setfield("Buf", "len", get("b"), op("i32.add", field("Buf", "len", get("b")), get("n"))),
    ])

    add_func(m, "rt_buf_str", [("b", BUF), ("s", STR)], [], [
        call("rt_buf_bytes", get("b"), field("Str", "b", get("s")), i32(0), arr_len(field("Str", "b", get("s")))),
    ])

    add_func(m, "rt_buf_to_str", [("b", BUF)], [STR], locals = [("na", U8A)], body = [
        set("na", arr_new_default("U8", field("Buf", "len", get("b")))),
        arr_copy("U8", get("na"), i32(0), field("Buf", "b", get("b")), i32(0), field("Buf", "len", get("b"))),
        new("Str", i32(0), get("na")),
    ])

    # Decimal digits of x. Works on the negated value so MIN_I64 is safe.
    add_func(m, "rt_buf_i64", [("b", BUF), ("x", I64)], [], locals = [
        ("i", I32),
        ("j", I32),
        ("t", I32),
        ("a", U8A),
    ], body = [
        if_(_i64lt0(get("x")),
            call("rt_buf_byte", get("b"), i32(45)),  # '-'
            set("x", op("i64.sub", i64(0), get("x")))),
        set("i", field("Buf", "len", get("b"))),
        loop("digits", [
            call("rt_buf_byte", get("b"), op("i32.sub", i32(48), op("i32.wrap_i64", op("i64.rem_s", get("x"), i64(10))))),
            set("x", op("i64.div_s", get("x"), i64(10))),
            br_if("digits", op("i64.ne", get("x"), i64(0))),
        ]),
        # digits came out least-significant first: reverse them in place
        set("a", field("Buf", "b", get("b"))),
        set("j", op("i32.sub", field("Buf", "len", get("b")), i32(1))),
        while_(op("i32.lt_s", get("i"), get("j")), [
            set("t", arr_get_u("U8", get("a"), get("i"))),
            arr_set("U8", get("a"), get("i"), arr_get_u("U8", get("a"), get("j"))),
            arr_set("U8", get("a"), get("j"), get("t")),
            inc("i"),
            inc("j", -1),
        ]),
    ])

    # Copy bytes into linear memory in 64 KiB chunks and hand them to the host.
    add_func(m, "rt_write_bytes", [("a", U8A), ("n", I32), ("fd", I32)], [], locals = [
        ("i", I32),
        ("j", I32),
        ("k", I32),
    ], body = [
        set("i", i32(0)),
        while_(op("i32.lt_s", get("i"), get("n")), [
            set("k", op("i32.sub", get("n"), get("i"))),
            if_(op("i32.gt_s", get("k"), i32(65536)), set("k", i32(65536))),
            for_i32("j", i32(0), get("k"), [
                get("j"),
                arr_get_u("U8", get("a"), op("i32.add", get("i"), get("j"))),
                ("i32.store8", 0),
            ]),
            call("host_write", get("fd"), i32(0), get("k")),
            set("i", op("i32.add", get("i"), get("k"))),
        ]),
    ])

    add_func(m, "rt_buf_write", [("b", BUF), ("fd", I32)], [], [
        call("rt_write_bytes", field("Buf", "b", get("b")), field("Buf", "len", get("b")), get("fd")),
    ])

    # Stage the message (first 64 KiB) in linear memory and hand it to the host.
    add_func(m, "rt_fail_ex", [("msg", STR), ("plain", I32)], [], locals = [("a", U8A), ("n", I32), ("i", I32)], body = [
        set("a", field("Str", "b", get("msg"))),
        set("n", arr_len(get("a"))),
        if_(op("i32.gt_s", get("n"), i32(65536)), set("n", i32(65536))),
        for_i32("i", i32(0), get("n"), [get("i"), arr_get_u("U8", get("a"), get("i")), ("i32.store8", 0)]),
        call("host_fail", i32(0), get("n"), get("plain")),
        "unreachable",
    ])
    add_func(m, "rt_fail", [("msg", STR)], [], [call("rt_fail_ex", get("msg"), i32(0)), "unreachable"])

    add_func(m, "rt_fail_type1", [("pre", STR), ("v", V), ("post", STR)], [], locals = [("b", BUF)], body = [
        set("b", call("rt_buf_new")),
        call("rt_buf_str", get("b"), get("pre")),
        call("rt_buf_str", get("b"), call("rt_type", get("v"))),
        call("rt_buf_str", get("b"), get("post")),
        call("rt_fail", call("rt_buf_to_str", get("b"))),
    ])

    add_func(m, "rt_fail_type2", [("pre", STR), ("a", V), ("mid", STR), ("x", V), ("post", STR)], [], locals = [("b", BUF)], body = [
        set("b", call("rt_buf_new")),
        call("rt_buf_str", get("b"), get("pre")),
        call("rt_buf_str", get("b"), call("rt_type", get("a"))),
        call("rt_buf_str", get("b"), get("mid")),
        call("rt_buf_str", get("b"), call("rt_type", get("x"))),
        call("rt_buf_str", get("b"), get("post")),
        call("rt_fail", call("rt_buf_to_str", get("b"))),
    ])

# ---------------------------------------------------------------- basic values

def _basics(m):
    add_func(m, "rt_type", [("v", V)], [STR], locals = [("k", I32)], body = [
        if_(or_(is_("i31", get("v")), or_(is_("Int", get("v")), is_("Big", get("v")))), ret(S(m, "int"))),
        if_(is_("Float", get("v")), ret(S(m, "float"))),
        if_(is_("Str", get("v")), ret(S(m, "string"))),
        if_(is_("List", get("v")), ret(S(m, "list"))),
        if_(is_("Tuple", get("v")), ret(S(m, "tuple"))),
        if_(is_("Dict", get("v")), ret(S(m, "dict"))),
        if_(is_("Set", get("v")), ret(S(m, "set"))),
        if_(is_("Bool", get("v")), ret(S(m, "bool"))),
        if_(is_("NoneType", get("v")), ret(S(m, "NoneType"))),
        if_(is_("Func", get("v")), ret(select_(
            field("Sig", "kind", field("Func", "sig", as_("Func", get("v")))),
            S(m, "builtin_function_or_method"),
            S(m, "function"),
            STR,
        ))),
        if_(is_("Bytes", get("v")), ret(S(m, "bytes"))),
        if_(is_("Struct", get("v")), ret(S(m, "struct"))),
        if_(is_("Bound", get("v")), ret(S(m, "builtin_function_or_method"))),
        if_(is_("Range", get("v")), ret(S(m, "range"))),
        if_(is_("Lazy", get("v")), [
            set("k", field("Lazy", "kind", as_("Lazy", get("v")))),
            if_(op("i32.le_u", get("k"), i32(LAZY_ELEM_ORDS)), ret(S(m, "string.elems"))),
            if_(op("i32.le_u", get("k"), i32(LAZY_CODEPOINT_ORDS)), ret(S(m, "string.codepoints"))),
            ret(S(m, "bytes.elems")),
        ]),
        if_(is_null(get("v")), ret(S(m, "<unbound>"))),
        S(m, "<unknown>"),
    ])

    add_func(m, "rt_bool", [("x", I32)], [V], [select_(get("x"), gget("True"), gget("False"), V)])

    add_func(m, "rt_truth", [("v", V)], [I32], [
        if_(ref_eq(get("v"), gget("None")), ret(i32(0))),
        if_(is_("Bool", get("v")), ret(field("Bool", "v", as_("Bool", get("v"))))),
        if_(is_("i31", get("v")), ret(op("i32.ne", op("i31.get_s", as_("i31", get("v"))), i32(0)))),
        if_(is_("Str", get("v")), ret(op("i32.ne", arr_len(field("Str", "b", as_("Str", get("v")))), i32(0)))),
        if_(is_("List", get("v")), ret(op("i32.ne", field("List", "len", as_("List", get("v"))), i32(0)))),
        if_(is_("Tuple", get("v")), ret(op("i32.ne", arr_len(field("Tuple", "items", as_("Tuple", get("v")))), i32(0)))),
        if_(is_("Dict", get("v")), ret(op("i32.ne", field("Dict", "len", as_("Dict", get("v"))), i32(0)))),
        if_(is_("Set", get("v")), ret(op("i32.ne", field("Dict", "len", field("Set", "d", as_("Set", get("v")))), i32(0)))),
        if_(is_("Bytes", get("v")), ret(op("i32.ne", arr_len(field("Bytes", "b", as_("Bytes", get("v")))), i32(0)))),
        if_(is_("Float", get("v")), ret(op("f64.ne", field("Float", "v", as_("Float", get("v"))), op("f64.convert_i64_s", i64(0))))),
        if_(is_("Range", get("v")), ret(op("i64.ne", call("rt_range_len", as_("Range", get("v"))), i64(0)))),
        i32(1),  # boxed ints are never zero
    ])

    add_func(m, "rt_not", [("v", V)], [V], [call("rt_bool", eqz(call("rt_truth", get("v"))))])

# ---------------------------------------------------------------- ints

def _ints(m):
    add_func(m, "rt_int", [("x", I64)], [V], [
        if_(op("i64.lt_u", op("i64.add", get("x"), i64(1 << 30)), i64(1 << 31)),
            ret(op("ref.i31", op("i32.wrap_i64", get("x"))))),
        new("Int", get("x")),
    ])

    add_func(m, "rt_is_int", [("v", V)], [I32], [or_(is_("i31", get("v")), or_(is_("Int", get("v")), is_("Big", get("v"))))])
    add_func(m, "rt_is_small", [("v", V)], [I32], [or_(is_("i31", get("v")), is_("Int", get("v")))])

    add_func(m, "rt_i64", [("v", V)], [I64], [
        if_(is_("i31", get("v")), ret(op("i64.extend_i32_s", op("i31.get_s", as_("i31", get("v")))))),
        if_(is_("Int", get("v")), ret(field("Int", "v", as_("Int", get("v"))))),
        if_(is_("Big", get("v")), [call("rt_fail", call("rt_str_concat", call("rt_str", get("v")), S(m, " out of range"))), "unreachable"]),
        type_err1(m, "got ", get("v"), ", want int"),
    ])

    overflow = fail_(m, "integer overflow")
    x, y, r = get("x"), get("y"), get("r")
    P = [("x", I64), ("y", I64)]

    add_func(m, "rt_add64", P, [I64], locals = [("r", I64)], body = [
        set("r", op("i64.add", x, y)),
        if_(_i64lt0(op("i64.and", op("i64.xor", x, r), op("i64.xor", y, r))), overflow),
        r,
    ])
    add_func(m, "rt_sub64", P, [I64], locals = [("r", I64)], body = [
        set("r", op("i64.sub", x, y)),
        if_(_i64lt0(op("i64.and", op("i64.xor", x, y), op("i64.xor", x, r))), overflow),
        r,
    ])
    add_func(m, "rt_mul64", P, [I64], locals = [("r", I64)], body = [
        if_(op("i64.eqz", x), ret(i64(0))),
        if_(and_(op("i64.eq", x, i64(-1)), op("i64.eq", y, i64(MIN_I64))), overflow),
        set("r", op("i64.mul", x, y)),
        if_(op("i64.ne", op("i64.div_s", r, x), y), overflow),
        r,
    ])
    add_func(m, "rt_floordiv64", P, [I64], locals = [("r", I64)], body = [
        if_(op("i64.eqz", y), fail_(m, "floored division by zero")),
        if_(and_(op("i64.eq", x, i64(MIN_I64)), op("i64.eq", y, i64(-1))), overflow),
        set("r", op("i64.div_s", x, y)),
        if_(and_(op("i64.ne", op("i64.rem_s", x, y), i64(0)), _i64lt0(op("i64.xor", x, y))),
            set("r", op("i64.sub", r, i64(1)))),
        r,
    ])
    add_func(m, "rt_mod64", P, [I64], locals = [("r", I64)], body = [
        if_(op("i64.eqz", y), fail_(m, "integer modulo by zero")),
        set("r", op("i64.rem_s", x, y)),
        if_(and_(op("i64.ne", r, i64(0)), _i64lt0(op("i64.xor", r, y))),
            set("r", op("i64.add", r, y))),
        r,
    ])
    add_func(m, "rt_shl64", P, [I64], locals = [("r", I64)], body = [
        if_(_i64lt0(y), call("rt_fail", call("rt_str_concat", S(m, "negative shift count: "), call("rt_str", call("rt_int", y))))),
        if_(op("i64.eqz", x), ret(i64(0))),
        if_(op("i64.ge_s", y, i64(64)), overflow),
        set("r", op("i64.shl", x, y)),
        if_(op("i64.ne", op("i64.shr_s", r, y), x), overflow),
        r,
    ])
    add_func(m, "rt_shr64", P, [I64], [
        if_(_i64lt0(y), call("rt_fail", call("rt_str_concat", S(m, "negative shift count: "), call("rt_str", call("rt_int", y))))),
        if_(op("i64.gt_s", y, i64(63)), set("y", i64(63))),
        op("i64.shr_s", x, y),
    ])

    # Binary int operators: an i64 fast path, $Big arithmetic on overflow
    # or for big operands, then floats and sets where they apply.
    A, B = get("a"), get("b")
    X, Y, R = get("x"), get("y"), get("r")
    PAB = [("a", V), ("b", V)]
    LXY = [("x", I64), ("y", I64), ("r", I64), ("k", I32)]

    def small2():
        return and_(call("rt_is_small", A), call("rt_is_small", B))

    def ints2():
        return and_(call("rt_is_int", A), call("rt_is_int", B))

    def xy():
        return [set("x", call("rt_i64", A)), set("y", call("rt_i64", B))]

    def either_float():
        return or_(is_("Float", A), is_("Float", B))

    def rest(sym, fop = None, setop = None):
        out = []
        if fop != None:
            out.append(if_(either_float(), ret(call(fop, A, B))))
        if setop != None:
            out.append(if_(both("Set", A, B), ret(call(setop, as_("Set", A), as_("Set", B)))))
        out.append(type_err2(m, "unknown binary op: ", A, " " + sym + " ", B, ""))
        return out

    add_func(m, "rt_sub", PAB, [V], locals = LXY, body = [
        if_(small2(), [
            xy(),
            set("r", op("i64.sub", X, Y)),
            if_(op("i64.ge_s", op("i64.and", op("i64.xor", X, Y), op("i64.xor", X, R)), i64(0)), ret(call("rt_int", R))),
        ]),
        if_(ints2(), ret(call("rt_big_addsub", A, B, i32(1)))),
        rest("-", "rt_fsub", "rt_set_difference"),
    ])

    def int_zero_check(msg):
        return if_(and_(call("rt_is_small", B), op("i64.eqz", call("rt_i64", B))), fail_(m, msg))

    add_func(m, "rt_floordiv", PAB, [V], locals = LXY, body = [
        if_(ints2(), [
            int_zero_check("floored division by zero"),
            if_(small2(), [
                xy(),
                if_(eqz(and_(op("i64.eq", X, i64(MIN_I64)), op("i64.eq", Y, i64(-1)))), ret(call("rt_int", call("rt_floordiv64", X, Y)))),
            ]),
            ret(call("rt_big_divmod", A, B, i32(0))),
        ]),
        rest("//", "rt_ffloordiv"),
    ])

    add_func(m, "rt_mod", PAB, [V], locals = LXY, body = [
        if_(ints2(), [
            int_zero_check("integer modulo by zero"),
            if_(small2(), ret(call("rt_int", call("rt_mod64", call("rt_i64", A), call("rt_i64", B))))),
            ret(call("rt_big_divmod", A, B, i32(1))),
        ]),
        rest("%", "rt_fmod"),
    ])

    for fname, sym, wop, which, setop in [
        ("rt_and", "&", "i64.and", 0, "rt_set_intersection"),
        ("rt_or", "|", "i64.or", 1, "rt_set_union"),
        ("rt_xor", "^", "i64.xor", 2, "rt_set_symmetric_difference"),
    ]:
        add_func(m, fname, PAB, [V], [
            if_(small2(), ret(call("rt_int", op(wop, call("rt_i64", A), call("rt_i64", B))))),
            if_(ints2(), ret(call("rt_big_bitop", A, B, i32(which)))),
            if_(and_(is_("Dict", A), is_("Dict", B)), ret(call("rt_dict_union", as_("Dict", A), as_("Dict", B)))) if fname == "rt_or" else None,
            rest(sym, None, setop),
        ])

    # A shift count: an int in [0, 2^31) (and < 512 for <<), as starlark-go.
    add_func(m, "rt_shift_count", [("y", V), ("left", I32)], [I32], locals = [("x", I64)], body = [
        if_(eqz(call("rt_is_small", get("y"))),
            [call("rt_fail", call("rt_str_concat", call("rt_str", get("y")), S(m, " out of range"))), "unreachable"]),
        set("x", call("rt_i64", get("y"))),
        if_(or_(op("i64.lt_s", X, i64(-(1 << 31))), op("i64.gt_s", X, i64((1 << 31) - 1))),
            [call("rt_fail", call("rt_str_concat", call("rt_str", get("y")), S(m, " out of range"))), "unreachable"]),
        if_(op("i64.lt_s", X, i64(0)), call("rt_fail", call("rt_str_concat", S(m, "negative shift count: "), call("rt_str", get("y"))))),
        if_(and_(get("left"), op("i64.ge_s", X, i64(512))),
            call("rt_fail", call("rt_str_concat", S(m, "shift count too large: "), call("rt_str", get("y"))))),
        op("i32.wrap_i64", X),
    ])

    add_func(m, "rt_shl", PAB, [V], locals = LXY, body = [
        if_(ints2(), [
            set("k", call("rt_shift_count", B, i32(1))),
            if_(call("rt_is_small", A), [
                set("x", call("rt_i64", A)),
                if_(op("i32.lt_s", get("k"), i32(63)), [
                    set("r", op("i64.shl", X, op("i64.extend_i32_u", get("k")))),
                    if_(op("i64.eq", op("i64.shr_s", R, op("i64.extend_i32_u", get("k"))), X), ret(call("rt_int", R))),
                ]),
            ]),
            ret(call("rt_big_shift", A, get("k"), i32(1))),
        ]),
        rest("<<"),
    ])

    add_func(m, "rt_shr", PAB, [V], locals = LXY, body = [
        if_(ints2(), [
            set("k", call("rt_shift_count", B, i32(0))),
            if_(call("rt_is_small", A), ret(call("rt_int", op("i64.shr_s", call("rt_i64", A),
                op("i64.extend_i32_u", select_(op("i32.gt_s", get("k"), i32(63)), i32(63), get("k"), I32)))))),
            ret(call("rt_big_shift", A, get("k"), i32(0))),
        ]),
        rest(">>"),
    ])

    add_func(m, "rt_neg", [("v", V)], [V], [
        if_(call("rt_is_small", get("v")), [
            if_(op("i64.ne", call("rt_i64", get("v")), i64(MIN_I64)),
                ret(call("rt_int", op("i64.sub", i64(0), call("rt_i64", get("v")))))),
        ]),
        if_(call("rt_is_int", get("v")), ret(call("rt_big_neg", get("v")))),
        if_(is_("Float", get("v")), ret(new("Float", op("f64.neg", field("Float", "v", as_("Float", get("v"))))))),
        type_err1(m, "unknown unary op: - ", get("v"), ""),
    ])
    add_func(m, "rt_invert", [("v", V)], [V], [
        if_(call("rt_is_int", get("v")), ret(call("rt_xor", get("v"), op("ref.i31", i32(-1))))),
        type_err1(m, "unknown unary op: ~ ", get("v"), ""),
    ])
    add_func(m, "rt_pos", [("v", V)], [V], [
        if_(or_(call("rt_is_int", get("v")), is_("Float", get("v"))), ret(get("v"))),
        type_err1(m, "unknown unary op: + ", get("v"), ""),
    ])

# ---------------------------------------------------------------- strings

def bstr(v):
    """The bytes value v (an eqref known to be a $Bytes) as a $Str sharing its
    array, so string functions can work on it."""
    return new("Str", i32(0), field("Bytes", "b", as_("Bytes", v)))

def str_bytes(s):
    """The $Str s (code) as a $Bytes sharing its array."""
    return new("Bytes", i32(0), field("Str", "b", s))

# ---------------------------------------------------------------- big ints
#
# Ints that don't fit in an i64 are (ref $Big) = {neg, mag}: sign and
# magnitude, mag an $I32A of 32-bit limbs, least significant first, with no
# zero limbs on top. Normalized: a value that fits in an i64 is never a
# $Big (rt_big_make), so equal ints still have equal representations. The
# int operations take a fast i64 path and fall back to these on overflow.

def _lg(a, i):
    return arr_get("I32A", a, i)

def _lu(a, i):
    """Limb i of a as an unsigned i64."""
    return op("i64.extend_i32_u", arr_get("I32A", a, i))

def _ls(a, i, v):
    """Set limb i of a to the low 32 bits of i64 v."""
    return arr_set("I32A", a, i, op("i32.wrap_i64", v))

# ---------------------------------------------------------------- Unicode
#
# Character properties as Go's unicode/strconv packages define them (which
# starlark-go uses), from lib/unicode_tables.star (generated from Go by
# tools/gen_unicode.go). Each table is a passive data segment of
# little-endian i32s, turned into an $I32A on first use. The print table is
# always present (repr needs it); the class and case tables are filled in
# only when the program uses a method that needs them (add_unicode_tables).

def _le32(xs):
    out = []
    for x in xs:
        if x < 0:
            x += 4294967296
        out.extend([x & 255, (x >> 8) & 255, (x >> 16) & 255, (x >> 24) & 255])
    return out

def add_unicode_tables(m):
    """Fill in the class and case tables (see above)."""
    if not m["uni_class"]:
        m["uni_class"].extend(_le32(CLASS_RANGES))
        m["uni_case"].extend(_le32(CASE_RANGES))

def _unicode(m):
    add_data(m, "uni_print", _le32(PRINT_RANGES))
    m["uni_class"] = []
    m["uni_case"] = []
    add_data(m, "uni_class", m["uni_class"])
    add_data(m, "uni_case", m["uni_case"])
    for name, n in [("uni_print", len(PRINT_RANGES)), ("uni_class", len(CLASS_RANGES)), ("uni_case", len(CASE_RANGES))]:
        add_global(m, "g_" + name, ref("I32A", True), True, [null("I32A")])
        add_func(m, "rt_" + name, [], [I32A], [
            if_(is_null(gget("g_" + name)), gset("g_" + name, [i32(0), i32(n), ("array.new_data", "I32A", name)])),
            non_null(gget("g_" + name)),
        ])

    # Index (of the first i32) of the range of table t (entries of `stride`
    # i32s starting [lo, hi, ...], sorted) containing r, or -1.
    add_func(m, "rt_uni_find", [("t", I32A), ("stride", I32), ("r", I32)], [I32], locals = [("lo", I32), ("hi", I32), ("mid", I32), ("p", I32)], body = [
        set("lo", i32(0)),
        set("hi", op("i32.div_u", arr_len(get("t")), get("stride"))),
        while_(op("i32.lt_s", get("lo"), get("hi")), [
            set("mid", op("i32.shr_u", op("i32.add", get("lo"), get("hi")), i32(1))),
            set("p", op("i32.mul", get("mid"), get("stride"))),
            if_(op("i32.lt_s", get("r"), arr_get("I32A", get("t"), get("p"))), [set("hi", get("mid")), br("loop")]),
            if_(op("i32.gt_s", get("r"), arr_get("I32A", get("t"), op("i32.add", get("p"), i32(1)))), [set("lo", op("i32.add", get("mid"), i32(1))), br("loop")]),
            ret(get("p")),
        ]),
        i32(-1),
    ])

    add_func(m, "rt_uni_isprint", [("r", I32)], [I32], [
        if_(op("i32.lt_u", get("r"), i32(0x80)), ret(and_(op("i32.ge_u", get("r"), i32(0x20)), op("i32.lt_u", get("r"), i32(0x7f))))),
        op("i32.ge_s", call("rt_uni_find", call("rt_uni_print"), i32(2), get("r")), i32(0)),
    ])

    # flags of rune r: 1 letter, 2 digit, 4 space, 8 upper, 16 lower,
    # 32 title, 64 cased (has other cases: unicode.SimpleFold(r) != r)
    add_func(m, "rt_uni_flags", [("r", I32)], [I32], locals = [("p", I32), ("t", I32A)], body = [
        set("t", call("rt_uni_class")),
        set("p", call("rt_uni_find", get("t"), i32(3), get("r"))),
        if_(op("i32.lt_s", get("p"), i32(0)), ret(i32(0))),
        arr_get("I32A", get("t"), op("i32.add", get("p"), i32(2))),
    ])

    # unicode.To(c, r): c 0 upper, 1 lower, 2 title (Go's `to`, with its
    # ASCII fast paths)
    add_func(m, "rt_uni_to", [("c", I32), ("r", I32)], [I32], locals = [("p", I32), ("t", I32A), ("d", I32), ("lo", I32)], body = [
        if_(op("i32.lt_u", get("r"), i32(0x80)), [
            if_(and_(eqz(op("i32.eq", get("c"), i32(1))), and_(op("i32.ge_u", get("r"), i32(97)), op("i32.le_u", get("r"), i32(122)))),
                ret(op("i32.sub", get("r"), i32(32)))),
            if_(and_(op("i32.eq", get("c"), i32(1)), and_(op("i32.ge_u", get("r"), i32(65)), op("i32.le_u", get("r"), i32(90)))),
                ret(op("i32.add", get("r"), i32(32)))),
            ret(get("r")),
        ]),
        set("t", call("rt_uni_case")),
        set("p", call("rt_uni_find", get("t"), i32(5), get("r"))),
        if_(op("i32.lt_s", get("p"), i32(0)), ret(get("r"))),
        set("d", arr_get("I32A", get("t"), op("i32.add", op("i32.add", get("p"), i32(2)), get("c")))),
        if_(op("i32.gt_s", get("d"), i32(0x10ffff)), [
            # alternating upper/lower sequence: even offsets upper, odd lower
            set("lo", arr_get("I32A", get("t"), get("p"))),
            ret(op("i32.add", get("lo"), op("i32.or", op("i32.and", op("i32.sub", get("r"), get("lo")), i32(-2)), op("i32.and", get("c"), i32(1))))),
        ]),
        op("i32.add", get("r"), get("d")),
    ])

    add_func(m, "rt_uni_cased", [("r", I32)], [I32], [
        or_(or_(and_(op("i32.ge_u", get("r"), i32(97)), op("i32.le_u", get("r"), i32(122))),
                and_(op("i32.ge_u", get("r"), i32(65)), op("i32.le_u", get("r"), i32(90)))),
            op("i32.ne", op("i32.and", call("rt_uni_flags", get("r")), i32(64)), i32(0))),
    ])

    # Append rune r as UTF-8.
    add_func(m, "rt_buf_rune", [("b", BUF), ("c", I32)], [], [
        if_(op("i32.lt_u", get("c"), i32(0x80)), [call("rt_buf_byte", get("b"), get("c")), "return"]),
        if_(op("i32.lt_u", get("c"), i32(0x800)), [
            call("rt_buf_byte", get("b"), op("i32.or", i32(0xc0), op("i32.shr_u", get("c"), i32(6)))),
            call("rt_buf_byte", get("b"), op("i32.or", i32(0x80), op("i32.and", get("c"), i32(63)))),
            "return",
        ]),
        if_(op("i32.lt_u", get("c"), i32(0x10000)), [
            call("rt_buf_byte", get("b"), op("i32.or", i32(0xe0), op("i32.shr_u", get("c"), i32(12)))),
        ], [
            call("rt_buf_byte", get("b"), op("i32.or", i32(0xf0), op("i32.shr_u", get("c"), i32(18)))),
            call("rt_buf_byte", get("b"), op("i32.or", i32(0x80), op("i32.and", op("i32.shr_u", get("c"), i32(12)), i32(63)))),
        ]),
        call("rt_buf_byte", get("b"), op("i32.or", i32(0x80), op("i32.and", op("i32.shr_u", get("c"), i32(6)), i32(63)))),
        call("rt_buf_byte", get("b"), op("i32.or", i32(0x80), op("i32.and", get("c"), i32(63)))),
    ])

    # Case conversion of string s, rune by rune (an invalid byte is U+FFFD,
    # as Go's strings.Map and range loops): mode 0 upper, 1 lower, 2 title
    # (starlark-go's: title case after uncased runes, else lower case),
    # 3 capitalize (title case first, then lower case).
    add_func(m, "rt_str_case", [("s", STR), ("mode", I32)], [STR], locals = [
        ("a", U8A), ("n", I32), ("i", I32), ("k", I32), ("r", I32), ("b", BUF), ("prev", I32),
    ], body = [
        set("a", field("Str", "b", get("s"))),
        set("n", arr_len(get("a"))),
        set("b", call("rt_buf_new")),
        set("prev", i32(0)),
        set("i", i32(0)),
        while_(op("i32.lt_s", get("i"), get("n")), [
            set("k", call("rt_utf8_seq", get("a"), get("i"), get("n"))),
            if_(get("k"), set("r", call("rt_utf8_rune", get("a"), get("i"), get("k"))), [set("r", i32(0xfffd)), set("k", i32(1))]),
            if_(op("i32.le_u", get("mode"), i32(1)), set("r", call("rt_uni_to", get("mode"), get("r"))),
            if_(op("i32.eq", get("mode"), i32(2)), [
                set("r", call("rt_uni_to", select_(get("prev"), i32(1), i32(2), I32), get("r"))),
                set("prev", call("rt_uni_cased", get("r"))),
            ], set("r", call("rt_uni_to", select_(op("i32.eqz", get("i")), i32(2), i32(1), I32), get("r"))))),
            call("rt_buf_rune", get("b"), get("r")),
            set("i", op("i32.add", get("i"), get("k"))),
        ]),
        call("rt_buf_to_str", get("b")),
    ])

    # Character tests on string s (rune by rune, invalid bytes as U+FFFD):
    # 0 isalnum, 1 isalpha, 2 isdigit, 3 isspace (all runes, non-empty),
    # 4 islower, 5 isupper (some cased rune, and unchanged by lower()/
    # upper()), 6 istitle (starlark-go's rules).
    add_func(m, "rt_str_class", [("s", STR), ("mode", I32)], [I32], locals = [
        ("a", U8A), ("n", I32), ("i", I32), ("k", I32), ("r", I32), ("f", I32), ("want", I32),
        ("cased", I32), ("prev", I32),
    ], body = [
        set("a", field("Str", "b", get("s"))),
        set("n", arr_len(get("a"))),
        if_(op("i32.ge_u", get("mode"), i32(4)), [
            if_(op("i32.lt_u", get("mode"), i32(6)), [
                # some cased rune ...
                set("cased", i32(0)),
                set("i", i32(0)),
                while_(and_(eqz(get("cased")), op("i32.lt_s", get("i"), get("n"))), [
                    set("k", call("rt_utf8_seq", get("a"), get("i"), get("n"))),
                    if_(get("k"), set("r", call("rt_utf8_rune", get("a"), get("i"), get("k"))), [set("r", i32(0xfffd)), set("k", i32(1))]),
                    set("cased", call("rt_uni_cased", get("r"))),
                    set("i", op("i32.add", get("i"), get("k"))),
                ], label = "c"),
                # ... and s == s.lower() / s.upper()
                ret(and_(get("cased"), call("rt_str_eq", get("s"), call("rt_str_case", get("s"), op("i32.sub", i32(5), get("mode")))))),
            ]),
            # istitle
            set("cased", i32(0)),
            set("prev", i32(0)),
            set("i", i32(0)),
            while_(op("i32.lt_s", get("i"), get("n")), [
                set("k", call("rt_utf8_seq", get("a"), get("i"), get("n"))),
                if_(get("k"), set("r", call("rt_utf8_rune", get("a"), get("i"), get("k"))), [set("r", i32(0xfffd)), set("k", i32(1))]),
                set("f", select_(op("i32.lt_u", get("r"), i32(0x80)), i32(0), call("rt_uni_flags", get("r")), I32)),
                if_(or_(and_(op("i32.ge_u", get("r"), i32(65)), op("i32.le_u", get("r"), i32(90))), op("i32.and", get("f"), i32(32))), [
                    if_(get("prev"), ret(i32(0))),
                    set("prev", i32(1)),
                    set("cased", i32(1)),
                ], if_(or_(and_(op("i32.ge_u", get("r"), i32(97)), op("i32.le_u", get("r"), i32(122))), op("i32.and", get("f"), i32(16))), [
                    if_(eqz(get("prev")), ret(i32(0))),
                    set("prev", i32(1)),
                    set("cased", i32(1)),
                ], if_(op("i32.and", get("f"), i32(8)), ret(i32(0)), set("prev", i32(0))))),
                set("i", op("i32.add", get("i"), get("k"))),
            ], label = "t"),
            ret(get("cased")),
        ]),
        # 1 letter (| 2 digit for alnum), 2 digit, 4 space
        set("want", select_(eqz(get("mode")), i32(3), select_(op("i32.eq", get("mode"), i32(1)), i32(1),
                            select_(op("i32.eq", get("mode"), i32(2)), i32(2), i32(4), I32), I32), I32)),
        set("i", i32(0)),
        while_(op("i32.lt_s", get("i"), get("n")), [
            set("k", call("rt_utf8_seq", get("a"), get("i"), get("n"))),
            if_(get("k"), set("r", call("rt_utf8_rune", get("a"), get("i"), get("k"))), [set("r", i32(0xfffd)), set("k", i32(1))]),
            if_(op("i32.lt_u", get("r"), i32(0x80)), [
                # ASCII: same answers as the tables, without them
                set("f", i32(0)),
                if_(or_(and_(op("i32.ge_u", get("r"), i32(97)), op("i32.le_u", get("r"), i32(122))),
                        and_(op("i32.ge_u", get("r"), i32(65)), op("i32.le_u", get("r"), i32(90)))), set("f", i32(1))),
                if_(and_(op("i32.ge_u", get("r"), i32(48)), op("i32.le_u", get("r"), i32(57))), set("f", i32(2))),
                if_(or_(op("i32.eq", get("r"), i32(32)), and_(op("i32.ge_u", get("r"), i32(9)), op("i32.le_u", get("r"), i32(13)))), set("f", i32(4))),
            ], set("f", call("rt_uni_flags", get("r")))),
            if_(eqz(op("i32.and", get("f"), get("want"))), ret(i32(0))),
            set("i", op("i32.add", get("i"), get("k"))),
        ], label = "a"),
        op("i32.gt_s", get("n"), i32(0)),
    ])

def _magnitudes(m):
    U = I32A
    a, b, r, n = get("a"), get("b"), get("r"), get("n")

    def la():
        return arr_len(a)

    def lb():
        return arr_len(b)

    # a[:n] without its zero limbs on top (a itself when nothing changes)
    add_func(m, "rt_mag_trim", [("a", U), ("n", I32)], [U], locals = [("r", U)], body = [
        while_(and_(op("i32.gt_s", n, i32(0)), eqz(_lg(a, op("i32.sub", n, i32(1))))), set("n", op("i32.sub", n, i32(1))), label = "top"),
        if_(op("i32.eq", n, la()), ret(a)),
        set("r", arr_new_default("I32A", n)),
        arr_copy("I32A", r, i32(0), a, i32(0), n),
        r,
    ])

    add_func(m, "rt_mag_of_u64", [("x", I64)], [U], [
        if_(op("i64.eqz", get("x")), ret(arr_new_default("I32A", i32(0)))),
        if_(op("i64.eqz", op("i64.shr_u", get("x"), i64(32))), ret(arr_fixed("I32A", op("i32.wrap_i64", get("x"))))),
        arr_fixed("I32A", op("i32.wrap_i64", get("x")), op("i32.wrap_i64", op("i64.shr_u", get("x"), i64(32)))),
    ])

    add_func(m, "rt_mag_cmp", [("a", U), ("b", U)], [I32], locals = [("i", I32)], body = [
        if_(op("i32.ne", la(), lb()), ret(select_(op("i32.gt_s", la(), lb()), i32(1), i32(-1), I32))),
        set("i", op("i32.sub", la(), i32(1))),
        while_(op("i32.ge_s", get("i"), i32(0)), [
            if_(op("i32.ne", _lg(a, get("i")), _lg(b, get("i"))),
                ret(select_(op("i32.lt_u", _lg(a, get("i")), _lg(b, get("i"))), i32(-1), i32(1), I32))),
            set("i", op("i32.sub", get("i"), i32(1))),
        ]),
        i32(0),
    ])

    def limb_or0(x, i, nx):
        return select_(op("i32.lt_s", i, nx), _lu(x, i), i64(0), I64)

    add_func(m, "rt_mag_add", [("a", U), ("b", U)], [U], locals = [("r", U), ("n", I32), ("i", I32), ("c", I64)], body = [
        set("n", op("i32.add", select_(op("i32.gt_s", la(), lb()), la(), lb(), I32), i32(1))),
        set("r", arr_new_default("I32A", n)),
        set("c", i64(0)),
        for_i32("i", i32(0), n, [
            set("c", op("i64.add", op("i64.add", get("c"), limb_or0(a, get("i"), la())), limb_or0(b, get("i"), lb()))),
            _ls(r, get("i"), get("c")),
            set("c", op("i64.shr_u", get("c"), i64(32))),
        ]),
        call("rt_mag_trim", r, n),
    ])

    # a - b, for a >= b
    add_func(m, "rt_mag_sub", [("a", U), ("b", U)], [U], locals = [("r", U), ("i", I32), ("c", I64), ("s", I64)], body = [
        set("r", arr_new_default("I32A", la())),
        set("c", i64(0)),
        for_i32("i", i32(0), la(), [
            set("s", op("i64.sub", op("i64.sub", _lu(a, get("i")), limb_or0(b, get("i"), lb())), get("c"))),
            set("c", op("i64.shr_u", get("s"), i64(63))),  # borrow: s < 0
            _ls(r, get("i"), get("s")),
        ]),
        call("rt_mag_trim", r, la()),
    ])

    add_func(m, "rt_mag_mul", [("a", U), ("b", U)], [U], locals = [("r", U), ("i", I32), ("j", I32), ("c", I64), ("x", I64), ("t", I64)], body = [
        set("r", arr_new_default("I32A", op("i32.add", la(), lb()))),
        for_i32("i", i32(0), la(), [
            set("c", i64(0)),
            set("x", _lu(a, get("i"))),
            for_i32("j", i32(0), lb(), [
                # fits: (2^32-1)^2 + 2(2^32-1) = 2^64-1
                set("t", op("i64.add", op("i64.add", op("i64.mul", get("x"), _lu(b, get("j"))),
                                          _lu(r, op("i32.add", get("i"), get("j")))), get("c"))),
                _ls(r, op("i32.add", get("i"), get("j")), get("t")),
                set("c", op("i64.shr_u", get("t"), i64(32))),
            ], label = "inner"),
            _ls(r, op("i32.add", get("i"), lb()), get("c")),
        ], label = "outer"),
        call("rt_mag_trim", r, op("i32.add", la(), lb())),
    ])

    # a * mul + add (mul, add < 2^32)
    add_func(m, "rt_mag_muladd", [("a", U), ("mul", I64), ("add", I64)], [U], locals = [("r", U), ("i", I32), ("c", I64), ("t", I64)], body = [
        set("r", arr_new_default("I32A", op("i32.add", la(), i32(1)))),
        set("c", get("add")),
        for_i32("i", i32(0), la(), [
            set("t", op("i64.add", op("i64.mul", _lu(a, get("i")), get("mul")), get("c"))),
            _ls(r, get("i"), get("t")),
            set("c", op("i64.shr_u", get("t"), i64(32))),
        ]),
        _ls(r, la(), get("c")),
        call("rt_mag_trim", r, op("i32.add", la(), i32(1))),
    ])

    # a // d for 0 < d < 2^32; the remainder goes to global big_rem
    add_func(m, "rt_mag_divsmall", [("a", U), ("d", I64)], [U], locals = [("r", U), ("i", I32), ("rem", I64), ("cur", I64)], body = [
        set("r", arr_new_default("I32A", la())),
        set("rem", i64(0)),
        set("i", op("i32.sub", la(), i32(1))),
        while_(op("i32.ge_s", get("i"), i32(0)), [
            set("cur", op("i64.or", op("i64.shl", get("rem"), i64(32)), _lu(a, get("i")))),
            _ls(r, get("i"), op("i64.div_u", get("cur"), get("d"))),
            set("rem", op("i64.rem_u", get("cur"), get("d"))),
            set("i", op("i32.sub", get("i"), i32(1))),
        ]),
        gset("big_rem", get("rem")),
        call("rt_mag_trim", r, la()),
    ])

    add_func(m, "rt_mag_shl", [("a", U), ("k", I32)], [U], locals = [("r", U), ("q", I32), ("s", I64), ("i", I32), ("v", I64), ("n", I32)], body = [
        set("q", op("i32.shr_u", get("k"), i32(5))),
        set("s", op("i64.extend_i32_u", op("i32.and", get("k"), i32(31)))),
        set("n", op("i32.add", op("i32.add", la(), get("q")), i32(1))),
        set("r", arr_new_default("I32A", n)),
        for_i32("i", i32(0), la(), [
            set("v", op("i64.shl", _lu(a, get("i")), get("s"))),
            arr_set("I32A", r, op("i32.add", get("i"), get("q")),
                    op("i32.or", _lg(r, op("i32.add", get("i"), get("q"))), op("i32.wrap_i64", get("v")))),
            _ls(r, op("i32.add", op("i32.add", get("i"), get("q")), i32(1)), op("i64.shr_u", get("v"), i64(32))),
        ]),
        call("rt_mag_trim", r, n),
    ])

    add_func(m, "rt_mag_shr", [("a", U), ("k", I32)], [U], locals = [("r", U), ("q", I32), ("s", I64), ("i", I32), ("n", I32), ("hi", I64)], body = [
        set("q", op("i32.shr_u", get("k"), i32(5))),
        if_(op("i32.ge_u", get("q"), la()), ret(arr_new_default("I32A", i32(0)))),
        set("s", op("i64.extend_i32_u", op("i32.and", get("k"), i32(31)))),
        set("n", op("i32.sub", la(), get("q"))),
        set("r", arr_new_default("I32A", n)),
        for_i32("i", i32(0), n, [
            set("hi", select_(op("i32.lt_s", op("i32.add", op("i32.add", get("i"), get("q")), i32(1)), la()),
                              op("i64.shl", _lu(a, op("i32.add", op("i32.add", get("i"), get("q")), i32(1))), op("i64.sub", i64(32), get("s"))),
                              i64(0), I64)),
            _ls(r, get("i"), op("i64.or", op("i64.shr_u", _lu(a, op("i32.add", get("i"), get("q"))), get("s")), get("hi"))),
        ]),
        call("rt_mag_trim", r, n),
    ])

    # a // b (b != 0); the remainder goes to global big_remm. Binary long
    # division: one bit of a at a time into the running remainder.
    add_func(m, "rt_mag_divmod", [("a", U), ("b", U)], [U], locals = [
        ("r", U), ("q", U), ("i", I32), ("j", I32), ("nb", I32), ("c", I64), ("t", I64), ("ge", I32),
    ], body = [
        if_(op("i32.lt_s", call("rt_mag_cmp", a, b), i32(0)), [gset("big_remm", a), ret(arr_new_default("I32A", i32(0)))]),
        if_(op("i32.eq", lb(), i32(1)), [
            set("q", call("rt_mag_divsmall", a, _lu(b, i32(0)))),
            gset("big_remm", call("rt_mag_of_u64", gget("big_rem"))),
            ret(get("q")),
        ]),
        set("nb", op("i32.add", lb(), i32(1))),
        set("r", arr_new_default("I32A", get("nb"))),
        set("q", arr_new_default("I32A", la())),
        set("i", op("i32.sub", op("i32.shl", la(), i32(5)), i32(1))),
        while_(op("i32.ge_s", get("i"), i32(0)), [
            # r = r << 1 | bit i of a
            set("c", op("i64.and", op("i64.shr_u", _lu(a, op("i32.shr_u", get("i"), i32(5))),
                                          op("i64.extend_i32_u", op("i32.and", get("i"), i32(31)))), i64(1))),
            for_i32("j", i32(0), get("nb"), [
                set("t", op("i64.or", op("i64.shl", _lu(r, get("j")), i64(1)), get("c"))),
                _ls(r, get("j"), get("t")),
                set("c", op("i64.shr_u", get("t"), i64(32))),
            ], label = "shift"),
            # r >= b ?
            set("ge", op("i32.ne", _lg(r, lb()), i32(0))),
            if_(eqz(get("ge")), [
                set("ge", i32(1)),
                set("j", op("i32.sub", lb(), i32(1))),
                while_(op("i32.ge_s", get("j"), i32(0)), [
                    if_(op("i32.ne", _lg(r, get("j")), _lg(b, get("j"))), [
                        set("ge", op("i32.gt_u", _lg(r, get("j")), _lg(b, get("j")))),
                        br("cmp_break"),
                    ]),
                    set("j", op("i32.sub", get("j"), i32(1))),
                ], label = "cmp"),
            ]),
            if_(get("ge"), [
                set("c", i64(0)),
                for_i32("j", i32(0), get("nb"), [
                    set("t", op("i64.sub", op("i64.sub", _lu(r, get("j")), limb_or0(b, get("j"), lb())), get("c"))),
                    set("c", op("i64.shr_u", get("t"), i64(63))),
                    _ls(r, get("j"), get("t")),
                ], label = "sub"),
                arr_set("I32A", get("q"), op("i32.shr_u", get("i"), i32(5)),
                        op("i32.or", _lg(get("q"), op("i32.shr_u", get("i"), i32(5))),
                           op("i32.shl", i32(1), op("i32.and", get("i"), i32(31))))),
            ]),
            set("i", op("i32.sub", get("i"), i32(1))),
        ]),
        gset("big_remm", call("rt_mag_trim", r, get("nb"))),
        call("rt_mag_trim", get("q"), la()),
    ])

    # The n-limb two's complement negation of a (a padded to n limbs).
    add_func(m, "rt_mag_negate", [("a", U), ("n", I32)], [U], locals = [("r", U), ("i", I32), ("c", I64)], body = [
        set("r", arr_new_default("I32A", n)),
        set("c", i64(1)),
        for_i32("i", i32(0), n, [
            set("c", op("i64.add", op("i64.xor", limb_or0(a, get("i"), la()), i64(0xffffffff)), get("c"))),
            _ls(r, get("i"), get("c")),
            set("c", op("i64.shr_u", get("c"), i64(32))),
        ]),
        r,
    ])

def _bigints(m):
    U = I32A
    a, b = get("a"), get("b")

    def BF(f, v):
        return field("Big", f, as_("Big", v))

    add_func(m, "rt_int_neg", [("v", V)], [I32], [
        if_(is_("Big", get("v")), ret(BF("neg", get("v")))),
        op("i64.lt_s", call("rt_i64", get("v")), i64(0)),
    ])

    # |v| as limbs, for any int v
    add_func(m, "rt_int_mag", [("v", V)], [U], locals = [("x", I64)], body = [
        if_(is_("Big", get("v")), ret(BF("mag", get("v")))),
        set("x", call("rt_i64", get("v"))),
        call("rt_mag_of_u64", select_(op("i64.lt_s", get("x"), i64(0)), op("i64.sub", i64(0), get("x")), get("x"), I64)),
    ])

    # The int with this sign and magnitude, normalized.
    add_func(m, "rt_big_make", [("neg", I32), ("mag", U)], [V], locals = [("n", I32), ("u", I64)], body = [
        set("n", arr_len(get("mag"))),
        if_(eqz(get("n")), ret(op("ref.i31", i32(0)))),
        if_(op("i32.le_s", get("n"), i32(2)), [
            set("u", op("i64.or", _lu(get("mag"), i32(0)),
                        select_(op("i32.eq", get("n"), i32(2)), op("i64.shl", _lu(get("mag"), i32(1)), i64(32)), i64(0), I64))),
            if_(and_(eqz(get("neg")), op("i64.ge_s", get("u"), i64(0))), ret(call("rt_int", get("u")))),
            if_(and_(get("neg"), op("i64.le_u", get("u"), i64(MIN_I64))), ret(call("rt_int", op("i64.sub", i64(0), get("u"))))),
        ]),
        new("Big", get("neg"), get("mag")),
    ])

    def parts():
        return [
            set("na", call("rt_int_neg", a)), set("ma", call("rt_int_mag", a)),
            set("nb", call("rt_int_neg", b)), set("mb", call("rt_int_mag", b)),
        ]

    PL = [("na", I32), ("ma", U), ("nb", I32), ("mb", U)]

    # a + b, or a - b (flip = 1), for ints
    add_func(m, "rt_big_addsub", [("a", V), ("b", V), ("flip", I32)], [V], locals = PL + [("c", I32)], body = [
        parts(),
        set("nb", op("i32.xor", get("nb"), get("flip"))),
        if_(op("i32.eq", get("na"), get("nb")), ret(call("rt_big_make", get("na"), call("rt_mag_add", get("ma"), get("mb"))))),
        set("c", call("rt_mag_cmp", get("ma"), get("mb"))),
        if_(op("i32.ge_s", get("c"), i32(0)), ret(call("rt_big_make", get("na"), call("rt_mag_sub", get("ma"), get("mb"))))),
        call("rt_big_make", get("nb"), call("rt_mag_sub", get("mb"), get("ma"))),
    ])

    add_func(m, "rt_big_mul", [("a", V), ("b", V)], [V], locals = PL, body = [
        parts(),
        call("rt_big_make", op("i32.xor", get("na"), get("nb")), call("rt_mag_mul", get("ma"), get("mb"))),
    ])

    # a // b (want_mod = 0) or a % b (1), floored; b != 0
    add_func(m, "rt_big_divmod", [("a", V), ("b", V), ("want_mod", I32)], [V], locals = PL + [("q", U), ("r", U)], body = [
        parts(),
        set("q", call("rt_mag_divmod", get("ma"), get("mb"))),
        set("r", non_null(gget("big_remm"))),
        if_(and_(op("i32.gt_s", arr_len(get("r")), i32(0)), op("i32.ne", get("na"), get("nb"))), [
            set("q", call("rt_mag_add", get("q"), arr_fixed("I32A", i32(1)))),
            set("r", call("rt_mag_sub", get("mb"), get("r"))),
        ]),
        if_(get("want_mod"), ret(call("rt_big_make", get("nb"), get("r")))),
        call("rt_big_make", op("i32.xor", get("na"), get("nb")), get("q")),
    ])

    # three-way comparison of ints
    add_func(m, "rt_big_cmp", [("a", V), ("b", V)], [I32], locals = PL + [("x", I64), ("y", I64), ("c", I32)], body = [
        if_(eqz(or_(is_("Big", a), is_("Big", b))), [
            set("x", call("rt_i64", a)),
            set("y", call("rt_i64", b)),
            ret(op("i32.sub", op("i64.gt_s", get("x"), get("y")), op("i64.lt_s", get("x"), get("y")))),
        ]),
        parts(),
        if_(op("i32.ne", get("na"), get("nb")), ret(select_(get("na"), i32(-1), i32(1), I32))),
        set("c", call("rt_mag_cmp", get("ma"), get("mb"))),
        select_(get("na"), op("i32.sub", i32(0), get("c")), get("c"), I32),
    ])

    add_func(m, "rt_big_neg", [("a", V)], [V], [
        call("rt_big_make", eqz(call("rt_int_neg", a)), call("rt_int_mag", a)),
    ])

    # a << k or a >> k (left = 0), for 0 <= k < 2^31; floored like Python
    add_func(m, "rt_big_shift", [("a", V), ("k", I32), ("left", I32)], [V], locals = [("na", I32), ("ma", U)], body = [
        set("na", call("rt_int_neg", a)),
        set("ma", call("rt_int_mag", a)),
        if_(get("left"), ret(call("rt_big_make", get("na"), call("rt_mag_shl", get("ma"), get("k"))))),
        if_(eqz(get("na")), ret(call("rt_big_make", i32(0), call("rt_mag_shr", get("ma"), get("k"))))),
        # -((|a| - 1) >> k) - 1
        call("rt_big_make", i32(1), call("rt_mag_add", call("rt_mag_shr", call("rt_mag_sub", get("ma"), arr_fixed("I32A", i32(1))), get("k")),
                                          arr_fixed("I32A", i32(1)))),
    ])

    # a & b (which = 0), a | b (1), a ^ b (2), on two's complement
    add_func(m, "rt_big_bitop", [("a", V), ("b", V), ("which", I32)], [V], locals = PL + [("n", I32), ("ta", U), ("tb", U), ("r", U), ("i", I32), ("x", I32), ("y", I32)], body = [
        parts(),
        set("n", op("i32.add", select_(op("i32.gt_s", arr_len(get("ma")), arr_len(get("mb"))), arr_len(get("ma")), arr_len(get("mb")), I32), i32(1))),
        set("ta", select_(get("na"), call("rt_mag_negate", get("ma"), get("n")), call("rt_mag_pad", get("ma"), get("n")), U)),
        set("tb", select_(get("nb"), call("rt_mag_negate", get("mb"), get("n")), call("rt_mag_pad", get("mb"), get("n")), U)),
        set("r", arr_new_default("I32A", get("n"))),
        for_i32("i", i32(0), get("n"), [
            set("x", _lg(get("ta"), get("i"))),
            set("y", _lg(get("tb"), get("i"))),
            arr_set("I32A", get("r"), get("i"), select_(eqz(get("which")), op("i32.and", get("x"), get("y")),
                select_(op("i32.eq", get("which"), i32(1)), op("i32.or", get("x"), get("y")), op("i32.xor", get("x"), get("y")), I32), I32)),
        ]),
        if_(op("i32.lt_s", _lg(get("r"), op("i32.sub", get("n"), i32(1))), i32(0)),
            ret(call("rt_big_make", i32(1), call("rt_mag_trim", call("rt_mag_negate", get("r"), get("n")), get("n"))))),
        call("rt_big_make", i32(0), call("rt_mag_trim", get("r"), get("n"))),
    ])

    add_func(m, "rt_mag_pad", [("a", U), ("n", I32)], [U], locals = [("r", U)], body = [
        set("r", arr_new_default("I32A", get("n"))),
        arr_copy("I32A", get("r"), i32(0), a, i32(0), arr_len(a)),
        get("r"),
    ])

    add_func(m, "rt_big_hash", [("v", V)], [I32], locals = [("h", I32), ("i", I32), ("mag", U)], body = [
        set("mag", BF("mag", get("v"))),
        set("h", select_(BF("neg", get("v")), i32(0x2f9c1d27), i32(0x51ed270b), I32)),
        for_i32("i", i32(0), arr_len(get("mag")), [
            set("h", op("i32.mul", op("i32.xor", get("h"), _lg(get("mag"), get("i"))), i32(0x01000193))),
        ]),
        _mix32("h"),
        get("h"),
    ])

    # Digits of int v in base 2..16 (a leading "-" if negative).
    add_func(m, "rt_buf_bigradix", [("b", BUF), ("v", V), ("base", I32), ("upper", I32)], [], locals = [
        ("mag", U), ("p", I64), ("k", I32), ("chunks", U), ("nc", I32), ("i", I32),
    ], body = [
        if_(call("rt_int_neg", get("v")), call("rt_buf_byte", get("b"), i32(45))),
        set("mag", call("rt_int_mag", get("v"))),
        # chunk = base**k, the largest power below 2**31
        set("p", op("i64.extend_i32_u", get("base"))),
        set("k", i32(1)),
        while_(op("i64.lt_u", op("i64.mul", get("p"), op("i64.extend_i32_u", get("base"))), i64(1 << 31)), [
            set("p", op("i64.mul", get("p"), op("i64.extend_i32_u", get("base")))),
            inc("k"),
        ], label = "pow"),
        set("chunks", arr_new_default("I32A", op("i32.add", op("i32.mul", arr_len(get("mag")), i32(2)), i32(2)))),
        set("nc", i32(0)),
        while_(op("i32.gt_s", arr_len(get("mag")), i32(0)), [
            set("mag", call("rt_mag_divsmall", get("mag"), get("p"))),
            _ls(get("chunks"), get("nc"), gget("big_rem")),
            inc("nc"),
        ], label = "chunk"),
        if_(eqz(get("nc")), call("rt_buf_byte", get("b"), i32(48))),
        set("i", op("i32.sub", get("nc"), i32(1))),
        while_(op("i32.ge_s", get("i"), i32(0)), [
            call("rt_buf_digits", get("b"), _lg(get("chunks"), get("i")), get("base"), get("upper"),
                 select_(op("i32.eq", get("i"), op("i32.sub", get("nc"), i32(1))), i32(0), get("k"), I32)),
            set("i", op("i32.sub", get("i"), i32(1))),
        ], label = "emit"),
    ])

    # x (0 <= x < 2^31) in base, zero-padded to width digits
    add_func(m, "rt_buf_digits", [("b", BUF), ("x", I32), ("base", I32), ("upper", I32), ("width", I32)], [], locals = [
        ("t", ref("U8")), ("n", I32), ("d", I32),
    ], body = [
        set("t", arr_new_default("U8", i32(32))),
        set("n", i32(0)),
        loop("dig", [
            set("d", op("i32.rem_u", get("x"), get("base"))),
            arr_set("U8", get("t"), get("n"), select_(op("i32.lt_u", get("d"), i32(10)), op("i32.add", get("d"), i32(48)),
                    op("i32.add", get("d"), select_(get("upper"), i32(55), i32(87), I32)), I32)),
            inc("n"),
            set("x", op("i32.div_u", get("x"), get("base"))),
            br_if("dig", or_(op("i32.ne", get("x"), i32(0)), op("i32.lt_s", get("n"), get("width")))),
        ]),
        while_(op("i32.gt_s", get("n"), i32(0)), [
            set("n", op("i32.sub", get("n"), i32(1))),
            call("rt_buf_byte", get("b"), arr_get_u("U8", get("t"), get("n"))),
        ], label = "out"),
    ])

    # float(v) for a $Big: correctly rounded (the top 64 bits with a sticky
    # bit, converted, then scaled by an exact power of two)
    add_func(m, "rt_big_to_f64", [("v", V)], [F64], locals = [("mag", U), ("bits", I32), ("sh", I32), ("top", U), ("u", I64), ("f", F64), ("i", I32)], body = [
        set("mag", BF("mag", get("v"))),
        set("bits", op("i32.sub", op("i32.shl", arr_len(get("mag")), i32(5)),
                       op("i32.clz", _lg(get("mag"), op("i32.sub", arr_len(get("mag")), i32(1)))))),
        set("sh", op("i32.sub", get("bits"), i32(64))),
        if_(op("i32.gt_s", get("sh"), i32(1023)), fail_(m, "int too large to convert to float")),
        set("top", call("rt_mag_shr", get("mag"), get("sh"))),
        set("u", op("i64.or", _lu(get("top"), i32(0)), op("i64.shl", _lu(get("top"), i32(1)), i64(32)))),
        # sticky: any 1 bit shifted out
        if_(op("i32.ne", call("rt_mag_cmp", call("rt_mag_shl", get("top"), get("sh")), get("mag")), i32(0)),
            set("u", op("i64.or", get("u"), i64(1)))),
        set("f", op("f64.mul", op("f64.convert_i64_u", get("u")),
                    op("f64.reinterpret_i64", op("i64.shl", op("i64.extend_i32_u", op("i32.add", get("sh"), i32(1023))), i64(52))))),
        if_(op("f64.eq", op("f64.sub", get("f"), get("f")), op("f64.sub", get("f"), get("f"))), [], fail_(m, "int too large to convert to float")),
        select_(BF("neg", get("v")), op("f64.neg", get("f")), get("f"), F64),
    ])

    # The integer value of float x (finite, |x| >= 2^63) as a $Big
    add_func(m, "rt_big_of_f64", [("x", F64)], [V], locals = [("bits", I64), ("e", I32)], body = [
        set("bits", op("i64.reinterpret_f64", get("x"))),
        set("e", op("i32.sub", op("i32.wrap_i64", op("i64.and", op("i64.shr_u", get("bits"), i64(52)), i64(0x7ff))), i32(1075))),
        call("rt_big_make", op("i32.wrap_i64", op("i64.shr_u", get("bits"), i64(63))),
             call("rt_mag_shl", call("rt_mag_of_u64", op("i64.or", op("i64.and", get("bits"), i64((1 << 52) - 1)), i64(1 << 52))), get("e"))),
    ])

def _floats(m):
    x, y = get("x"), get("y")

    def fc(n):
        return op("f64.convert_i64_s", i64(n))

    TWO63 = op("f64.neg", op("f64.convert_i64_s", i64(MIN_I64)))  # 2**63, exactly

    add_func(m, "rt_float", [("x", F64)], [V], [new("Float", x)])
    add_func(m, "rt_is_num", [("v", V)], [I32], [or_(call("rt_is_int", get("v")), is_("Float", get("v")))])

    # The value of a number as an f64 (ints are rounded to nearest).
    add_func(m, "rt_f64", [("v", V)], [F64], [
        if_(is_("Float", get("v")), ret(field("Float", "v", as_("Float", get("v"))))),
        if_(is_("Big", get("v")), ret(call("rt_big_to_f64", get("v")))),
        op("f64.convert_i64_s", call("rt_i64", get("v"))),
    ])

    # Exact three-way comparison of an int and a (non-NaN) float.
    add_func(m, "rt_cmp_if", [("i", I64), ("f", F64)], [I32], locals = [("t", F64), ("ti", I64)], body = [
        if_(op("f64.ge", get("f"), TWO63), ret(i32(-1))),
        if_(op("f64.lt", get("f"), op("f64.neg", TWO63)), ret(i32(1))),
        set("t", op("f64.trunc", get("f"))),
        set("ti", op("i64.trunc_f64_s", get("t"))),
        if_(op("i64.lt_s", get("i"), get("ti")), ret(i32(-1))),
        if_(op("i64.gt_s", get("i"), get("ti")), ret(i32(1))),
        if_(op("f64.gt", get("f"), get("t")), ret(i32(-1))),
        if_(op("f64.lt", get("f"), get("t")), ret(i32(1))),
        i32(0),
    ])

    # Exact three-way comparison of int v and a non-NaN float.
    add_func(m, "rt_cmp_vf", [("v", V), ("f", F64)], [I32], locals = [("t", F64), ("c", I32)], body = [
        if_(eqz(is_("Big", get("v"))), ret(call("rt_cmp_if", call("rt_i64", get("v")), get("f")))),
        if_(op("f64.ne", op("f64.sub", get("f"), get("f")), fc(0)), ret(select_(op("f64.gt", get("f"), fc(0)), i32(-1), i32(1), I32))),
        set("t", op("f64.trunc", get("f"))),
        # |v| >= 2^63 > |t|: the sign decides
        if_(op("f64.lt", op("f64.abs", get("t")), TWO63), ret(select_(field("Big", "neg", as_("Big", get("v"))), i32(-1), i32(1), I32))),
        call("rt_big_cmp", get("v"), call("rt_big_of_f64", get("t"))),  # t == f: no fraction
    ])

    # starlark-go's total order on floats: NaN is above +inf and equal to itself.
    add_func(m, "rt_cmp_ff", [("x", F64), ("y", F64)], [I32], [
        if_(op("f64.gt", x, y), ret(i32(1))),
        if_(op("f64.lt", x, y), ret(i32(-1))),
        if_(op("f64.eq", x, y), ret(i32(0))),
        if_(op("f64.eq", x, x), ret(i32(-1))),  # y is NaN
        if_(op("f64.eq", y, y), ret(i32(1))),  # x is NaN
        i32(0),
    ])

    # Three-way comparison of numbers a and b, at least one a float.
    add_func(m, "rt_num_cmp", [("a", V), ("b", V)], [I32], locals = [("x", F64), ("y", F64)], body = [
        if_(and_(is_("Float", get("a")), is_("Float", get("b"))), ret(call("rt_cmp_ff", call("rt_f64", get("a")), call("rt_f64", get("b"))))),
        if_(is_("Float", get("b")), [
            set("y", call("rt_f64", get("b"))),
            if_(op("f64.ne", y, y), ret(i32(-1))),
            ret(call("rt_cmp_vf", get("a"), y)),
        ]),
        set("x", call("rt_f64", get("a"))),
        if_(op("f64.ne", x, x), ret(i32(1))),
        op("i32.sub", i32(0), call("rt_cmp_vf", get("b"), x)),
    ])

    # Equal ints and floats hash alike: a finite float hashes as its integer
    # part (as starlark-go does); NaN and infinities share one hash.
    add_func(m, "rt_float_hash", [("x", F64)], [I32], locals = [("t", F64), ("h", I32), ("bits", I64)], body = [
        if_(op("f64.ne", op("f64.sub", x, x), fc(0)), ret(i32(1618033))),
        set("t", op("f64.trunc", x)),
        if_(op("f64.lt", op("f64.abs", get("t")), TWO63), ret(call("rt_hash", call("rt_int", op("i64.trunc_f64_s", get("t")))))),
        call("rt_hash", call("rt_big_of_f64", get("t"))),
    ])

    # Float to int, truncating; pre: the error message's start
    # ("int: " -> "int: cannot convert float NaN to integer").
    add_func(m, "rt_float_to_int", [("x", F64), ("pre", STR)], [V], locals = [("b", BUF)], body = [
        if_(op("f64.ne", op("f64.sub", x, x), fc(0)), [
            set("b", call("rt_buf_new")),
            call("rt_buf_str", get("b"), get("pre")),
            call("rt_buf_str", get("b"), select_(op("f64.ne", x, x),
                 S(m, "cannot convert float NaN to integer"), S(m, "cannot convert float infinity to integer"), STR)),
            call("rt_fail", call("rt_buf_to_str", get("b"))),
        ]),
        if_(op("f64.ge", op("f64.abs", op("f64.trunc", x)), TWO63), ret(call("rt_big_of_f64", op("f64.trunc", x)))),
        call("rt_int", op("i64.trunc_f64_s", x)),
    ])

    # Append x formatted with conv ('g' 'G' 'e' 'E' 'f'), as starlark-go.
    add_func(m, "rt_buf_float", [("b", BUF), ("x", F64), ("conv", I32)], [], locals = [("n", I32)], body = [
        set("n", call("host_float_fmt", x, get("conv"))),
        call("rt_buf_bytes", get("b"), call("rt_mem_take", get("n")), i32(0), get("n")),
    ])

    # float(s) for a string s.
    add_func(m, "rt_parse_float", [("s", STR)], [V], locals = [("n", I32), ("r", I32)], body = [
        set("n", arr_len(field("Str", "b", get("s")))),
        if_(eqz(get("n")), fail_(m, "float: empty string")),
        if_(op("i32.gt_s", get("n"), i32(65536)), set("r", i32(1)), [
            call("rt_mem_put", field("Str", "b", get("s")), i32(0), get("n")),
            set("r", call("host_float_parse", i32(0), get("n"))),
        ]),
        if_(op("i32.eq", get("r"), i32(1)), call("rt_fail", call("rt_str_concat", S(m, "invalid float literal: "), get("s")))),
        if_(op("i32.eq", get("r"), i32(2)), fail_(m, "floating-point number too large")),
        call("rt_float", [i32(0), ("f64.load", 0)]),
    ])

    def binop(name, sym, code, zero_msg = None):
        body = [
            if_(eqz(and_(call("rt_is_num", get("a")), call("rt_is_num", get("b")))),
                type_err2(m, "unknown binary op: ", get("a"), " " + sym + " ", get("b"), "")),
            set("x", call("rt_f64", get("a"))),
            set("y", call("rt_f64", get("b"))),
        ]
        if zero_msg != None:
            body.append(if_(op("f64.eq", y, fc(0)), fail_(m, zero_msg)))
        body.append(call("rt_float", code))
        add_func(m, name, [("a", V), ("b", V)], [V], body, locals = [("x", F64), ("y", F64), ("z", F64)])

    # Float arithmetic, after the int fast paths (rt_add etc. dispatch here
    # when an operand is a float; rt_div is the / operator for all numbers).
    binop("rt_fadd", "+", op("f64.add", x, y))
    binop("rt_fsub", "-", op("f64.sub", x, y))
    binop("rt_fmul", "*", op("f64.mul", x, y))
    binop("rt_div", "/", op("f64.div", x, y), "floating-point division by zero")
    binop("rt_ffloordiv", "//", op("f64.floor", op("f64.div", x, y)), "floored division by zero")
    # Go's x.Mod(y): fmod, then the sign of y
    binop("rt_fmod", "%", [
        set("z", call("host_float_mod", x, y)),
        if_(and_(op("i32.ne", op("f64.lt", x, fc(0)), op("f64.lt", y, fc(0))), op("f64.ne", get("z"), fc(0))),
            set("z", op("f64.add", get("z"), y))),
        get("z"),
    ], "floating-point modulo by zero")

def _strings(m):
    # Spelling hints, as starlark-go's internal/spell: the candidate in
    # cands[lo:hi] (strings) nearest to x, ignoring case and underscores,
    # with at most 50% typos; or None. (compiler/spell.star is the same in
    # Starlark, for compile-time errors.)
    add_func(m, "rt_fold", [("s", U8A)], [U8A], locals = [("n", I32), ("k", I32), ("i", I32), ("c", I32), ("o", U8A)], body = [
        set("n", arr_len(get("s"))),
        set("k", i32(0)),
        for_i32("i", i32(0), get("n"), if_(op("i32.ne", arr_get_u("U8", get("s"), get("i")), i32(95)), inc("k"))),
        set("o", arr_new_default("U8", get("k"))),
        set("k", i32(0)),
        for_i32("i", i32(0), get("n"), [
            set("c", arr_get_u("U8", get("s"), get("i"))),
            if_(op("i32.ne", get("c"), i32(95)), [
                if_(and_(op("i32.ge_u", get("c"), i32(65)), op("i32.le_u", get("c"), i32(90))), set("c", op("i32.add", get("c"), i32(32)))),
                arr_set("U8", get("o"), get("k"), get("c")),
                inc("k"),
            ]),
        ]),
        get("o"),
    ])

    # Levenshtein distance of x and y, or some value > max once it exceeds max.
    add_func(m, "rt_levenshtein", [("x", U8A), ("y", U8A), ("max", I32)], [I32], locals = [
        ("t", U8A), ("xo", I32), ("lx", I32), ("ly", I32), ("i", I32), ("j", I32),
        ("row", I32A), ("best", I32), ("prev", I32), ("a", I32), ("b", I32), ("c", I32), ("k", I32), ("d", I32),
    ], body = [
        if_(op("i32.gt_s", arr_len(get("x")), arr_len(get("y"))), [set("t", get("x")), set("x", get("y")), set("y", get("t"))]),
        # drop the common prefix (only up to the first difference, as Go)
        set("xo", i32(0)),
        for_i32("i", i32(0), arr_len(get("x")), [
            if_(op("i32.ne", arr_get_u("U8", get("x"), get("i")), arr_get_u("U8", get("y"), get("i"))), [set("xo", get("i")), br("diff_break")]),
        ], label = "diff"),
        set("lx", op("i32.sub", arr_len(get("x")), get("xo"))),
        set("ly", op("i32.sub", arr_len(get("y")), get("xo"))),
        if_(eqz(get("lx")), ret(get("ly"))),
        set("d", op("i32.sub", get("ly"), get("lx"))),
        if_(op("i32.gt_s", get("d"), get("max")), ret(get("d"))),
        set("row", arr_new_default("I32A", op("i32.add", get("ly"), i32(1)))),
        for_i32("j", i32(0), op("i32.add", get("ly"), i32(1)), arr_set("I32A", get("row"), get("j"), get("j"))),
        for_i32("i", i32(1), op("i32.add", get("lx"), i32(1)), [
            arr_set("I32A", get("row"), i32(0), get("i")),
            set("best", get("i")),
            set("prev", op("i32.sub", get("i"), i32(1))),
            for_i32("j", i32(1), op("i32.add", get("ly"), i32(1)), [
                set("a", op("i32.add", get("prev"), op("i32.ne",
                    arr_get_u("U8", get("x"), op("i32.add", get("xo"), op("i32.sub", get("i"), i32(1)))),
                    arr_get_u("U8", get("y"), op("i32.add", get("xo"), op("i32.sub", get("j"), i32(1))))))),
                set("b", op("i32.add", i32(1), arr_get("I32A", get("row"), op("i32.sub", get("j"), i32(1))))),
                set("c", op("i32.add", i32(1), arr_get("I32A", get("row"), get("j")))),
                set("k", select_(op("i32.lt_s", get("a"), get("b")), get("a"), get("b"), I32)),
                set("k", select_(op("i32.lt_s", get("k"), get("c")), get("k"), get("c"), I32)),
                set("prev", arr_get("I32A", get("row"), get("j"))),
                arr_set("I32A", get("row"), get("j"), get("k")),
                if_(op("i32.lt_s", get("k"), get("best")), set("best", get("k"))),
            ]),
            if_(op("i32.gt_s", get("best"), get("max")), ret(get("best"))),
        ]),
        arr_get("I32A", get("row"), get("ly")),
    ])

    add_func(m, "rt_nearest", [("x", STR), ("cands", VALS), ("lo", I32), ("hi", I32)], [V], locals = [
        ("fx", U8A), ("bestd", I32), ("best", V), ("i", I32), ("c", V), ("d", I32),
    ], body = [
        set("fx", call("rt_fold", field("Str", "b", get("x")))),
        set("bestd", op("i32.div_s", op("i32.add", arr_len(get("fx")), i32(1)), i32(2))),
        set("best", gget("None")),
        for_i32("i", get("lo"), get("hi"), [
            set("c", arr_get("Vals", get("cands"), get("i"))),
            if_(is_("Str", get("c")), [
                set("d", call("rt_levenshtein", get("fx"), call("rt_fold", field("Str", "b", as_("Str", get("c")))), get("bestd"))),
                if_(op("i32.lt_s", get("d"), get("bestd")), [set("bestd", get("d")), set("best", get("c"))]),
            ]),
        ]),
        get("best"),
    ])

    add_func(m, "rt_str_from_data", [("off", I32), ("n", I32)], [STR], [
        new("Str", i32(0), [get("off"), get("n"), ("array.new_data", "U8", "strings")]),
    ])

    add_func(m, "rt_str_concat", [("a", STR), ("b", STR)], [STR], locals = [
        ("na", U8A),
        ("la", I32),
        ("lb", I32),
    ], body = [
        set("la", arr_len(field("Str", "b", get("a")))),
        set("lb", arr_len(field("Str", "b", get("b")))),
        set("na", arr_new_default("U8", op("i32.add", get("la"), get("lb")))),
        arr_copy("U8", get("na"), i32(0), field("Str", "b", get("a")), i32(0), get("la")),
        arr_copy("U8", get("na"), get("la"), field("Str", "b", get("b")), i32(0), get("lb")),
        new("Str", i32(0), get("na")),
    ])

    add_func(m, "rt_str_eq", [("a", STR), ("b", STR)], [I32], locals = [
        ("x", U8A),
        ("y", U8A),
        ("n", I32),
        ("i", I32),
    ], body = [
        if_(ref_eq(get("a"), get("b")), ret(i32(1))),
        set("x", field("Str", "b", get("a"))),
        set("y", field("Str", "b", get("b"))),
        set("n", arr_len(get("x"))),
        if_(op("i32.ne", get("n"), arr_len(get("y"))), ret(i32(0))),
        for_i32("i", i32(0), get("n"), [
            if_(op("i32.ne", arr_get_u("U8", get("x"), get("i")), arr_get_u("U8", get("y"), get("i"))), ret(i32(0))),
        ]),
        i32(1),
    ])

    # a < b, comparing bytes as unsigned (same order as UTF-8 code points).
    add_func(m, "rt_str_lt", [("a", STR), ("b", STR)], [I32], locals = [
        ("x", U8A),
        ("y", U8A),
        ("n", I32),
        ("i", I32),
        ("c", I32),
        ("d", I32),
    ], body = [
        set("x", field("Str", "b", get("a"))),
        set("y", field("Str", "b", get("b"))),
        set("n", arr_len(get("x"))),
        if_(op("i32.lt_s", arr_len(get("y")), get("n")), set("n", arr_len(get("y")))),
        for_i32("i", i32(0), get("n"), [
            set("c", arr_get_u("U8", get("x"), get("i"))),
            set("d", arr_get_u("U8", get("y"), get("i"))),
            if_(op("i32.ne", get("c"), get("d")), ret(op("i32.lt_u", get("c"), get("d")))),
        ]),
        op("i32.lt_s", arr_len(get("x")), arr_len(get("y"))),
    ])

    # FNV-1a, cached in the string. 0 means "not computed", so remap it.
    add_func(m, "rt_str_hash", [("s", STR)], [I32], locals = [
        ("h", I32),
        ("a", U8A),
        ("i", I32),
    ], body = [
        set("h", field("Str", "hash", get("s"))),
        if_(op("i32.ne", get("h"), i32(0)), ret(get("h"))),
        set("h", i32(0x811c9dc5)),
        set("a", field("Str", "b", get("s"))),
        for_i32("i", i32(0), arr_len(get("a")), [
            set("h", op("i32.mul", op("i32.xor", get("h"), arr_get_u("U8", get("a"), get("i"))), i32(0x01000193))),
        ]),
        if_(eqz(get("h")), set("h", i32(1))),
        setfield("Str", "hash", get("s"), get("h")),
        get("h"),
    ])

    # The count for repeating a sequence of len > 0 elements count times, as
    # starlark-go's tupleRepeat/stringRepeat: an int32 ("repeat count N too
    # large"), at most 0 meaning none, with len * count < 2^30 ("excessive
    # repeat (len * count elements)"); `limit` is starwasm's own cap.
    add_func(m, "rt_repeat_count", [("count", V), ("len", I32), ("limit", I64)], [I32], locals = [("n", I64), ("b", BUF)], body = [
        if_(eqz(call("rt_is_small", get("count"))), [
            call("rt_fail", call("rt_str_concat", call("rt_str_concat", S(m, "repeat count "), call("rt_str", get("count"))), S(m, " too large"))),
        ]),
        set("n", call("rt_i64", get("count"))),
        if_(op("i64.ne", op("i64.extend_i32_s", op("i32.wrap_i64", get("n"))), get("n")), [
            call("rt_fail", call("rt_str_concat", call("rt_str_concat", S(m, "repeat count "), call("rt_str", get("count"))), S(m, " too large"))),
        ]),
        if_(op("i64.le_s", get("n"), i64(0)), ret(i32(0))),
        if_(op("i64.ge_s", op("i64.mul", get("n"), op("i64.extend_i32_u", get("len"))), i64(1 << 30)), [
            set("b", call("rt_buf_new")),
            call("rt_buf_str", get("b"), S(m, "excessive repeat (")),
            call("rt_buf_i64", get("b"), op("i64.extend_i32_u", get("len"))),
            call("rt_buf_str", get("b"), S(m, " * ")),
            call("rt_buf_i64", get("b"), get("n")),
            call("rt_buf_str", get("b"), S(m, " elements)")),
            call("rt_fail", call("rt_buf_to_str", get("b"))),
        ]),
        if_(op("i64.gt_s", op("i64.mul", get("n"), op("i64.extend_i32_u", get("len"))), get("limit")),
            fail_(m, "repetition result too large")),
        op("i32.wrap_i64", get("n")),
    ])

    add_func(m, "rt_str_repeat", [("s", STR), ("count", V)], [STR], locals = [
        ("len", I32),
        ("n", I32),
        ("i", I32),
        ("na", U8A),
    ], body = [
        set("len", arr_len(field("Str", "b", get("s")))),
        if_(eqz(get("len")), ret(get("s"))),
        set("n", call("rt_repeat_count", get("count"), get("len"), i64(1 << 30))),
        if_(eqz(get("n")), ret(new("Str", i32(0), arr_new_default("U8", i32(0))))),
        set("na", arr_new_default("U8", op("i32.mul", get("n"), get("len")))),
        for_i32("i", i32(0), get("n"), [
            arr_copy("U8", get("na"), op("i32.mul", get("i"), get("len")), field("Str", "b", get("s")), i32(0), get("len")),
        ]),
        new("Str", i32(0), get("na")),
    ])

    add_func(m, "rt_str_contains", [("hay", STR), ("needle", STR)], [I32], locals = [
        ("h", U8A),
        ("nd", U8A),
        ("i", I32),
        ("j", I32),
        ("last", I32),
        ("nl", I32),
    ], body = [
        set("h", field("Str", "b", get("hay"))),
        set("nd", field("Str", "b", get("needle"))),
        set("nl", arr_len(get("nd"))),
        set("last", op("i32.sub", arr_len(get("h")), get("nl"))),
        set("i", i32(0)),
        while_(op("i32.le_s", get("i"), get("last")), [
            set("j", i32(0)),
            while_(and_(op("i32.lt_s", get("j"), get("nl")),
                        op("i32.eq", arr_get_u("U8", get("h"), op("i32.add", get("i"), get("j"))),
                           arr_get_u("U8", get("nd"), get("j")))),
                   inc("j"), label = "match"),
            if_(op("i32.eq", get("j"), get("nl")), ret(i32(1))),
            inc("i"),
        ]),
        i32(0),
    ])

    # Length (1..4) of the valid UTF-8 sequence starting at a[i] (a[:n]), or
    # 0 if the bytes there are not valid UTF-8 (as Go's utf8.DecodeRune
    # decides: no overlong forms, surrogates or values above U+10FFFF).
    add_func(m, "rt_utf8_seq", [("a", U8A), ("i", I32), ("n", I32)], [I32], locals = [
        ("c", I32),
        ("need", I32),
        ("lo", I32),
        ("hi", I32),
        ("k", I32),
        ("d", I32),
    ], body = [
        set("c", arr_get_u("U8", get("a"), get("i"))),
        if_(op("i32.lt_u", get("c"), i32(0x80)), ret(i32(1))),
        if_(op("i32.lt_u", get("c"), i32(0xc2)), ret(i32(0))),
        set("lo", i32(0x80)),
        set("hi", i32(0xbf)),
        if_(op("i32.lt_u", get("c"), i32(0xe0)), set("need", i32(2)),
        if_(op("i32.lt_u", get("c"), i32(0xf0)), [
            set("need", i32(3)),
            if_(op("i32.eq", get("c"), i32(0xe0)), set("lo", i32(0xa0))),
            if_(op("i32.eq", get("c"), i32(0xed)), set("hi", i32(0x9f))),
        ], if_(op("i32.lt_u", get("c"), i32(0xf5)), [
            set("need", i32(4)),
            if_(op("i32.eq", get("c"), i32(0xf0)), set("lo", i32(0x90))),
            if_(op("i32.eq", get("c"), i32(0xf4)), set("hi", i32(0x8f))),
        ], ret(i32(0))))),
        if_(op("i32.gt_s", op("i32.add", get("i"), get("need")), get("n")), ret(i32(0))),
        for_i32("k", i32(1), get("need"), [
            set("d", arr_get_u("U8", get("a"), op("i32.add", get("i"), get("k")))),
            if_(or_(op("i32.lt_u", get("d"), get("lo")), op("i32.gt_u", get("d"), get("hi"))), ret(i32(0))),
            set("lo", i32(0x80)),
            set("hi", i32(0xbf)),
        ]),
        get("need"),
    ])

    # Quoted form of the bytes a, as in starlark-go: "..." for strings and
    # b"..." (bytes=1) for bytes. Valid UTF-8 is kept; other bytes and ASCII
    # control characters are escaped.
    add_func(m, "rt_buf_repr_u8", [("b", BUF), ("a", U8A), ("bytes", I32)], [], locals = [
        ("i", I32),
        ("c", I32),
        ("k", I32),
        ("n", I32),
    ], body = [
        if_(get("bytes"), call("rt_buf_byte", get("b"), i32(98))),  # b
        call("rt_buf_byte", get("b"), i32(34)),  # "
        set("n", arr_len(get("a"))),
        set("i", i32(0)),
        while_(op("i32.lt_s", get("i"), get("n")), [
            set("c", arr_get_u("U8", get("a"), get("i"))),
            if_(op("i32.ge_u", get("c"), i32(0x80)), [
                set("k", call("rt_utf8_seq", get("a"), get("i"), get("n"))),
                if_(get("k"), [
                    # valid UTF-8: kept if printable (strconv.IsPrint), else
                    # \uXXXX / \UXXXXXXXX, as Go's strconv.Quote
                    set("c", call("rt_utf8_rune", get("a"), get("i"), get("k"))),
                    if_(call("rt_uni_isprint", get("c")), call("rt_buf_bytes", get("b"), get("a"), get("i"), get("k")), [
                        call("rt_buf_str", get("b"), select_(op("i32.lt_u", get("c"), i32(0x10000)), S(m, "\\u"), S(m, "\\U"), STR)),
                        call("rt_buf_digits", get("b"), get("c"), i32(16), i32(0), select_(op("i32.lt_u", get("c"), i32(0x10000)), i32(4), i32(8), I32)),
                    ]),
                    set("i", op("i32.add", get("i"), get("k"))),
                    br("loop"),
                ]),
            ]),
            inc("i"),
            if_(op("i32.eq", get("c"), i32(92)), call("rt_buf_str", get("b"), S(m, "\\\\")),
            if_(op("i32.eq", get("c"), i32(34)), call("rt_buf_str", get("b"), S(m, "\\\"")),
            if_(op("i32.eq", get("c"), i32(10)), call("rt_buf_str", get("b"), S(m, "\\n")),
            if_(op("i32.eq", get("c"), i32(9)), call("rt_buf_str", get("b"), S(m, "\\t")),
            if_(op("i32.eq", get("c"), i32(13)), call("rt_buf_str", get("b"), S(m, "\\r")),
            if_(op("i32.eq", get("c"), i32(7)), call("rt_buf_str", get("b"), S(m, "\\a")),
            if_(op("i32.eq", get("c"), i32(8)), call("rt_buf_str", get("b"), S(m, "\\b")),
            if_(op("i32.eq", get("c"), i32(11)), call("rt_buf_str", get("b"), S(m, "\\v")),
            if_(op("i32.eq", get("c"), i32(12)), call("rt_buf_str", get("b"), S(m, "\\f")),
            if_(or_(op("i32.lt_u", get("c"), i32(32)), op("i32.ge_u", get("c"), i32(127))), [
                call("rt_buf_str", get("b"), S(m, "\\x")),
                call("rt_buf_byte", get("b"), call("rt_hexdigit", op("i32.shr_u", get("c"), i32(4)))),
                call("rt_buf_byte", get("b"), call("rt_hexdigit", op("i32.and", get("c"), i32(15)))),
            ], call("rt_buf_byte", get("b"), get("c")))))))))))),
        ]),
        call("rt_buf_byte", get("b"), i32(34)),
    ])

    add_func(m, "rt_buf_repr_str", [("b", BUF), ("s", STR)], [], [
        call("rt_buf_repr_u8", get("b"), field("Str", "b", get("s")), i32(0)),
    ])

    # str(bytes): the bytes as UTF-8, each invalid byte replaced by U+FFFD.
    add_func(m, "rt_bytes_str", [("a", U8A)], [STR], locals = [("b", BUF), ("i", I32), ("k", I32), ("n", I32)], body = [
        set("b", call("rt_buf_new")),
        set("n", arr_len(get("a"))),
        set("i", i32(0)),
        while_(op("i32.lt_s", get("i"), get("n")), [
            set("k", call("rt_utf8_seq", get("a"), get("i"), get("n"))),
            if_(get("k"), [
                call("rt_buf_bytes", get("b"), get("a"), get("i"), get("k")),
                set("i", op("i32.add", get("i"), get("k"))),
            ], [
                call("rt_buf_byte", get("b"), i32(0xef)),
                call("rt_buf_byte", get("b"), i32(0xbf)),
                call("rt_buf_byte", get("b"), i32(0xbd)),
                inc("i"),
            ]),
        ]),
        call("rt_buf_to_str", get("b")),
    ])

    add_func(m, "rt_hexdigit", [("d", I32)], [I32], [
        select_(op("i32.lt_u", get("d"), i32(10)),
                op("i32.add", get("d"), i32(48)),
                op("i32.add", get("d"), i32(87)), I32),
    ])

# ---------------------------------------------------------------- equality, ordering, hashing

def _compare(m):
    a, b = get("a"), get("b")

    # Comparisons recurse into lists, tuples, dicts and structs at most 10
    # levels deep (starlark-go's CompareLimit), which also stops cycles:
    # "comparison exceeded maximum recursion depth". d is the depth left.
    D = get("d")

    def dm1():
        return op("i32.sub", D, i32(1))

    seqP = [("x", VALS), ("xn", I32), ("y", VALS), ("yn", I32), ("d", I32)]
    add_func(m, "rt_seq_eq", seqP, [I32], locals = [("i", I32)], body = [
        if_(op("i32.ne", get("xn"), get("yn")), ret(i32(0))),
        for_i32("i", i32(0), get("xn"), [
            if_(eqz(call("rt_eq_d", arr_get("Vals", get("x"), get("i")), arr_get("Vals", get("y"), get("i")), dm1())),
                ret(i32(0))),
        ]),
        i32(1),
    ])

    add_func(m, "rt_seq_lt", seqP, [I32], locals = [("i", I32), ("p", V), ("q", V)], body = [
        set("i", i32(0)),
        while_(and_(op("i32.lt_s", get("i"), get("xn")), op("i32.lt_s", get("i"), get("yn"))), [
            set("p", arr_get("Vals", get("x"), get("i"))),
            set("q", arr_get("Vals", get("y"), get("i"))),
            if_(eqz(call("rt_eq_d", get("p"), get("q"), dm1())), ret(call("rt_lt_d", get("p"), get("q"), dm1()))),
            inc("i"),
        ]),
        op("i32.lt_s", get("xn"), get("yn")),
    ])

    too_deep = if_(op("i32.lt_s", D, i32(1)), fail_(m, "comparison exceeded maximum recursion depth"))
    add_func(m, "rt_eq", [("a", V), ("b", V)], [I32], [call("rt_eq_d", a, b, i32(10))])
    add_func(m, "rt_lt", [("a", V), ("b", V)], [I32], [call("rt_lt_d", a, b, i32(10))])

    def mixed_num(a, b):
        # i32: both numbers, at least one a float
        return and_(and_(call("rt_is_num", a), call("rt_is_num", b)), or_(is_("Float", a), is_("Float", b)))

    add_func(m, "rt_eq_d", [("a", V), ("b", V), ("d", I32)], [I32], [
        too_deep,
        if_(eqz(or_(or_(is_("List", a), is_("Tuple", a)), or_(is_("Dict", a), is_("Struct", a)))),
            if_(ref_eq(a, b), ret(i32(1)))),  # containers: no identity shortcut (as starlark-go)
        if_(mixed_num(a, b), ret(eqz(call("rt_num_cmp", a, b)))),
        if_(both("Int", a, b), ret(op("i64.eq", field("Int", "v", as_("Int", a)), field("Int", "v", as_("Int", b))))),
        if_(both("Big", a, b), ret(eqz(call("rt_big_cmp", a, b)))),
        if_(both("Str", a, b), ret(call("rt_str_eq", as_("Str", a), as_("Str", b)))),
        if_(both("List", a, b), ret(call(
            "rt_seq_eq",
            field("List", "items", as_("List", a)),
            field("List", "len", as_("List", a)),
            field("List", "items", as_("List", b)),
            field("List", "len", as_("List", b)),
            D,
        ))),
        if_(both("Tuple", a, b), ret(call(
            "rt_seq_eq",
            field("Tuple", "items", as_("Tuple", a)),
            arr_len(field("Tuple", "items", as_("Tuple", a))),
            field("Tuple", "items", as_("Tuple", b)),
            arr_len(field("Tuple", "items", as_("Tuple", b))),
            D,
        ))),
        if_(both("Dict", a, b), ret(call("rt_dict_eq", as_("Dict", a), as_("Dict", b), D))),
        if_(both("Set", a, b), ret(call("rt_dict_eq", field("Set", "d", as_("Set", a)), field("Set", "d", as_("Set", b)), D))),
        if_(both("Bytes", a, b), ret(call("rt_str_eq", bstr(a), bstr(b)))),
        if_(both("Struct", a, b), ret(call("rt_dict_eq", field("Struct", "d", as_("Struct", a)), field("Struct", "d", as_("Struct", b)), D))),
        if_(both("Range", a, b), ret(call("rt_range_eq", as_("Range", a), as_("Range", b)))),
        if_(both("Lazy", a, b), ret(and_(
            op("i32.eq", field("Lazy", "kind", as_("Lazy", a)), field("Lazy", "kind", as_("Lazy", b))),
            call("rt_str_eq", field("Lazy", "s", as_("Lazy", a)), field("Lazy", "s", as_("Lazy", b))),
        ))),
        i32(0),
    ])

    add_func(m, "rt_lt_d", [("a", V), ("b", V), ("d", I32)], [I32], [
        too_deep,
        if_(mixed_num(a, b), ret(op("i32.lt_s", call("rt_num_cmp", a, b), i32(0)))),
        if_(and_(call("rt_is_int", a), call("rt_is_int", b)),
            ret(op("i32.lt_s", call("rt_big_cmp", a, b), i32(0)))),
        if_(both("Str", a, b), ret(call("rt_str_lt", as_("Str", a), as_("Str", b)))),
        if_(both("Bytes", a, b), ret(call("rt_str_lt", bstr(a), bstr(b)))),
        if_(both("Bool", a, b), ret(and_(ref_eq(a, gget("False")), ref_eq(b, gget("True"))))),
        if_(both("List", a, b), ret(call(
            "rt_seq_lt",
            field("List", "items", as_("List", a)),
            field("List", "len", as_("List", a)),
            field("List", "items", as_("List", b)),
            field("List", "len", as_("List", b)),
            D,
        ))),
        if_(both("Tuple", a, b), ret(call(
            "rt_seq_lt",
            field("Tuple", "items", as_("Tuple", a)),
            arr_len(field("Tuple", "items", as_("Tuple", a))),
            field("Tuple", "items", as_("Tuple", b)),
            arr_len(field("Tuple", "items", as_("Tuple", b))),
            D,
        ))),
        # sets: proper subset
        if_(both("Set", a, b), ret(and_(
            call("rt_set_subset", as_("Set", a), as_("Set", b)),
            op("i32.lt_s", field("Dict", "len", field("Set", "d", as_("Set", a))), field("Dict", "len", field("Set", "d", as_("Set", b)))),
        ))),
        type_err2(m, "", a, " < ", b, " not implemented"),
    ])

    add_func(m, "rt_hash", [("v", V)], [I32], locals = [
        ("h", I32),
        ("x", I64),
        ("items", VALS),
        ("i", I32),
        ("d", ref("Dict", True)),
    ], body = [
        if_(is_("i31", get("v")), [
            set("h", op("i31.get_s", as_("i31", get("v")))),
            _mix32("h"),
            ret(get("h")),
        ]),
        if_(is_("Int", get("v")), [
            set("x", field("Int", "v", as_("Int", get("v")))),
            set("h", op("i32.xor", op("i32.wrap_i64", get("x")), op("i32.wrap_i64", op("i64.shr_u", get("x"), i64(32))))),
            _mix32("h"),
            ret(get("h")),
        ]),
        if_(is_("Big", get("v")), ret(call("rt_big_hash", get("v")))),
        if_(is_("Str", get("v")), ret(call("rt_str_hash", as_("Str", get("v"))))),
        if_(is_("NoneType", get("v")), ret(i32(0x2545f491))),
        if_(is_("Bool", get("v")), ret(op("i32.add", field("Bool", "v", as_("Bool", get("v"))), i32(0x6b43a9b5)))),
        if_(is_("Func", get("v")), [
            set("h", field("Func", "id", as_("Func", get("v")))),
            _mix32("h"),
            ret(get("h")),
        ]),
        if_(is_("Bytes", get("v")), ret(call("rt_str_hash", bstr(get("v"))))),
        if_(is_("Float", get("v")), ret(call("rt_float_hash", field("Float", "v", as_("Float", get("v")))))),
        if_(or_(is_("Range", get("v")), is_("Lazy", get("v"))), type_err1(m, "unhashable: ", get("v"), "")),
        if_(is_("Bound", get("v")), ret(op("i32.xor", call("rt_str_hash", field("Bound", "name", as_("Bound", get("v")))), i32(5521)))),
        if_(is_("Struct", get("v")), [
            set("d", field("Struct", "d", as_("Struct", get("v")))),
            set("h", i32(0x1d4c6f)),
            for_i32("i", i32(0), field("Dict", "used", get("d")), [
                if_(eqz(is_null(arr_get("Vals", field("Dict", "keys", get("d")), get("i")))), [
                    set("h", op("i32.mul", op("i32.xor", get("h"), call("rt_hash", arr_get("Vals", field("Dict", "keys", get("d")), get("i")))), i32(1000003))),
                    set("h", op("i32.mul", op("i32.xor", get("h"), call("rt_hash", arr_get("Vals", field("Dict", "vals", get("d")), get("i")))), i32(1000003))),
                ]),
            ]),
            ret(get("h")),
        ]),
        if_(is_("Tuple", get("v")), [
            set("items", field("Tuple", "items", as_("Tuple", get("v")))),
            set("h", i32(0x345678)),
            for_i32("i", i32(0), arr_len(get("items")), [
                set("h", op("i32.mul", op("i32.xor", get("h"), call("rt_hash", arr_get("Vals", get("items"), get("i")))), i32(1000003))),
            ]),
            ret(get("h")),
        ]),
        type_err1(m, "unhashable type: ", get("v"), ""),
    ])

# ---------------------------------------------------------------- dicts

def _dicts(m):
    d = get("d")

    def F(f):
        return field("Dict", f, d)

    add_func(m, "rt_dict_new", [], [DICT], [
        new(
            "Dict",
            i32(0),
            i32(0),
            arr_new_default("Vals", i32(4)),
            arr_new_default("Vals", i32(4)),
            arr_new_default("I32A", i32(4)),
            arr_new("I32A", i32(-1), i32(8)),
            i32(0),  # not frozen
        ),
    ])

    # d[k] = v for a dict literal: a key may not repeat ("duplicate key: k")
    add_func(m, "rt_dict_set_uniq", [("d", DICT), ("k", V), ("v", V)], [], locals = [("n", I32)], body = [
        set("n", F("len")),
        call("rt_dict_set", d, get("k"), get("v")),
        if_(op("i32.eq", F("len"), get("n")), call("rt_fail", call("rt_str_concat", S(m, "duplicate key: "), call("rt_repr", get("k"))))),
    ])

    # a | b for dicts: a fresh dict with a's entries, then b's (as
    # starlark-go's Dict.Union).
    add_func(m, "rt_dict_union", [("a", DICT), ("b", DICT)], [V], locals = [("r", DICT), ("x", DICT), ("i", I32), ("k", V)], body = [
        set("r", call("rt_dict_new")),
        set("x", get("a")),
        loop("union", [
            for_i32("i", i32(0), field("Dict", "used", get("x")), [
                set("k", arr_get("Vals", field("Dict", "keys", get("x")), get("i"))),
                if_(eqz(is_null(get("k"))), call("rt_dict_set", get("r"), get("k"), arr_get("Vals", field("Dict", "vals", get("x")), get("i")))),
            ]),
            if_(eqz(ref_eq(get("x"), get("b"))), [set("x", get("b")), br("union")]),
        ]),
        get("r"),
    ])

    # Entry index of key k (with hash h), or -1.
    add_func(m, "rt_dict_find", [("d", DICT), ("k", V), ("h", I32)], [I32], locals = [
        ("idx", I32A),
        ("keys", VALS),
        ("mask", I32),
        ("p", I32),
        ("e", I32),
    ], body = [
        set("idx", F("index")),
        set("keys", F("keys")),
        set("mask", op("i32.sub", arr_len(get("idx")), i32(1))),
        set("p", op("i32.and", get("h"), get("mask"))),
        forever("probe", [
            set("e", arr_get("I32A", get("idx"), get("p"))),
            if_(op("i32.eq", get("e"), i32(-1)), ret(i32(-1))),
            if_(and_(
                op("i32.eq", arr_get("I32A", F("hashes"), get("e")), get("h")),
                and_(
                    eqz(is_null(arr_get("Vals", get("keys"), get("e")))),
                    call("rt_eq", arr_get("Vals", get("keys"), get("e")), get("k")),
                ),
            ), ret(get("e"))),
            set("p", op("i32.and", op("i32.add", get("p"), i32(1)), get("mask"))),
        ]),
    ])

    add_func(m, "rt_dict_get", [("d", DICT), ("k", V)], [V], locals = [("e", I32)], body = [
        set("e", call("rt_dict_find", d, get("k"), call("rt_hash", get("k")))),
        if_(op("i32.lt_s", get("e"), i32(0)), ret(null("eq"))),
        arr_get("Vals", F("vals"), get("e")),
    ])

    # Rebuild into fresh arrays, dropping tombstones; doubles the table
    # unless at least half the used entries were tombstones.
    add_func(m, "rt_dict_grow", [("d", DICT)], [], locals = [
        ("size", I32),
        ("mask", I32),
        ("nidx", I32A),
        ("nk", VALS),
        ("nv", VALS),
        ("nh", I32A),
        ("i", I32),
        ("j", I32),
        ("p", I32),
        ("used", I32),
        ("k", V),
    ], body = [
        set("size", arr_len(F("index"))),
        if_(op("i32.ge_s", op("i32.shl", F("len"), i32(1)), F("used")),
            set("size", op("i32.shl", get("size"), i32(1)))),
        set("mask", op("i32.sub", get("size"), i32(1))),
        set("nidx", arr_new("I32A", i32(-1), get("size"))),
        set("nk", arr_new_default("Vals", op("i32.shr_u", get("size"), i32(1)))),
        set("nv", arr_new_default("Vals", op("i32.shr_u", get("size"), i32(1)))),
        set("nh", arr_new_default("I32A", op("i32.shr_u", get("size"), i32(1)))),
        set("used", F("used")),
        set("j", i32(0)),
        for_i32("i", i32(0), get("used"), [
            set("k", arr_get("Vals", F("keys"), get("i"))),
            if_(eqz(is_null(get("k"))), [
                arr_set("Vals", get("nk"), get("j"), get("k")),
                arr_set("Vals", get("nv"), get("j"), arr_get("Vals", F("vals"), get("i"))),
                arr_set("I32A", get("nh"), get("j"), arr_get("I32A", F("hashes"), get("i"))),
                set("p", op("i32.and", arr_get("I32A", get("nh"), get("j")), get("mask"))),
                while_(op("i32.ne", arr_get("I32A", get("nidx"), get("p")), i32(-1)),
                       set("p", op("i32.and", op("i32.add", get("p"), i32(1)), get("mask"))), label = "slot"),
                arr_set("I32A", get("nidx"), get("p"), get("j")),
                inc("j"),
            ]),
        ]),
        setfield("Dict", "used", d, get("j")),
        setfield("Dict", "keys", d, get("nk")),
        setfield("Dict", "vals", d, get("nv")),
        setfield("Dict", "hashes", d, get("nh")),
        setfield("Dict", "index", d, get("nidx")),
    ])

    add_func(m, "rt_dict_set", [("d", DICT), ("k", V), ("v", V)], [], locals = [
        ("h", I32),
        ("e", I32),
        ("p", I32),
        ("mask", I32),
        ("idx", I32A),
        ("u", I32),
    ], body = [
        check_mutable(m, F("frozen"), "cannot insert into frozen hash table", "cannot insert into hash table during iteration"),
        set("h", call("rt_hash", get("k"))),
        set("e", call("rt_dict_find", d, get("k"), get("h"))),
        if_(op("i32.ge_s", get("e"), i32(0)), [
            arr_set("Vals", F("vals"), get("e"), get("v")),
            "return",
        ]),
        if_(op("i32.eq", F("used"), arr_len(F("keys"))), call("rt_dict_grow", d)),
        set("idx", F("index")),
        set("mask", op("i32.sub", arr_len(get("idx")), i32(1))),
        set("p", op("i32.and", get("h"), get("mask"))),
        while_(op("i32.ne", arr_get("I32A", get("idx"), get("p")), i32(-1)),
               set("p", op("i32.and", op("i32.add", get("p"), i32(1)), get("mask")))),
        set("u", F("used")),
        arr_set("I32A", get("idx"), get("p"), get("u")),
        arr_set("Vals", F("keys"), get("u"), get("k")),
        arr_set("Vals", F("vals"), get("u"), get("v")),
        arr_set("I32A", F("hashes"), get("u"), get("h")),
        setfield("Dict", "used", d, op("i32.add", get("u"), i32(1))),
        setfield("Dict", "len", d, op("i32.add", F("len"), i32(1))),
    ])

    add_func(m, "rt_dict_eq", [("a", DICT), ("b", DICT), ("d", I32)], [I32], locals = [
        ("i", I32),
        ("k", V),
        ("w", V),
    ], body = [
        if_(op("i32.ne", field("Dict", "len", get("a")), field("Dict", "len", get("b"))), ret(i32(0))),
        for_i32("i", i32(0), field("Dict", "used", get("a")), [
            set("k", arr_get("Vals", field("Dict", "keys", get("a")), get("i"))),
            if_(eqz(is_null(get("k"))), [
                set("w", call("rt_dict_get", get("b"), get("k"))),
                if_(or_(is_null(get("w")),
                        eqz(call("rt_eq_d", arr_get("Vals", field("Dict", "vals", get("a")), get("i")), get("w"), op("i32.sub", get("d"), i32(1))))),
                    ret(i32(0))),
            ]),
        ]),
        i32(1),
    ])

    add_func(m, "rt_dict_keys", [("d", DICT)], [TUPLE], locals = [
        ("out", VALS),
        ("i", I32),
        ("j", I32),
        ("k", V),
    ], body = [
        set("out", arr_new_default("Vals", F("len"))),
        set("j", i32(0)),
        for_i32("i", i32(0), F("used"), [
            set("k", arr_get("Vals", F("keys"), get("i"))),
            if_(eqz(is_null(get("k"))), [arr_set("Vals", get("out"), get("j"), get("k")), inc("j")]),
        ]),
        new("Tuple", get("out")),
    ])

# ---------------------------------------------------------------- lists and tuples

def _sets(m):
    def D(s):
        return field("Set", "d", get(s))

    add_func(m, "rt_set_new", [], [ref("Set")], [new("Set", call("rt_dict_new"))])

    # i32: is k in set s
    add_func(m, "rt_set_has", [("s", ref("Set")), ("k", V)], [I32], [
        op("i32.ge_s", call("rt_dict_find", D("s"), get("k"), call("rt_hash", get("k"))), i32(0)),
    ])

    # Add to `out` every element of a (in order) that is (want=1) or is not
    # (want=0) in b; b may be null to add all of a.
    add_func(m, "rt_set_filter", [("out", ref("Set")), ("a", ref("Set")), ("b", ref("Set", True)), ("want", I32)], [], locals = [
        ("i", I32),
        ("k", V),
    ], body = [
        for_i32("i", i32(0), field("Dict", "used", D("a")), [
            set("k", arr_get("Vals", field("Dict", "keys", D("a")), get("i"))),
            if_(and_(eqz(is_null(get("k"))),
                     or_(is_null(get("b")), op("i32.eq", call("rt_set_has", non_null(get("b")), get("k")), get("want")))),
                call("rt_dict_set", D("out"), get("k"), gget("None"))),
        ]),
    ])

    # Element order follows starlark-go: a | b: a then b's new ones;
    # a & b: b's elements that are in a; a - b: a's not in b; a ^ b: a's not
    # in b, then b's not in a.
    P = [("a", ref("Set")), ("b", ref("Set"))]
    add_func(m, "rt_set_union", P, [V], locals = [("r", ref("Set"))], body = [
        set("r", call("rt_set_new")),
        call("rt_set_filter", get("r"), get("a"), null("Set"), i32(1)),
        call("rt_set_filter", get("r"), get("b"), null("Set"), i32(1)),
        get("r"),
    ])
    add_func(m, "rt_set_intersection", P, [V], locals = [("r", ref("Set"))], body = [
        set("r", call("rt_set_new")),
        call("rt_set_filter", get("r"), get("b"), get("a"), i32(1)),
        get("r"),
    ])
    add_func(m, "rt_set_difference", P, [V], locals = [("r", ref("Set"))], body = [
        set("r", call("rt_set_new")),
        call("rt_set_filter", get("r"), get("a"), get("b"), i32(0)),
        get("r"),
    ])
    add_func(m, "rt_set_symmetric_difference", P, [V], locals = [("r", ref("Set"))], body = [
        set("r", call("rt_set_new")),
        call("rt_set_filter", get("r"), get("a"), get("b"), i32(0)),
        call("rt_set_filter", get("r"), get("b"), get("a"), i32(0)),
        get("r"),
    ])

    # i32: a is a subset of b
    add_func(m, "rt_set_subset", P, [I32], locals = [("i", I32), ("k", V)], body = [
        for_i32("i", i32(0), field("Dict", "used", D("a")), [
            set("k", arr_get("Vals", field("Dict", "keys", D("a")), get("i"))),
            if_(and_(eqz(is_null(get("k"))), eqz(call("rt_set_has", get("b"), get("k")))), ret(i32(0))),
        ]),
        i32(1),
    ])

def _lazy(m):
    R = ref("Range")

    def RF(f, v):
        return field("Range", f, get(v))

    # Number of elements of range r, or -1 if it doesn't fit in an int.
    # Works on unsigned differences, so no step or bound can overflow.
    add_func(m, "rt_range_len", [("r", R)], [I64], locals = [("st", I64), ("d", I64), ("n", I64)], body = [
        set("st", RF("step", "r")),
        if_(op("i64.gt_s", get("st"), i64(0)), [
            if_(op("i64.ge_s", RF("start", "r"), RF("stop", "r")), ret(i64(0))),
            set("d", op("i64.sub", RF("stop", "r"), RF("start", "r"))),
        ], [
            if_(op("i64.le_s", RF("start", "r"), RF("stop", "r")), ret(i64(0))),
            set("d", op("i64.sub", RF("start", "r"), RF("stop", "r"))),
            set("st", op("i64.sub", i64(0), get("st"))),
        ]),
        set("n", op("i64.add", op("i64.div_u", op("i64.sub", get("d"), i64(1)), get("st")), i64(1))),
        select_(_i64lt0(get("n")), i64(-1), get("n"), I64),
    ])

    # Ranges are equal when they hold the same elements (starlark-go).
    add_func(m, "rt_range_eq", [("a", R), ("b", R)], [I32], locals = [("n", I64)], body = [
        set("n", call("rt_range_len", get("a"))),
        if_(op("i64.ne", get("n"), call("rt_range_len", get("b"))), ret(i32(0))),
        if_(op("i64.eqz", get("n")), ret(i32(1))),
        if_(op("i64.ne", RF("start", "a"), RF("start", "b")), ret(i32(0))),
        if_(op("i64.eq", get("n"), i64(1)), ret(i32(1))),
        op("i64.eq", RF("step", "a"), RF("step", "b")),
    ])

    add_func(m, "rt_range_items", [("r", R)], [TUPLE], locals = [("n", I64), ("out", VALS), ("i", I32)], body = [
        set("n", call("rt_range_len", get("r"))),
        if_(or_(_i64lt0(get("n")), op("i64.gt_s", get("n"), i64(MAX_ARRAY))), fail_(m, "range too large to materialize")),
        set("out", arr_new_default("Vals", op("i32.wrap_i64", get("n")))),
        for_i32("i", i32(0), arr_len(get("out")), [
            arr_set("Vals", get("out"), get("i"), call("rt_int", op("i64.add", RF("start", "r"),
                    op("i64.mul", op("i64.extend_i32_s", get("i")), RF("step", "r"))))),
        ]),
        new("Tuple", get("out")),
    ])

    # r[i]; a range's length may exceed 32 bits (-1 from rt_range_len, "too
    # long for an int", compares as the largest unsigned length)
    add_func(m, "rt_range_index", [("r", R), ("i", V)], [V], locals = [("n", I64), ("x", I64), ("b", BUF)], body = [
        # big or non-int indexes: rt_norm_index has the messages
        if_(or_(eqz(call("rt_is_small", get("i"))), call("rt_out_of_i32", call("rt_i64", get("i")))),
            [call("rt_norm_index", get("i"), i32(0), S(m, ""), S(m, "range")), "drop"]),
        set("n", call("rt_range_len", get("r"))),
        set("x", call("rt_i64", get("i"))),
        if_(_i64lt0(get("x")), set("x", op("i64.add", get("x"), get("n")))),
        if_(or_(_i64lt0(get("x")), op("i64.ge_u", get("x"), get("n"))), [
            # "range index 5 out of range [-3:2]" / "index 0 out of range: empty range"
            set("b", call("rt_buf_new")),
            if_(op("i64.ne", get("n"), i64(0)), call("rt_buf_str", get("b"), S(m, "range "))),
            call("rt_buf_str", get("b"), S(m, "index ")),
            call("rt_buf_i64", get("b"), call("rt_i64", get("i"))),
            if_(op("i64.eqz", get("n")), call("rt_buf_str", get("b"), S(m, " out of range: empty range")), [
                call("rt_buf_str", get("b"), S(m, " out of range [")),
                call("rt_buf_i64", get("b"), op("i64.sub", i64(0), get("n"))),
                call("rt_buf_byte", get("b"), i32(58)),
                call("rt_buf_i64", get("b"), op("i64.sub", get("n"), i64(1))),
                call("rt_buf_byte", get("b"), i32(93)),
            ]),
            call("rt_fail", call("rt_buf_to_str", get("b"))),
        ]),
        call("rt_int", op("i64.add", RF("start", "r"), op("i64.mul", get("x"), RF("step", "r")))),
    ])

    # i32: integer x is an element of range r
    add_func(m, "rt_range_has", [("r", R), ("x", I64)], [I32], locals = [("d", I64)], body = [
        if_(op("i64.gt_s", RF("step", "r"), i64(0)), [
            if_(or_(op("i64.lt_s", get("x"), RF("start", "r")), op("i64.ge_s", get("x"), RF("stop", "r"))), ret(i32(0))),
            set("d", op("i64.sub", get("x"), RF("start", "r"))),
            ret(op("i64.eqz", op("i64.rem_u", get("d"), RF("step", "r")))),
        ]),
        if_(or_(op("i64.gt_s", get("x"), RF("start", "r")), op("i64.le_s", get("x"), RF("stop", "r"))), ret(i32(0))),
        set("d", op("i64.sub", RF("start", "r"), get("x"))),
        op("i64.eqz", op("i64.rem_u", get("d"), op("i64.sub", i64(0), RF("step", "r")))),
    ])

    # The code point of the k-byte valid UTF-8 sequence at a[i].
    add_func(m, "rt_utf8_rune", [("a", U8A), ("i", I32), ("k", I32)], [I32], locals = [("r", I32), ("j", I32)], body = [
        set("r", arr_get_u("U8", get("a"), get("i"))),
        if_(op("i32.eq", get("k"), i32(1)), ret(get("r"))),
        set("r", op("i32.and", get("r"), op("i32.shr_u", i32(0x7f), get("k")))),
        for_i32("j", i32(1), get("k"), [
            set("r", op("i32.or", op("i32.shl", get("r"), i32(6)),
                        op("i32.and", arr_get_u("U8", get("a"), op("i32.add", get("i"), get("j"))), i32(0x3f)))),
        ]),
        get("r"),
    ])

    # The elements of a $Lazy: one-byte strings, byte values, code points as
    # strings (an invalid byte is "\ufffd"), or code point values
    # (an invalid byte is U+FFFD), as Go's string iteration decodes them.
    add_func(m, "rt_lazy_items", [("l", ref("Lazy"))], [TUPLE], locals = [
        ("a", U8A),
        ("n", I32),
        ("i", I32),
        ("k", I32),
        ("kind", I32),
        ("out", LIST),
        ("sub", U8A),
    ], body = [
        set("a", field("Str", "b", field("Lazy", "s", get("l")))),
        set("n", arr_len(get("a"))),
        set("kind", field("Lazy", "kind", get("l"))),
        set("out", call("rt_list_new", get("n"))),
        set("i", i32(0)),
        while_(op("i32.lt_s", get("i"), get("n")), [
            if_(op("i32.ge_u", get("kind"), i32(LAZY_CODEPOINTS)), [
                if_(op("i32.ne", get("kind"), i32(LAZY_BYTES_ELEMS)), set("k", call("rt_utf8_seq", get("a"), get("i"), get("n"))), set("k", i32(1))),
            ], set("k", i32(1))),
            if_(op("i32.eq", get("kind"), i32(LAZY_CODEPOINT_ORDS)),
                call("rt_list_append", get("out"), op("ref.i31", select_(get("k"), call("rt_utf8_rune", get("a"), get("i"), get("k")), i32(0xfffd), I32))),
            if_(or_(op("i32.eq", get("kind"), i32(LAZY_ELEMS)), op("i32.eq", get("kind"), i32(LAZY_CODEPOINTS))), [
                if_(eqz(get("k")), [
                    set("k", i32(1)),
                    # codepoints(): an invalid byte is "\ufffd" (starlark-go)
                    if_(op("i32.eq", get("kind"), i32(LAZY_CODEPOINTS)), [
                        call("rt_list_append", get("out"), S(m, "\ufffd")),
                        set("i", op("i32.add", get("i"), i32(1))),
                        br("loop"),
                    ]),
                ]),
                set("sub", arr_new_default("U8", get("k"))),
                arr_copy("U8", get("sub"), i32(0), get("a"), get("i"), get("k")),
                call("rt_list_append", get("out"), new("Str", i32(0), get("sub"))),
            ], call("rt_list_append", get("out"), op("ref.i31", arr_get_u("U8", get("a"), get("i")))))),
            if_(eqz(get("k")), set("k", i32(1))),
            set("i", op("i32.add", get("i"), get("k"))),
        ]),
        new("Tuple", call("rt_vals_concat", field("List", "items", get("out")), field("List", "len", get("out")), arr_new_default("Vals", i32(0)), i32(0))),
    ])

def _sequences(m):
    add_func(m, "rt_list_new", [("cap", I32)], [LIST], [new("List", i32(0), arr_new_default("Vals", get("cap")), i32(0))])

    add_func(m, "rt_list_append", [("l", LIST), ("v", V)], [], locals = [
        ("items", VALS),
        ("n", I32),
        ("na", VALS),
    ], body = [
        check_mutable(m, field("List", "frozen", get("l")), "cannot append to frozen list", "cannot append to list during iteration"),
        set("items", field("List", "items", get("l"))),
        set("n", field("List", "len", get("l"))),
        if_(op("i32.eq", get("n"), arr_len(get("items"))), [
            if_(op("i32.ge_s", get("n"), i32(MAX_ARRAY)), fail_(m, "list too large")),
            set("na", arr_new_default("Vals", select_(
                op("i32.lt_s", get("n"), i32(4)),
                i32(4),
                select_(op("i32.gt_s", get("n"), i32(MAX_ARRAY // 2)), i32(MAX_ARRAY), op("i32.shl", get("n"), i32(1)), I32),
                I32,
            ))),
            arr_copy("Vals", get("na"), i32(0), get("items"), i32(0), get("n")),
            setfield("List", "items", get("l"), get("na")),
            set("items", get("na")),
        ]),
        arr_set("Vals", get("items"), get("n"), get("v")),
        setfield("List", "len", get("l"), op("i32.add", get("n"), i32(1))),
    ])

    # Fresh array holding x[0:xn] + y[0:yn].
    add_func(m, "rt_vals_concat", [("x", VALS), ("xn", I32), ("y", VALS), ("yn", I32)], [VALS], locals = [("na", VALS)], body = [
        set("na", arr_new_default("Vals", op("i32.add", get("xn"), get("yn")))),
        arr_copy("Vals", get("na"), i32(0), get("x"), i32(0), get("xn")),
        arr_copy("Vals", get("na"), get("xn"), get("y"), i32(0), get("yn")),
        get("na"),
    ])

    # Fresh array holding x[0:n] repeated `count` times.
    add_func(m, "rt_vals_repeat", [("x", VALS), ("n", I32), ("count", V)], [VALS], locals = [
        ("na", VALS),
        ("c", I32),
        ("i", I32),
    ], body = [
        if_(eqz(get("n")), ret(arr_new_default("Vals", i32(0)))),
        # lists and tuples: V8's array limit (see NOTES.md)
        set("c", call("rt_repeat_count", get("count"), get("n"), i64(1 << 27))),
        set("na", arr_new_default("Vals", op("i32.mul", get("c"), get("n")))),
        for_i32("i", i32(0), get("c"), [
            arr_copy("Vals", get("na"), op("i32.mul", get("i"), get("n")), get("x"), i32(0), get("n")),
        ]),
        get("na"),
    ])

    add_func(m, "rt_vals_contains", [("x", VALS), ("n", I32), ("v", V)], [I32], locals = [("i", I32)], body = [
        for_i32("i", i32(0), get("n"), [
            if_(call("rt_eq", arr_get("Vals", get("x"), get("i")), get("v")), ret(i32(1))),
        ]),
        i32(0),
    ])

    add_func(m, "rt_out_of_i32", [("x", I64)], [I32], [
        op("i64.ne", op("i64.extend_i32_s", op("i32.wrap_i64", get("x"))), get("x")),
    ])

    # Index i into a sequence of length n. pre: message prefix ("" or
    # "pop: "); what: the sequence's type ("list").
    add_func(m, "rt_norm_index", [("i", V), ("n", I32), ("pre", STR), ("what", STR)], [I32], locals = [("x", I64), ("b", BUF)], body = [
        if_(or_(is_("Big", get("i")), and_(call("rt_is_small", get("i")),
                call("rt_out_of_i32", call("rt_i64", get("i"))))), [
            # "list index: 1180591620717411303424 out of range" (an index
            # must fit in 32 bits, as in starlark-go)
            set("b", call("rt_buf_new")),
            call("rt_buf_str", get("b"), get("pre")),
            call("rt_buf_str", get("b"), get("what")),
            call("rt_buf_str", get("b"), S(m, " index: ")),
            call("rt_buf_value", get("b"), get("i"), i32(0)),
            call("rt_buf_str", get("b"), S(m, " out of range")),
            call("rt_fail", call("rt_buf_to_str", get("b"))),
        ]),
        if_(eqz(call("rt_is_int", get("i"))), [
            # "list index: got float, want int"
            set("b", call("rt_buf_new")),
            call("rt_buf_str", get("b"), get("pre")),
            call("rt_buf_str", get("b"), get("what")),
            call("rt_buf_str", get("b"), S(m, " index: got ")),
            call("rt_buf_str", get("b"), call("rt_type", get("i"))),
            call("rt_buf_str", get("b"), S(m, ", want int")),
            call("rt_fail", call("rt_buf_to_str", get("b"))),
        ]),
        set("x", call("rt_i64", get("i"))),
        if_(_i64lt0(get("x")), set("x", op("i64.add", get("x"), op("i64.extend_i32_s", get("n"))))),
        if_(or_(_i64lt0(get("x")), op("i64.ge_s", get("x"), op("i64.extend_i32_s", get("n")))), [
            # starlark-go: "list index 5 out of range [-1:0]" /
            # "index 0 out of range: empty list"
            set("b", call("rt_buf_new")),
            call("rt_buf_str", get("b"), get("pre")),
            if_(get("n"), [call("rt_buf_str", get("b"), get("what")), call("rt_buf_byte", get("b"), i32(32))]),
            call("rt_buf_str", get("b"), S(m, "index ")),
            call("rt_buf_i64", get("b"), call("rt_i64", get("i"))),
            if_(eqz(get("n")), [
                call("rt_buf_str", get("b"), S(m, " out of range: empty ")),
                call("rt_buf_str", get("b"), get("what")),
            ], [
                call("rt_buf_str", get("b"), S(m, " out of range [")),
                call("rt_buf_i64", get("b"), op("i64.sub", i64(0), op("i64.extend_i32_s", get("n")))),
                call("rt_buf_byte", get("b"), i32(58)),  # :
                call("rt_buf_i64", get("b"), op("i64.extend_i32_s", op("i32.sub", get("n"), i32(1)))),
                call("rt_buf_byte", get("b"), i32(93)),  # ]
            ]),
            call("rt_fail", call("rt_buf_to_str", get("b"))),
        ]),
        op("i32.wrap_i64", get("x")),
    ])

# ---------------------------------------------------------------- generic operations

def _generic(m):
    x = get("x")

    def L(f, v):
        return field("List", f, as_("List", v))

    def T(v):
        return field("Tuple", "items", as_("Tuple", v))

    def SB(v):
        return field("Str", "b", as_("Str", v))

    def BB(v):
        return field("Bytes", "b", as_("Bytes", v))

    a, b = get("a"), get("b")

    add_func(m, "rt_add", [("a", V), ("b", V)], [V], locals = [("x", I64), ("y", I64), ("r", I64)], body = [
        if_(and_(call("rt_is_small", a), call("rt_is_small", b)), [
            set("x", call("rt_i64", a)),
            set("y", call("rt_i64", b)),
            set("r", op("i64.add", get("x"), get("y"))),
            if_(op("i64.ge_s", op("i64.and", op("i64.xor", get("x"), get("r")), op("i64.xor", get("y"), get("r"))), i64(0)),
                ret(call("rt_int", get("r")))),
        ]),
        if_(and_(call("rt_is_int", a), call("rt_is_int", b)), ret(call("rt_big_addsub", a, b, i32(0)))),
        if_(or_(is_("Float", a), is_("Float", b)), ret(call("rt_fadd", a, b))),
        if_(both("Str", a, b), ret(call("rt_str_concat", as_("Str", a), as_("Str", b)))),
        if_(both("Bytes", a, b), ret(str_bytes(call("rt_str_concat", bstr(a), bstr(b))))),
        if_(both("Struct", a, b), ret(call("rt_struct_add", as_("Struct", a), as_("Struct", b)))),
        if_(both("List", a, b), ret(new(
            "List",
            op("i32.add", L("len", a), L("len", b)),
            call("rt_vals_concat", L("items", a), L("len", a), L("items", b), L("len", b)),
            i32(0),
        ))),
        if_(both("Tuple", a, b), ret(new(
            "Tuple",
            call("rt_vals_concat", T(a), arr_len(T(a)), T(b), arr_len(T(b))),
        ))),
        type_err2(m, "unknown binary op: ", a, " + ", b, ""),
    ])

    add_func(m, "rt_mul", [("a", V), ("b", V)], [V], locals = [("t", V), ("arr", VALS), ("x", I64), ("y", I64), ("r", I64)], body = [
        if_(and_(call("rt_is_small", a), call("rt_is_small", b)), [
            set("x", call("rt_i64", a)),
            set("y", call("rt_i64", b)),
            if_(op("i64.eqz", get("x")), ret(op("ref.i31", i32(0)))),
            if_(eqz(and_(op("i64.eq", get("x"), i64(-1)), op("i64.eq", get("y"), i64(MIN_I64)))), [
                set("r", op("i64.mul", get("x"), get("y"))),
                if_(op("i64.eq", op("i64.div_s", get("r"), get("x")), get("y")), ret(call("rt_int", get("r")))),
            ]),
        ]),
        if_(and_(call("rt_is_int", a), call("rt_is_int", b)), ret(call("rt_big_mul", a, b))),
        if_(or_(is_("Float", a), is_("Float", b)), ret(call("rt_fmul", a, b))),
        # put the int (if any) on the right
        if_(call("rt_is_int", a), [set("t", a), set("a", b), set("b", get("t"))]),
        if_(call("rt_is_int", b), [
            if_(is_("Str", a), ret(call("rt_str_repeat", as_("Str", a), b))),
            if_(is_("Bytes", a), ret(str_bytes(call("rt_str_repeat", bstr(a), b)))),
            if_(is_("List", a), [
                set("arr", call("rt_vals_repeat", L("items", a), L("len", a), b)),
                ret(new("List", arr_len(get("arr")), get("arr"), i32(0))),
            ]),
            if_(is_("Tuple", a), ret(new("Tuple", call("rt_vals_repeat", T(a), arr_len(T(a)), b)))),
        ]),
        type_err2(m, "unknown binary op: ", a, " * ", b, ""),
    ])

    add_func(m, "rt_len_i32", [("x", V)], [I32], locals = [("n", I64)], body = [
        if_(is_("Str", x), ret(arr_len(SB(x)))),
        if_(is_("Bytes", x), ret(arr_len(BB(x)))),
        if_(is_("List", x), ret(L("len", x))),
        if_(is_("Tuple", x), ret(arr_len(T(x)))),
        if_(is_("Dict", x), ret(field("Dict", "len", as_("Dict", x)))),
        if_(is_("Set", x), ret(field("Dict", "len", field("Set", "d", as_("Set", x))))),
        if_(is_("Range", x), [
            set("n", call("rt_range_len", as_("Range", x))),
            if_(op("i64.le_u", get("n"), i64(0x7fffffff)), ret(op("i32.wrap_i64", get("n")))),
        ]),
        if_(and_(is_("Lazy", x), op("i32.le_u", field("Lazy", "kind", as_("Lazy", x)), i32(LAZY_ELEM_ORDS))),
            ret(arr_len(field("Str", "b", field("Lazy", "s", as_("Lazy", x)))))),
        type_err1(m, "len: value of type ", x, " has no len"),
    ])

    add_func(m, "rt_len", [("x", V)], [V], [
        # a range's length may exceed 32 bits
        if_(and_(is_("Range", x), op("i64.ge_s", call("rt_range_len", as_("Range", x)), i64(0))),
            ret(call("rt_int", call("rt_range_len", as_("Range", x))))),
        call("rt_int", op("i64.extend_i32_s", call("rt_len_i32", x))),
    ])

    add_func(m, "rt_index", [("x", V), ("i", V)], [V], locals = [("v", V), ("b", BUF), ("k", I32), ("c", I32)], body = [
        if_(is_("List", x), ret(arr_get("Vals", L("items", x), call("rt_norm_index", get("i"), L("len", x), S(m, ""), S(m, "list"))))),
        if_(is_("Tuple", x), ret(arr_get("Vals", T(x), call("rt_norm_index", get("i"), arr_len(T(x)), S(m, ""), S(m, "tuple"))))),
        if_(is_("Str", x), ret(new("Str", i32(0), arr_fixed(
            "U8",
            arr_get_u("U8", SB(x), call("rt_norm_index", get("i"), arr_len(SB(x)), S(m, ""), S(m, "string"))),
        )))),
        if_(is_("Range", x), ret(call("rt_range_index", as_("Range", x), get("i")))),
        if_(and_(is_("Lazy", x), op("i32.le_u", field("Lazy", "kind", as_("Lazy", x)), i32(LAZY_ELEM_ORDS))), [
            set("k", call("rt_norm_index", get("i"), call("rt_len_i32", x), S(m, ""), S(m, "string.elems"))),
            set("c", arr_get_u("U8", field("Str", "b", field("Lazy", "s", as_("Lazy", x))), get("k"))),
            if_(field("Lazy", "kind", as_("Lazy", x)), ret(op("ref.i31", get("c")))),
            ret(new("Str", i32(0), arr_fixed("U8", get("c")))),
        ]),
        if_(is_("Bytes", x), ret(new("Bytes", i32(0), arr_fixed(
            "U8",
            arr_get_u("U8", BB(x), call("rt_norm_index", get("i"), arr_len(BB(x)), S(m, ""), S(m, "bytes"))),
        )))),
        if_(is_("Dict", x), [
            set("v", call("rt_dict_get", as_("Dict", x), get("i"))),
            if_(is_null(get("v")), [
                set("b", call("rt_buf_new")),
                call("rt_buf_str", get("b"), S(m, "key ")),
                call("rt_buf_value", get("b"), get("i"), i32(1)),
                call("rt_buf_str", get("b"), S(m, " not in dict")),
                call("rt_fail", call("rt_buf_to_str", get("b"))),
            ]),
            ret(get("v")),
        ]),
        type_err2(m, "unhandled index operation ", x, "[", get("i"), "]"),
    ])

    add_func(m, "rt_setindex", [("x", V), ("i", V), ("v", V)], [], [
        if_(is_("List", x), [
            check_mutable(m, L("frozen", x), "cannot assign to element of frozen list", "cannot assign to element of list during iteration"),
            arr_set("Vals", L("items", x), call("rt_norm_index", get("i"), L("len", x), S(m, ""), S(m, "list")), get("v")),
            "return",
        ]),
        if_(is_("Dict", x), [
            call("rt_dict_set", as_("Dict", x), get("i"), get("v")),
            "return",
        ]),
        type_err1(m, "", x, " value does not support item assignment"),
    ])

    # x in c
    add_func(m, "rt_in", [("x", V), ("c", V)], [I32], locals = [("f", F64)], body = [
        if_(is_("List", get("c")), ret(call("rt_vals_contains", L("items", get("c")), L("len", get("c")), x))),
        if_(is_("Tuple", get("c")), ret(call("rt_vals_contains", T(get("c")), arr_len(T(get("c"))), x))),
        if_(is_("Set", get("c")), ret(op(
            "i32.ge_s",
            call("rt_dict_find", field("Set", "d", as_("Set", get("c"))), x, call("rt_hash", x)),
            i32(0),
        ))),
        # dicts: as starlark-go, an unhashable key is just not there
        if_(is_("Dict", get("c")), [
            if_(eqz(ref_eq(call("rt_unhashable", x), gget("None"))), ret(i32(0))),
            if_(or_(is_("Range", x), is_("Lazy", x)), ret(i32(0))),
            ret(op("i32.ge_s", call("rt_dict_find", as_("Dict", get("c")), x, call("rt_hash", x)), i32(0))),
        ]),
        if_(is_("Str", get("c")), [
            if_(eqz(is_("Str", x)), type_err1(m, "'in <string>' requires string as left operand, not ", x, "")),
            ret(call("rt_str_contains", as_("Str", get("c")), as_("Str", x))),
        ]),
        if_(is_("Range", get("c")), [
            # a float acts like its integer part (starlark-go's NumberToInt)
            if_(is_("Float", x), [
                set("f", field("Float", "v", as_("Float", x))),
                if_(op("f64.ne", op("f64.sub", get("f"), get("f")), op("f64.sub", get("f"), get("f"))),  # inf, nan
                    type_err1(m, "'in <range>' requires integer as left operand, not ", x, "")),
                if_(op("f64.ge", op("f64.abs", get("f")), op("f64.convert_i64_s", i64(9 * 1000000000000000000))), ret(i32(0))),
                ret(call("rt_range_has", as_("Range", get("c")), op("i64.trunc_f64_s", get("f")))),
            ]),
            if_(eqz(call("rt_is_int", x)), type_err1(m, "'in <range>' requires integer as left operand, not ", x, "")),
            ret(call("rt_range_has", as_("Range", get("c")), call("rt_i64", x))),
        ]),
        if_(is_("Bytes", get("c")), [
            if_(is_("Bytes", x), ret(call("rt_str_contains", bstr(get("c")), bstr(x)))),
            if_(call("rt_is_int", x), [
                if_(op("i64.gt_u", call("rt_i64", x), i64(255)), [
                    S(m, "int in bytes: "), call("rt_str", x), call("rt_str_concat"),
                    S(m, " out of range (want value in unsigned 8-bit range)"), call("rt_str_concat"),
                    call("rt_fail"), "unreachable",
                ]),
                ret(call("rt_str_contains", bstr(get("c")), new("Str", i32(0), arr_fixed("U8", op("i32.wrap_i64", call("rt_i64", x)))))),
            ]),
            type_err1(m, "'in bytes' requires bytes or int as left operand, not ", x, ""),
        ]),
        type_err2(m, "unknown binary op: ", x, " in ", get("c"), ""),
    ])

    # Snapshot of the elements a for-loop visits, as a tuple.
    add_func(m, "rt_iter", [("x", V)], [TUPLE], [
        if_(is_("Tuple", x), ret(as_("Tuple", x))),
        if_(is_("List", x), ret(new(
            "Tuple",
            call("rt_vals_concat", L("items", x), L("len", x), arr_new_default("Vals", i32(0)), i32(0)),
        ))),
        if_(is_("Dict", x), ret(call("rt_dict_keys", as_("Dict", x)))),
        if_(is_("Set", x), ret(call("rt_dict_keys", field("Set", "d", as_("Set", x))))),
        if_(is_("Range", x), ret(call("rt_range_items", as_("Range", x)))),
        if_(is_("Lazy", x), ret(call("rt_lazy_items", as_("Lazy", x)))),
        type_err1(m, "", x, " value is not iterable"),
    ])

# ---------------------------------------------------------------- str / repr / print

def _printing(m):
    v, b = get("v"), get("b")

    def str_(s):
        return call("rt_buf_str", b, S(m, s))

    def byte(c):
        return call("rt_buf_byte", b, i32(c))

    # Reference cycles: the lists and dicts being printed, outermost first
    # (like starlark-go, only the path to the current value counts, so
    # [x, x] prints both, but a list inside itself prints as [...]).
    add_global(m, "repr_path", ref("Vals", True), True, [null("Vals")])
    add_global(m, "repr_depth", I32, True, [i32(0)])

    # i32: v is already being printed (1), or else push it on the path (0)
    add_func(m, "rt_repr_enter", [("v", V)], [I32], locals = [("i", I32), ("na", VALS)], body = [
        if_(is_null(gget("repr_path")), gset("repr_path", arr_new_default("Vals", i32(8)))),
        for_i32("i", i32(0), gget("repr_depth"), [
            if_(ref_eq(arr_get("Vals", non_null(gget("repr_path")), get("i")), v), ret(i32(1))),
        ]),
        if_(op("i32.eq", gget("repr_depth"), arr_len(non_null(gget("repr_path")))), [
            set("na", arr_new_default("Vals", op("i32.shl", gget("repr_depth"), i32(1)))),
            arr_copy("Vals", get("na"), i32(0), non_null(gget("repr_path")), i32(0), gget("repr_depth")),
            gset("repr_path", get("na")),
        ]),
        arr_set("Vals", non_null(gget("repr_path")), gget("repr_depth"), v),
        gset("repr_depth", op("i32.add", gget("repr_depth"), i32(1))),
        i32(0),
    ])
    add_func(m, "rt_repr_leave", [], [], [
        gset("repr_depth", op("i32.sub", gget("repr_depth"), i32(1))),
        arr_set("Vals", non_null(gget("repr_path")), gget("repr_depth"), null("eq")),
    ])

    add_func(m, "rt_buf_value", [("b", BUF), ("v", V), ("quote", I32)], [], locals = [
        ("items", ref("Vals", True)),  # nullable: assigned inside if/else, used after
        ("n", I32),
        ("i", I32),
        ("j", I32),
        ("d", DICT),
        ("k", V),
    ], body = [
        if_(is_null(v), [str_("<unbound>"), "return"]),
        if_(ref_eq(v, gget("None")), [str_("None"), "return"]),
        if_(is_("Bool", v), [
            call("rt_buf_str", b, select_(field("Bool", "v", as_("Bool", v)), S(m, "True"), S(m, "False"), STR)),
            "return",
        ]),
        if_(is_("Big", v), [call("rt_buf_bigradix", b, v, i32(10), i32(0)), "return"]),
        if_(call("rt_is_int", v), [call("rt_buf_i64", b, call("rt_i64", v)), "return"]),
        if_(is_("Float", v), [call("rt_buf_float", b, field("Float", "v", as_("Float", v)), i32(103)), "return"]),  # 'g' 
        if_(is_("Str", v), [
            if_(get("quote"), call("rt_buf_repr_str", b, as_("Str", v)), call("rt_buf_str", b, as_("Str", v))),
            "return",
        ]),
        if_(or_(is_("List", v), is_("Tuple", v)), [
            if_(is_("List", v), [
                if_(call("rt_repr_enter", v), [str_("[...]"), "return"]),
                set("items", field("List", "items", as_("List", v))),
                set("n", field("List", "len", as_("List", v))),
                byte(91),  # [
            ], [
                set("items", field("Tuple", "items", as_("Tuple", v))),
                set("n", arr_len(get("items"))),
                byte(40),  # (
            ]),
            for_i32("i", i32(0), get("n"), [
                if_(get("i"), str_(", ")),
                call("rt_buf_value", b, arr_get("Vals", get("items"), get("i")), i32(1)),
            ]),
            if_(is_("List", v), [byte(93), call("rt_repr_leave")], [  # ]
                if_(op("i32.eq", get("n"), i32(1)), byte(44)),  # 1-tuple: (x,)
                byte(41),  # )
            ]),
            "return",
        ]),
        if_(is_("Dict", v), [
            if_(call("rt_repr_enter", v), [str_("{...}"), "return"]),
            set("d", as_("Dict", v)),
            byte(123),  # {
            set("j", i32(0)),
            for_i32("i", i32(0), field("Dict", "used", get("d")), [
                set("k", arr_get("Vals", field("Dict", "keys", get("d")), get("i"))),
                if_(eqz(is_null(get("k"))), [
                    if_(get("j"), str_(", ")),
                    call("rt_buf_value", b, get("k"), i32(1)),
                    str_(": "),
                    call("rt_buf_value", b, arr_get("Vals", field("Dict", "vals", get("d")), get("i")), i32(1)),
                    inc("j"),
                ]),
            ]),
            byte(125),  # }
            call("rt_repr_leave"),
            "return",
        ]),
        if_(is_("Set", v), [
            str_("set(["),
            set("d", field("Set", "d", as_("Set", v))),
            set("j", i32(0)),
            for_i32("i", i32(0), field("Dict", "used", get("d")), [
                set("k", arr_get("Vals", field("Dict", "keys", get("d")), get("i"))),
                if_(eqz(is_null(get("k"))), [
                    if_(get("j"), str_(", ")),
                    call("rt_buf_value", b, get("k"), i32(1)),
                    inc("j"),
                ]),
            ]),
            str_("])"),
            "return",
        ]),
        if_(is_("Func", v), [
            if_(field("Sig", "kind", field("Func", "sig", as_("Func", v))), str_("<built-in function "), str_("<function ")),
            call("rt_buf_str", b, field("Sig", "name", field("Func", "sig", as_("Func", v)))),
            byte(62),  # >
            "return",
        ]),
        if_(is_("Bytes", v), [
            # print() writes the raw bytes; repr (and str() of containers) quotes
            if_(get("quote"), call("rt_buf_repr_u8", b, field("Bytes", "b", as_("Bytes", v)), i32(1)),
                call("rt_buf_bytes", b, field("Bytes", "b", as_("Bytes", v)), i32(0), arr_len(field("Bytes", "b", as_("Bytes", v))))),
            "return",
        ]),
        if_(is_("Struct", v), [
            str_("struct("),
            set("d", field("Struct", "d", as_("Struct", v))),
            set("j", i32(0)),
            for_i32("i", i32(0), field("Dict", "used", get("d")), [
                set("k", arr_get("Vals", field("Dict", "keys", get("d")), get("i"))),
                if_(eqz(is_null(get("k"))), [
                    if_(get("j"), str_(", ")),
                    call("rt_buf_value", b, get("k"), i32(0)),
                    str_(" = "),
                    call("rt_buf_value", b, arr_get("Vals", field("Dict", "vals", get("d")), get("i")), i32(1)),
                    inc("j"),
                ]),
            ]),
            byte(41),  # )
            "return",
        ]),
        if_(is_("Range", v), [
            # range(stop), range(start, stop) or range(start, stop, step)
            str_("range("),
            if_(or_(op("i64.ne", field("Range", "start", as_("Range", v)), i64(0)), op("i64.ne", field("Range", "step", as_("Range", v)), i64(1))), [
                call("rt_buf_i64", b, field("Range", "start", as_("Range", v))),
                str_(", "),
            ]),
            call("rt_buf_i64", b, field("Range", "stop", as_("Range", v))),
            if_(op("i64.ne", field("Range", "step", as_("Range", v)), i64(1)), [
                str_(", "),
                call("rt_buf_i64", b, field("Range", "step", as_("Range", v))),
            ]),
            byte(41),
            "return",
        ]),
        if_(is_("Lazy", v), [
            # "abc".elems()
            set("j", field("Lazy", "kind", as_("Lazy", v))),
            call("rt_buf_repr_u8", b, field("Str", "b", field("Lazy", "s", as_("Lazy", v))), op("i32.eq", get("j"), i32(LAZY_BYTES_ELEMS))),
            if_(op("i32.eq", get("j"), i32(LAZY_ELEM_ORDS)), str_(".elem_ords()"),
            if_(op("i32.eq", get("j"), i32(LAZY_CODEPOINTS)), str_(".codepoints()"),
            if_(op("i32.eq", get("j"), i32(LAZY_CODEPOINT_ORDS)), str_(".codepoint_ords()"), str_(".elems()")))),
            "return",
        ]),
        if_(is_("Bound", v), [
            str_("<built-in method "),
            call("rt_buf_str", b, field("Bound", "name", as_("Bound", v))),
            str_(" of "),
            call("rt_buf_str", b, call("rt_type", field("Bound", "recv", as_("Bound", v)))),
            str_(" value>"),
            "return",
        ]),
        str_("<?>"),
    ])

    add_func(m, "rt_str", [("v", V)], [STR], locals = [("b", BUF)], body = [
        if_(is_("Str", v), ret(as_("Str", v))),
        if_(is_("Bytes", v), ret(call("rt_bytes_str", field("Bytes", "b", as_("Bytes", v))))),
        set("b", call("rt_buf_new")),
        call("rt_buf_value", b, v, i32(0)),
        call("rt_buf_to_str", b),
    ])

    add_func(m, "rt_repr", [("v", V)], [STR], locals = [("b", BUF)], body = [
        set("b", call("rt_buf_new")),
        call("rt_buf_value", b, v, i32(1)),
        call("rt_buf_to_str", b),
    ])

    add_func(m, "rt_print", [("v", V)], [], locals = [("b", BUF)], body = [
        set("b", call("rt_buf_new")),
        call("rt_buf_value", b, v, i32(0)),
        byte(10),
        call("rt_buf_write", b, i32(1)),
    ])

# ---------------------------------------------------------------- entry point

def add_runtime(m, test = False):
    """Add the Starlark runtime to module m. Call before defining other
    functions (it declares the host imports, which must come first).
    test: also declare the imports used by add_test_builtins."""
    _declare(m, test)
    _buffers(m)
    _basics(m)
    _ints(m)
    _unicode(m)
    _magnitudes(m)
    _bigints(m)
    _floats(m)
    _strings(m)
    _compare(m)
    _dicts(m)
    _sets(m)
    _lazy(m)
    _sequences(m)
    _generic(m)
    _printing(m)
