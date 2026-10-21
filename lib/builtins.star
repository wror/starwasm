# builtins.star — runtime support used by compiled code: builtin
# functions, methods, and helpers for statements (unpacking, +=, slicing,
# unbound-variable errors). Call add_builtins(m) after add_runtime(m).
#
# Methods are rt_m_<name>(receiver, arg1, ..., argN); the compiler passes
# ref.null for omitted optional arguments.

load("wasm.star", "EQREF", "I32", "I64", "add_func", "add_global", "ref")
load(
    "dsl.star",
    "and_",
    "arr_copy",
    "arr_fixed",
    "arr_get",
    "arr_get_u",
    "arr_len",
    "arr_new_default",
    "arr_set",
    "as_",
    "br",
    "br_if",
    "call",
    "drop",
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
load(
    "runtime.star",
    "check_mutable",
    "LAZY_BYTES_ELEMS",
    "LAZY_CODEPOINTS",
    "LAZY_CODEPOINT_ORDS",
    "LAZY_ELEMS",
    "LAZY_ELEM_ORDS",
    "S",
    "bstr",
    "fail_",
    "str_bytes",
    "type_err1",
)

V = EQREF
STR = ref("Str")
LIST = ref("List")
DICT = ref("Dict")
BUF = ref("Buf")
VALS = ref("Vals")
U8A = ref("U8")

def _absent(v):
    """i32: optional argument omitted (null) or None."""
    return or_(is_null(v), ref_eq(v, gget("None")))

def _items(v):
    return field("Tuple", "items", v)

def _misc(m):
    a, b = get("a"), get("b")
    P = [("a", V), ("b", V)]
    # Ordered types: ints, strings, lists, tuples, bools (same type on both
    # sides); sets are ordered by inclusion.
    add_func(m, "rt_comparable", P, [I32], [
        if_(and_(is_("Bool", a), is_("Bool", b)), ret(i32(1))),
        or_(and_(call("rt_is_num", a), call("rt_is_num", b)),
            or_(and_(is_("Str", a), is_("Str", b)),
                or_(and_(is_("List", a), is_("List", b)),
                    or_(and_(is_("Tuple", a), is_("Tuple", b)),
                        or_(and_(is_("Set", a), is_("Set", b)), and_(is_("Bytes", a), is_("Bytes", b))))))),
    ])

    def subset(x, y):
        return call("rt_set_subset", as_("Set", x), as_("Set", y))

    for name, sym, code, setcode in [
        ("rt_gt", " > ", call("rt_lt", b, a), call("rt_lt", b, a)),
        ("rt_le", " <= ", eqz(call("rt_lt", b, a)), subset(a, b)),
        ("rt_ge", " >= ", eqz(call("rt_lt", a, b)), subset(b, a)),
    ]:
        add_func(m, name, P, [I32], [
            if_(eqz(call("rt_comparable", a, b)), [S(m, ""), a, S(m, sym), b, S(m, " not implemented"), call("rt_fail_type2"), "unreachable"]),
            if_(is_("Set", a), ret(setcode)),  # not a total order: no deriving from <
            code,
        ])

    for kind in ["local", "global"]:
        add_func(m, "rt_unbound_" + kind, [("name", STR)], [], locals = [("b", BUF)], body = [
            set("b", call("rt_buf_new")),
            call("rt_buf_str", get("b"), S(m, kind + " variable ")),
            call("rt_buf_str", get("b"), get("name")),
            call("rt_buf_str", get("b"), S(m, " referenced before assignment")),
            call("rt_fail", call("rt_buf_to_str", get("b"))),
        ])

    # print(*args, sep=" "): str() of each, separated by sep (null: a
    # space), then a newline.
    add_func(m, "rt_print_args", [("items", VALS), ("sep", V)], [], locals = [("b", BUF), ("i", I32)], body = [
        if_(eqz(or_(is_null(get("sep")), is_("Str", get("sep")))),
            type_err1(m, "print: for parameter \"sep\": got ", get("sep"), ", want string")),
        set("b", call("rt_buf_new")),
        for_i32("i", i32(0), arr_len(get("items")), [
            if_(get("i"), if_(is_null(get("sep")), call("rt_buf_byte", get("b"), i32(32)), call("rt_buf_str", get("b"), as_("Str", get("sep"))))),
            call("rt_buf_value", get("b"), arr_get("Vals", get("items"), get("i")), i32(0)),
        ]),
        call("rt_buf_byte", get("b"), i32(10)),
        call("rt_buf_write", get("b"), i32(1)),
    ])

    # fail(*args, sep=" "); sep null when omitted
    add_func(m, "rt_fail_args", [("items", VALS), ("sep", V)], [], locals = [("b", BUF), ("i", I32)], body = [
        if_(eqz(or_(is_null(get("sep")), is_("Str", get("sep")))),
            type_err1(m, "fail: for parameter \"sep\": got ", get("sep"), ", want string")),
        set("b", call("rt_buf_new")),
        call("rt_buf_str", get("b"), S(m, "fail: ")),
        for_i32("i", i32(0), arr_len(get("items")), [
            if_(get("i"), if_(is_null(get("sep")), call("rt_buf_byte", get("b"), i32(32)), call("rt_buf_str", get("b"), as_("Str", get("sep"))))),
            call("rt_buf_value", get("b"), arr_get("Vals", get("items"), get("i")), i32(0)),
        ]),
        call("rt_fail", call("rt_buf_to_str", get("b"))),
    ])

    # Elements of x for `a, b = x`, checked to be exactly n.
    add_func(m, "rt_unpack", [("x", V), ("n", I32)], [VALS], locals = [
        ("k", I32),
        ("items", ref("Vals", True)),
        ("b", ref("Buf", True)),
    ], body = [
        if_(is_("List", get("x")), [
            set("k", field("List", "len", as_("List", get("x")))),
            set("items", field("List", "items", as_("List", get("x")))),
        ], if_(is_("Tuple", get("x")), [
            set("items", _items(as_("Tuple", get("x")))),
            set("k", arr_len(get("items"))),
        ], if_(or_(or_(is_("Range", get("x")), is_("Lazy", get("x"))), or_(is_("Dict", get("x")), is_("Set", get("x")))), [
            set("items", _items(call("rt_iter", get("x")))),
            set("k", arr_len(get("items"))),
        ], type_err1(m, "got ", get("x"), " in sequence assignment")))),
        if_(op("i32.ne", get("k"), get("n")), [
            set("b", call("rt_buf_new")),
            call("rt_buf_str", non_null(get("b")), select_(op("i32.gt_s", get("k"), get("n")),
                 S(m, "too many values to unpack (got "), S(m, "too few values to unpack (got "), STR)),
            call("rt_buf_i64", non_null(get("b")), op("i64.extend_i32_s", get("k"))),
            call("rt_buf_str", non_null(get("b")), S(m, ", want ")),
            call("rt_buf_i64", non_null(get("b")), op("i64.extend_i32_s", get("n"))),
            call("rt_buf_byte", non_null(get("b")), i32(41)),
            call("rt_fail", call("rt_buf_to_str", non_null(get("b")))),
        ]),
        non_null(get("items")),
    ])

    add_func(m, "rt_list_extend", [("l", LIST), ("x", V)], [], locals = [("t", VALS), ("i", I32)], body = [
        set("t", _items(call("rt_iter", get("x")))),  # snapshot, so l.extend(l) works
        for_i32("i", i32(0), arr_len(get("t")), [
            call("rt_list_append", get("l"), arr_get("Vals", get("t"), get("i"))),
        ]),
    ])

    # x += y: lists are extended in place; everything else is x = x + y.
    add_func(m, "rt_iadd", P, [V], [
        if_(is_("List", a), [
            if_(op("i32.shr_u", field("List", "frozen", as_("List", a)), i32(1)), fail_(m, "cannot apply += to list during iteration")),
            call("rt_list_extend", as_("List", a), b),
            ret(a),
        ]),
        call("rt_add", a, b),
    ])

    # x |= y: for dicts, update x in place (as starlark-go); else x | y.
    add_func(m, "rt_ior", P, [V], locals = [("x", ref("Dict", True)), ("y", ref("Dict", True)), ("i", I32), ("k", V)], body = [
        if_(and_(is_("Dict", a), is_("Dict", b)), [
            set("x", as_("Dict", a)),
            set("y", as_("Dict", b)),
            check_mutable(m, field("Dict", "frozen", get("x")), "cannot apply |= to frozen hash table", "cannot apply |= to hash table during iteration"),
            for_i32("i", i32(0), field("Dict", "used", get("y")), [
                set("k", arr_get("Vals", field("Dict", "keys", get("y")), get("i"))),
                if_(eqz(is_null(get("k"))), call("rt_dict_set", non_null(get("x")), get("k"), arr_get("Vals", field("Dict", "vals", get("y")), get("i")))),
            ]),
            ret(a),
        ]),
        call("rt_or", a, b),
    ])

    add_func(m, "rt_dict_from_pairs", [("kv", VALS)], [DICT], locals = [("d", DICT), ("i", I32)], body = [
        set("d", call("rt_dict_new")),
        set("i", i32(0)),
        while_(op("i32.lt_s", get("i"), arr_len(get("kv"))), [
            call("rt_dict_set", get("d"), arr_get("Vals", get("kv"), get("i")),
                 arr_get("Vals", get("kv"), op("i32.add", get("i"), i32(1)))),
            inc("i", 2),
        ]),
        get("d"),
    ])

    # Remove key k; returns its value, or null if absent. Leaves a tombstone.
    add_func(m, "rt_dict_delete", [("d", DICT), ("k", V)], [V], locals = [("e", I32), ("v", V)], body = [
        check_mutable(m, field("Dict", "frozen", get("d")), "cannot delete from frozen hash table", "cannot delete from hash table during iteration"),
        set("e", call("rt_dict_find", get("d"), get("k"), call("rt_hash", get("k")))),
        if_(op("i32.lt_s", get("e"), i32(0)), ret(null("eq"))),
        set("v", arr_get("Vals", field("Dict", "vals", get("d")), get("e"))),
        arr_set("Vals", field("Dict", "keys", get("d")), get("e"), null("eq")),
        arr_set("Vals", field("Dict", "vals", get("d")), get("e"), null("eq")),
        setfield("Dict", "len", get("d"), op("i32.sub", field("Dict", "len", get("d")), i32(1))),
        get("v"),
    ])

def _slicing(m):
    # Resolve one slice bound: default when absent; negative counts from
    # the end; then clamp to [lo, hi].
    # A slice index or step as starlark-go's AsInt32 (an int, not too big),
    # errors prefixed by what ("invalid start index: " etc.).
    add_func(m, "rt_slice_int", [("v", V), ("what", STR)], [I64], [
        if_(eqz(call("rt_is_int", get("v"))), [
            call("rt_fail", call("rt_str_concat", get("what"), call("rt_str_concat", call("rt_str_concat", S(m, "got "), call("rt_type", get("v"))), S(m, ", want int")))),
        ]),
        if_(or_(eqz(call("rt_is_small", get("v"))), call("rt_out_of_i32", call("rt_i64", get("v")))), [
            call("rt_fail", call("rt_str_concat", get("what"), call("rt_str_concat", call("rt_str", get("v")), S(m, " out of range")))),
        ]),
        call("rt_i64", get("v")),
    ])

    add_func(m, "rt_slice_bound", [("v", V), ("dflt", I64), ("n", I64), ("lo", I64), ("hi", I64), ("what", STR)], [I64], locals = [("i", I64)], body = [
        if_(_absent(get("v")), ret(get("dflt"))),
        set("i", call("rt_slice_int", get("v"), get("what"))),
        if_(op("i64.lt_s", get("i"), i64(0)), set("i", op("i64.add", get("i"), get("n")))),
        if_(op("i64.lt_s", get("i"), get("lo")), set("i", get("lo"))),
        if_(op("i64.gt_s", get("i"), get("hi")), set("i", get("hi"))),
        get("i"),
    ])

    add_func(m, "rt_slice", [("x", V), ("lo", V), ("hi", V), ("step", V)], [V], locals = [
        ("n", I64),
        ("st", I64),
        ("a", I64),
        ("z", I64),
        ("cnt", I32),
        ("k", I32),
        ("ob", U8A),
        ("src", U8A),
        ("out", VALS),
        ("items", ref("Vals", True)),
    ], body = [
        if_(is_("Bytes", get("x")), ret(str_bytes(as_("Str", call("rt_slice", bstr(get("x")), get("lo"), get("hi"), get("step")))))),
        if_(eqz(or_(or_(is_("Str", get("x")), is_("Range", get("x"))), or_(is_("List", get("x")), is_("Tuple", get("x"))))),
            type_err1(m, "invalid slice operand ", get("x"), "")),
        set("n", op("i64.extend_i32_s", call("rt_len_i32", get("x")))),
        set("st", select_(_absent(get("step")), i64(1), call("rt_slice_int", get("step"), S(m, "invalid slice step: ")), I64)),
        if_(op("i64.eqz", get("st")), fail_(m, "zero is not a valid slice step")),
        if_(op("i64.gt_s", get("st"), i64(0)), [
            set("a", call("rt_slice_bound", get("lo"), i64(0), get("n"), i64(0), get("n"), S(m, "invalid start index: "))),
            set("z", call("rt_slice_bound", get("hi"), get("n"), get("n"), i64(0), get("n"), S(m, "invalid end index: "))),
            set("cnt", select_(op("i64.gt_s", get("z"), get("a")),
                               op("i32.wrap_i64", op("i64.div_s", op("i64.add", op("i64.sub", get("z"), get("a")), op("i64.sub", get("st"), i64(1))), get("st"))),
                               i32(0), I32)),
        ], [
            set("a", call("rt_slice_bound", get("lo"), op("i64.sub", get("n"), i64(1)), get("n"), i64(-1), op("i64.sub", get("n"), i64(1)), S(m, "invalid start index: "))),
            set("z", call("rt_slice_bound", get("hi"), i64(-1), get("n"), i64(-1), op("i64.sub", get("n"), i64(1)), S(m, "invalid end index: "))),
            set("cnt", select_(op("i64.gt_s", get("a"), get("z")),
                               op("i32.wrap_i64", op("i64.div_s", op("i64.sub", op("i64.sub", get("a"), get("z")), op("i64.add", get("st"), i64(1))), op("i64.sub", i64(0), get("st")))),
                               i32(0), I32)),
        ]),
        # a slice of a range is a range (starlark-go): bounds a and z, scaled
        if_(is_("Range", get("x")), ret(new(
            "Range",
            op("i64.add", field("Range", "start", as_("Range", get("x"))), op("i64.mul", get("a"), field("Range", "step", as_("Range", get("x"))))),
            op("i64.add", field("Range", "start", as_("Range", get("x"))), op("i64.mul", get("z"), field("Range", "step", as_("Range", get("x"))))),
            op("i64.mul", get("st"), field("Range", "step", as_("Range", get("x")))),
        ))),
        if_(is_("Str", get("x")), [
            set("src", field("Str", "b", as_("Str", get("x")))),
            set("ob", arr_new_default("U8", get("cnt"))),
            for_i32("k", i32(0), get("cnt"), [
                arr_set("U8", get("ob"), get("k"), arr_get_u("U8", get("src"), op("i32.wrap_i64", op(
                    "i64.add", get("a"), op("i64.mul", op("i64.extend_i32_s", get("k")), get("st")))))),
            ]),
            ret(new("Str", i32(0), get("ob"))),
        ]),
        set("items", select_(is_("List", get("x")),
                             field("List", "items", as_("List", get("x"))),
                             _items(as_("Tuple", get("x"))), ref("Vals", True))),
        set("out", arr_new_default("Vals", get("cnt"))),
        for_i32("k", i32(0), get("cnt"), [
            arr_set("Vals", get("out"), get("k"), arr_get("Vals", get("items"), op("i32.wrap_i64", op(
                "i64.add", get("a"), op("i64.mul", op("i64.extend_i32_s", get("k")), get("st")))))),
        ]),
        if_(is_("List", get("x")), ret(new("List", get("cnt"), get("out"), i32(0)))),
        new("Tuple", get("out")),
    ])

def _conversions(m):
    x = get("x")

    # One argument of range(): an int, or "range: for parameter <i>: ...".
    add_func(m, "rt_range_arg", [("v", V), ("i", I32)], [I64], locals = [("b", BUF)], body = [
        if_(call("rt_is_small", get("v")), ret(call("rt_i64", get("v")))),
        if_(is_("Big", get("v")), [
            set("b", call("rt_buf_new")),
            call("rt_buf_str", get("b"), S(m, "range: for parameter ")),
            call("rt_buf_i64", get("b"), op("i64.extend_i32_s", get("i"))),
            call("rt_buf_str", get("b"), S(m, ": ")),
            call("rt_buf_value", get("b"), get("v"), i32(0)),
            call("rt_buf_str", get("b"), S(m, " out of range (want value in signed 64-bit range)")),
            call("rt_fail", call("rt_buf_to_str", get("b"))),
        ]),
        set("b", call("rt_buf_new")),
        call("rt_buf_str", get("b"), S(m, "range: for parameter ")),
        call("rt_buf_i64", get("b"), op("i64.extend_i32_s", get("i"))),
        call("rt_buf_str", get("b"), S(m, ": got ")),
        call("rt_buf_str", get("b"), call("rt_type", get("v"))),
        call("rt_buf_str", get("b"), S(m, ", want int")),
        call("rt_fail", call("rt_buf_to_str", get("b"))),
        "unreachable",
    ])

    # range(lo, hi, step) called with nargs arguments (lo = 0 and step = 1
    # when omitted): a lazy $Range.
    add_func(m, "rt_range", [("lo", V), ("hi", V), ("step", V), ("nargs", I32)], [V], locals = [("s", I64)], body = [
        set("s", call("rt_range_arg", get("step"), i32(3))),
        if_(op("i64.eqz", get("s")), fail_(m, "range: step argument must not be zero")),
        new("Range",
            call("rt_range_arg", get("lo"), i32(1)),
            call("rt_range_arg", get("hi"), select_(op("i32.eq", get("nargs"), i32(1)), i32(1), i32(2), I32)),
            get("s")),
    ])

    add_func(m, "rt_int_of", [("x", V)], [V], locals = [
        ("b", U8A),
        ("i", I32),
        ("n", I32),
        ("c", I32),
        ("neg", I32),
        ("mag", ref("I32A")),
    ], body = [
        if_(call("rt_is_int", x), ret(x)),
        if_(is_("Float", x), ret(call("rt_float_to_int", field("Float", "v", as_("Float", x)), S(m, "int: ")))),
        if_(is_("Bool", x), ret(op("ref.i31", field("Bool", "v", as_("Bool", x))))),
        if_(eqz(is_("Str", x)), type_err1(m, "int: cannot convert ", x, " to int")),
        set("b", field("Str", "b", as_("Str", x))),
        set("n", arr_len(get("b"))),
        set("i", i32(0)),
        set("neg", i32(0)),
        if_(get("n"), [
            set("c", arr_get_u("U8", get("b"), i32(0))),
            if_(or_(op("i32.eq", get("c"), i32(45)), op("i32.eq", get("c"), i32(43))), [
                set("neg", op("i32.eq", get("c"), i32(45))),
                set("i", i32(1)),
            ]),
        ]),
        if_(op("i32.ge_s", get("i"), get("n")), call("rt_fail", call("rt_str_concat", S(m, "int: invalid literal with base 10: "), as_("Str", x)))),
        set("mag", arr_new_default("I32A", i32(0))),
        while_(op("i32.lt_s", get("i"), get("n")), [
            set("c", op("i32.sub", arr_get_u("U8", get("b"), get("i")), i32(48))),
            if_(op("i32.gt_u", get("c"), i32(9)), call("rt_fail", call("rt_str_concat", S(m, "int: invalid literal with base 10: "), as_("Str", x)))),
            set("mag", call("rt_mag_muladd", get("mag"), i64(10), op("i64.extend_i32_u", get("c")))),
            inc("i"),
        ]),
        call("rt_big_make", get("neg"), get("mag")),
    ])

    # "list: for parameter 1: got int, want iterable" unless x is iterable
    add_func(m, "rt_want_iterable", [("x", V), ("name", STR)], [], locals = [("b", BUF)], body = [
        if_(or_(or_(or_(is_("List", x), is_("Tuple", x)), or_(is_("Dict", x), is_("Set", x))), or_(is_("Range", x), is_("Lazy", x))), "return"),
        set("b", call("rt_buf_new")),
        call("rt_buf_str", get("b"), get("name")),
        call("rt_buf_str", get("b"), S(m, ": for parameter 1: got ")),
        call("rt_buf_str", get("b"), call("rt_type", x)),
        call("rt_buf_str", get("b"), S(m, ", want iterable")),
        call("rt_fail", call("rt_buf_to_str", get("b"))),
    ])

    add_func(m, "rt_tuple_of", [("x", V)], [V], [
        call("rt_want_iterable", x, S(m, "tuple")),
        call("rt_iter", x),
    ])

    # float(x)
    add_func(m, "rt_float_of", [("x", V)], [V], [
        if_(is_("Float", x), ret(x)),
        if_(call("rt_is_int", x), ret(call("rt_float", call("rt_f64", x)))),
        if_(is_("Bool", x), ret(call("rt_float", op("f64.convert_i64_s", op("i64.extend_i32_u", field("Bool", "v", as_("Bool", x))))))),
        if_(is_("Str", x), ret(call("rt_parse_float", as_("Str", x)))),
        type_err1(m, "float got ", x, ", want number or string"),
    ])

    add_func(m, "rt_list_of", [("x", V)], [V], locals = [("t", VALS)], body = [
        call("rt_want_iterable", x, S(m, "list")),
        set("t", _items(call("rt_iter", x))),
        new("List", arr_len(get("t")), call("rt_vals_concat", get("t"), arr_len(get("t")), arr_new_default("Vals", i32(0)), i32(0)), i32(0)),
    ])

    # enumerate(x, start = 0); start null when omitted
    add_func(m, "rt_enumerate", [("x", V), ("start", V)], [V], locals = [("t", VALS), ("out", LIST), ("i", I32), ("s", I64)], body = [
        call("rt_want_iterable", x, S(m, "enumerate")),
        set("s", i64(0)),
        if_(eqz(is_null(get("start"))), [
            if_(eqz(call("rt_is_small", get("start"))), type_err1(m, "enumerate: for parameter 2: got ", get("start"), ", want int")),
            set("s", call("rt_i64", get("start"))),
        ]),
        set("t", _items(call("rt_iter", x))),
        set("out", call("rt_list_new", arr_len(get("t")))),
        for_i32("i", i32(0), arr_len(get("t")), [
            call("rt_list_append", get("out"), new("Tuple", arr_fixed(
                "Vals",
                call("rt_add", call("rt_int", get("s")), call("rt_int", op("i64.extend_i32_s", get("i")))),
                arr_get("Vals", get("t"), get("i")),
            ))),
        ]),
        get("out"),
    ])

    add_func(m, "rt_abs", [("x", V)], [V], [
        if_(is_("Float", x), ret(new("Float", op("f64.abs", field("Float", "v", as_("Float", x)))))),
        if_(is_("Big", x), ret(call("rt_big_make", i32(0), field("Big", "mag", as_("Big", x))))),
        if_(eqz(call("rt_is_small", x)), type_err1(m, "got ", x, ", want int or float")),
        if_(op("i64.lt_s", call("rt_i64", x), i64(0)), ret(call("rt_neg", x))),
        x,
    ])

    # ord(s): the single Unicode code point that s encodes in UTF-8.
    add_func(m, "rt_ord", [("x", V)], [V], locals = [
        ("b", U8A),
        ("n", I32),
        ("k", I32),
        ("cp", I32),
        ("i", I32),
    ], body = [
        # ord(bytes): the sole byte
        if_(is_("Bytes", x), [
            set("b", field("Str", "b", bstr(x))),
            if_(op("i32.ne", arr_len(get("b")), i32(1)), call("rt_fail", call("rt_str_concat", call("rt_str_concat",
                S(m, "ord: bytes has length "), call("rt_str", op("ref.i31", arr_len(get("b"))))), S(m, ", want 1")))),
            ret(op("ref.i31", arr_get_u("U8", get("b"), i32(0)))),
        ]),
        if_(eqz(is_("Str", x)), type_err1(m, "ord: got ", x, ", want string or bytes")),
        set("b", field("Str", "b", as_("Str", x))),
        set("n", arr_len(get("b"))),
        if_(eqz(get("n")), fail_(m, "ord: string encodes 0 Unicode code points, want 1")),
        # the first rune as Go's utf8.DecodeRuneInString: an invalid byte is U+FFFD
        set("k", call("rt_utf8_seq", get("b"), i32(0), get("n"))),
        if_(get("k"), set("cp", call("rt_utf8_rune", get("b"), i32(0), get("k"))), [set("cp", i32(0xfffd)), set("k", i32(1))]),
        if_(op("i32.ne", get("n"), get("k")), [
            # count runes as utf8.RuneCountInString (each invalid byte is one)
            set("cp", i32(0)),
            set("i", i32(0)),
            while_(op("i32.lt_s", get("i"), get("n")), [
                set("k", call("rt_utf8_seq", get("b"), get("i"), get("n"))),
                if_(eqz(get("k")), set("k", i32(1))),
                set("i", op("i32.add", get("i"), get("k"))),
                inc("cp"),
            ]),
            call("rt_fail", call("rt_str_concat", call("rt_str_concat", S(m, "ord: string encodes "),
                 call("rt_str", op("ref.i31", get("cp")))), S(m, " Unicode code points, want 1"))),
        ]),
        op("ref.i31", get("cp")),
    ])

    # chr(i): UTF-8 encoding of code point i.
    add_func(m, "rt_chr", [("x", V)], [V], locals = [("cp", I64), ("c", I32), ("b", BUF)], body = [
        # as starlark-go: AsInt32 first ("chr: N out of range")
        if_(is_("Big", x), call("rt_fail", call("rt_str_concat", call("rt_str_concat", S(m, "chr: "), call("rt_str", x)), S(m, " out of range")))),
        set("cp", call("rt_i64", x)),
        if_(op("i64.ne", op("i64.extend_i32_s", op("i32.wrap_i64", get("cp"))), get("cp")),
            call("rt_fail", call("rt_str_concat", call("rt_str_concat", S(m, "chr: "), call("rt_str", x)), S(m, " out of range")))),
        if_(op("i64.lt_s", get("cp"), i64(0)), call("rt_fail", call("rt_str_concat", call("rt_str_concat",
            S(m, "chr: Unicode code point "), call("rt_str", x)), S(m, " out of range (<0)")))),
        if_(op("i64.gt_s", get("cp"), i64(0x10ffff)), [
            set("b", call("rt_buf_new")),
            call("rt_buf_str", get("b"), S(m, "chr: Unicode code point U+")),
            call("rt_buf_radix", get("b"), get("cp"), i32(16), i32(1)),
            call("rt_buf_str", get("b"), S(m, " out of range (>0x10FFFF)")),
            call("rt_fail", call("rt_buf_to_str", get("b"))),
        ]),
        set("c", op("i32.wrap_i64", get("cp"))),
        set("b", call("rt_buf_new")),
        if_(op("i32.lt_u", get("c"), i32(0x80)), call("rt_buf_byte", get("b"), get("c")),
        if_(op("i32.lt_u", get("c"), i32(0x800)), [
            call("rt_buf_byte", get("b"), op("i32.or", i32(0xc0), op("i32.shr_u", get("c"), i32(6)))),
            call("rt_buf_byte", get("b"), op("i32.or", i32(0x80), op("i32.and", get("c"), i32(63)))),
        ], if_(op("i32.lt_u", get("c"), i32(0x10000)), [
            call("rt_buf_byte", get("b"), op("i32.or", i32(0xe0), op("i32.shr_u", get("c"), i32(12)))),
            call("rt_buf_byte", get("b"), op("i32.or", i32(0x80), op("i32.and", op("i32.shr_u", get("c"), i32(6)), i32(63)))),
            call("rt_buf_byte", get("b"), op("i32.or", i32(0x80), op("i32.and", get("c"), i32(63)))),
        ], [
            call("rt_buf_byte", get("b"), op("i32.or", i32(0xf0), op("i32.shr_u", get("c"), i32(18)))),
            call("rt_buf_byte", get("b"), op("i32.or", i32(0x80), op("i32.and", op("i32.shr_u", get("c"), i32(12)), i32(63)))),
            call("rt_buf_byte", get("b"), op("i32.or", i32(0x80), op("i32.and", op("i32.shr_u", get("c"), i32(6)), i32(63)))),
            call("rt_buf_byte", get("b"), op("i32.or", i32(0x80), op("i32.and", get("c"), i32(63)))),
        ]))),
        call("rt_buf_to_str", get("b")),
    ])

def _files(m):
    # Copy src[start:start+n] (n <= 64 KiB) to linear memory at 0.
    add_func(m, "rt_mem_put", [("src", U8A), ("start", I32), ("n", I32)], [], locals = [("i", I32)], body = [
        for_i32("i", i32(0), get("n"), [
            get("i"),
            arr_get_u("U8", get("src"), op("i32.add", get("start"), get("i"))),
            ("i32.store8", 0),
        ]),
    ])

    # Fresh byte array holding linear memory [0, n).
    add_func(m, "rt_mem_take", [("n", I32)], [U8A], locals = [("a", U8A), ("i", I32)], body = [
        set("a", arr_new_default("U8", get("n"))),
        for_i32("i", i32(0), get("n"), [
            arr_set("U8", get("a"), get("i"), [get("i"), ("i32.load8_u", 0)]),
        ]),
        get("a"),
    ])

    # Stage a path string in memory; returns its length.
    add_func(m, "rt_put_path", [("path", V)], [I32], locals = [("b", U8A)], body = [
        if_(eqz(is_("Str", get("path"))), type_err1(m, "file path: got ", get("path"), ", want string")),
        set("b", field("Str", "b", as_("Str", get("path")))),
        if_(op("i32.gt_s", arr_len(get("b")), i32(65536)), fail_(m, "file path too long")),
        call("rt_mem_put", get("b"), i32(0), arr_len(get("b"))),
        arr_len(get("b")),
    ])

    add_func(m, "rt_read_file", [("path", V)], [V], locals = [
        ("size", I32),
        ("off", I32),
        ("k", I32),
        ("a", U8A),
        ("i", I32),
        ("b", BUF),
    ], body = [
        set("size", call("host_file_size", i32(0), call("rt_put_path", get("path")))),
        if_(op("i32.lt_s", get("size"), i32(0)), [
            set("b", call("rt_buf_new")),
            call("rt_buf_str", get("b"), S(m, "read_file: cannot read ")),
            call("rt_buf_str", get("b"), as_("Str", get("path"))),
            call("rt_fail", call("rt_buf_to_str", get("b"))),
        ]),
        set("a", arr_new_default("U8", get("size"))),
        set("off", i32(0)),
        while_(op("i32.lt_s", get("off"), get("size")), [
            set("k", op("i32.sub", get("size"), get("off"))),
            if_(op("i32.gt_s", get("k"), i32(65536)), set("k", i32(65536))),
            call("host_file_chunk", get("off"), i32(0), get("k")),
            for_i32("i", i32(0), get("k"), [
                arr_set("U8", get("a"), op("i32.add", get("off"), get("i")), [get("i"), ("i32.load8_u", 0)]),
            ]),
            set("off", op("i32.add", get("off"), get("k"))),
        ]),
        new("Str", i32(0), get("a")),
    ])

    # write_file(path, data): data is a string or a list of ints 0..255.
    add_func(m, "rt_write_file", [("path", V), ("data", V)], [V], locals = [
        ("a", ref("U8", True)),  # assigned in if/else
        ("l", ref("List", True)),
        ("i", I32),
        ("x", I64),
    ], body = [
        call("host_out_begin", i32(0), call("rt_put_path", get("path"))),
        if_(is_("Str", get("data")), set("a", field("Str", "b", as_("Str", get("data")))),
        if_(is_("List", get("data")), [
            set("l", as_("List", get("data"))),
            set("a", arr_new_default("U8", field("List", "len", get("l")))),
            for_i32("i", i32(0), field("List", "len", get("l")), [
                set("x", call("rt_i64", arr_get("Vals", field("List", "items", get("l")), get("i")))),
                if_(op("i64.gt_u", get("x"), i64(255)), fail_(m, "write_file: list element is not a byte")),
                arr_set("U8", get("a"), get("i"), op("i32.wrap_i64", get("x"))),
            ]),
        ], type_err1(m, "write_file: got ", get("data"), ", want string or list of ints"))),
        call("rt_write_bytes", non_null(get("a")), arr_len(get("a")), i32(3)),
        call("host_out_end"),
        gget("None"),
    ])

    add_func(m, "rt_argv", [], [V], locals = [("out", LIST), ("i", I32), ("n", I32)], body = [
        set("out", call("rt_list_new", i32(0))),
        for_i32("i", i32(0), call("host_arg_count"), [
            set("n", call("host_arg_len", get("i"))),
            call("host_arg_copy", get("i"), i32(0)),
            call("rt_list_append", get("out"), new("Str", i32(0), call("rt_mem_take", get("n")))),
        ]),
        get("out"),
    ])

def _functions(m):
    add_global(m, "next_func_id", I32, True, [i32(0)])
    add_func(m, "rt_next_id", [], [I32], [
        gset("next_func_id", op("i32.add", gget("next_func_id"), i32(1))),
        gget("next_func_id"),
    ])

    # f(*args, **kwargs) for any callable value f. A bound method x.name
    # calls its function with x prepended to the arguments.
    add_func(m, "rt_call", [("f", V), ("args", VALS), ("kw", V)], [V], locals = [("a", VALS)], body = [
        if_(is_("Bound", get("f")), [
            set("a", arr_new_default("Vals", op("i32.add", arr_len(get("args")), i32(1)))),
            arr_set("Vals", get("a"), i32(0), field("Bound", "recv", as_("Bound", get("f")))),
            arr_copy("Vals", get("a"), i32(1), get("args"), i32(0), arr_len(get("args"))),
            set("args", get("a")),
            set("f", field("Bound", "fn", as_("Bound", get("f")))),
        ]),
        if_(eqz(is_("Func", get("f"))), type_err1(m, "invalid call of non-function (", get("f"), ")")),
        as_("Func", get("f")),
        get("args"),
        get("kw"),
        field("Func", "code", as_("Func", get("f"))),
        ("call_ref", "Code"),
    ])

    b = non_null(get("b"))  # nullable local: set inside if-branches

    def start_msg(sig):
        # starlark-go style: "function <name> ..."
        return [
            set("b", call("rt_buf_new")),
            call("rt_buf_str", b, S(m, "function ")),
            call("rt_buf_str", b, field("Sig", "name", sig)),
        ]

    def fail_named(sig, msg, extra):
        # "function <name> <msg><extra>"; extra is code for a Str, or None
        out = start_msg(sig) + [call("rt_buf_str", b, S(m, " " + msg))]
        if extra != None:
            out.append(call("rt_buf_str", b, extra))
        out.append(call("rt_fail", call("rt_buf_to_str", b)))
        return out

    def num(code):
        return call("rt_buf_i64", b, op("i64.extend_i32_s", code))

    def bmsg(sig, msg):
        # builtin style: "<name>: <msg>"
        return [
            set("b", call("rt_buf_new")),
            call("rt_buf_str", b, field("Sig", "name", sig)),
            call("rt_buf_str", b, S(m, ": " + msg)),
        ]

    def bfail():
        return [call("rt_fail", call("rt_buf_to_str", b)), "unreachable"]

    sig = get("sig")
    builtin = get("kind")  # i32: 0 for Starlark functions
    # Match a call's arguments to f's parameter slots (positional, *args,
    # keyword-only, **kwargs); fill defaults; report errors the way
    # starlark-go does: "function f ..." for Starlark functions, and for
    # builtins (Sig.kind 1: positional-only, 2: keywords too) the wording of
    # UnpackPositionalArgs / UnpackArgs, not counting a method's receiver.
    add_func(m, "rt_bind", [("f", ref("Func")), ("args", VALS), ("kw", V)], [VALS], locals = [
        ("sig", ref("Sig")),
        ("names", VALS),
        ("out", VALS),
        ("dflt", ref("Vals", True)),
        ("n", I32),
        ("npos", I32),
        ("va", I32),
        ("kwend", I32),
        ("total", I32),
        ("k", I32),
        ("i", I32),
        ("j", I32),
        ("s", I32),
        ("d", ref("Dict", True)),
        ("extra", ref("Dict", True)),
        ("key", V),
        ("b", ref("Buf", True)),
        ("extra_pos", VALS),
        ("kind", I32),
        ("recv", I32),
        ("minpos", I32),
        ("cands", ref("Vals", True)),
        ("hint", V),
    ], body = [
        set("sig", field("Func", "sig", get("f"))),
        set("names", field("Sig", "names", sig)),
        set("dflt", field("Func", "defaults", get("f"))),
        set("total", arr_len(get("names"))),
        set("out", arr_new_default("Vals", get("total"))),
        set("n", arr_len(get("args"))),
        set("npos", field("Sig", "npos", sig)),
        set("va", field("Sig", "varargs", sig)),
        set("kwend", op("i32.add", op("i32.add", get("npos"), get("va")), field("Sig", "nkw", sig))),
        set("kind", field("Sig", "kind", sig)),
        set("recv", field("Sig", "recv", sig)),

        # required positional parameters, besides a receiver
        set("minpos", i32(0)),
        for_i32("s", get("recv"), get("npos"), [
            if_(or_(is_null(get("dflt")), is_null(arr_get("Vals", non_null(get("dflt")), get("s")))), inc("minpos")),
        ]),
        if_(and_(op("i32.eq", get("kind"), i32(1)), eqz(is_null(get("kw")))), [
            if_(field("Dict", "len", as_("Dict", get("kw"))), [bmsg(sig, "unexpected keyword arguments"), bfail()]),
        ]),

        # positional arguments
        set("k", select_(op("i32.lt_s", get("n"), get("npos")), get("n"), get("npos"), I32)),
        arr_copy("Vals", get("out"), i32(0), get("args"), i32(0), get("k")),
        if_(op("i32.gt_s", get("n"), get("npos")), [
            if_(eqz(get("va")), [
                if_(builtin, [
                    # "split: got 3 arguments, want at most 2"
                    bmsg(sig, "got "),
                    num(op("i32.sub", get("n"), get("recv"))),
                    call("rt_buf_str", b, S(m, " arguments, want ")),
                    if_(or_(op("i32.eq", get("kind"), i32(2)), op("i32.lt_s", get("minpos"), op("i32.sub", get("npos"), get("recv")))),
                        call("rt_buf_str", b, S(m, "at most "))),
                    num(op("i32.sub", get("npos"), get("recv"))),
                    bfail(),
                ]),
                # "function f accepts 2 positional arguments (3 given)"
                start_msg(sig),
                if_(eqz(get("npos")), call("rt_buf_str", b, S(m, " accepts no arguments (")), [
                    call("rt_buf_str", b, S(m, " accepts ")),
                    num(get("npos")),
                    call("rt_buf_str", b, select_(op("i32.eq", get("npos"), i32(1)),
                         S(m, " positional argument ("), S(m, " positional arguments ("), STR)),
                ]),
                num(get("n")),
                call("rt_buf_str", b, S(m, " given)")),
                call("rt_fail", call("rt_buf_to_str", b)),
            ]),
            set("extra_pos", arr_new_default("Vals", op("i32.sub", get("n"), get("npos")))),
            arr_copy("Vals", get("extra_pos"), i32(0), get("args"), get("npos"), op("i32.sub", get("n"), get("npos"))),
            arr_set("Vals", get("out"), get("npos"), new("Tuple", get("extra_pos"))),
        ], if_(get("va"), arr_set("Vals", get("out"), get("npos"), new("Tuple", arr_new_default("Vals", i32(0)))))),

        # keyword arguments (never a method's receiver)
        if_(eqz(is_null(get("kw"))), [
            set("d", as_("Dict", get("kw"))),
            for_i32("i", i32(0), field("Dict", "used", get("d")), [
                set("key", arr_get("Vals", field("Dict", "keys", get("d")), get("i"))),
                if_(eqz(is_null(get("key"))), [
                    if_(eqz(is_("Str", get("key"))), fail_named(sig, "keywords must be strings", None)),
                    set("j", i32(-1)),
                    for_i32("s", get("recv"), get("kwend"), [
                        if_(and_(op("i32.lt_s", get("j"), i32(0)),
                                 and_(eqz(and_(get("va"), op("i32.eq", get("s"), get("npos")))),
                                      call("rt_str_eq", as_("Str", arr_get("Vals", get("names"), get("s"))), as_("Str", get("key"))))),
                            set("j", get("s"))),
                    ], label = "slot"),
                    if_(op("i32.lt_s", get("j"), i32(0)), [
                        if_(eqz(field("Sig", "kwargs", sig)), [
                            if_(builtin, [
                                bmsg(sig, "unexpected keyword argument "),
                                call("rt_buf_str", b, call("rt_repr", get("key"))),
                                # spelling hint among the named parameters (not *args)
                                set("cands", arr_new_default("Vals", op("i32.sub", op("i32.sub", get("kwend"), get("recv")), get("va")))),
                                arr_copy("Vals", non_null(get("cands")), i32(0), get("names"), get("recv"), op("i32.sub", get("npos"), get("recv"))),
                                arr_copy("Vals", non_null(get("cands")), op("i32.sub", get("npos"), get("recv")), get("names"),
                                         op("i32.add", get("npos"), get("va")), op("i32.sub", get("kwend"), op("i32.add", get("npos"), get("va")))),
                                # (starlark-go's UnpackArgs only offers the first half of
                                # them, rounded up: its loop steps by 2 over n, not 2n)
                                set("hint", call("rt_nearest", as_("Str", get("key")), non_null(get("cands")), i32(0),
                                                 op("i32.shr_u", op("i32.add", arr_len(non_null(get("cands"))), i32(1)), i32(1)))),
                                if_(is_("Str", get("hint")), [
                                    call("rt_buf_str", b, S(m, " (did you mean ")),
                                    call("rt_buf_str", b, as_("Str", get("hint"))),
                                    call("rt_buf_str", b, S(m, "?)")),
                                ]),
                                bfail(),
                            ]),
                            fail_named(sig, "got an unexpected keyword argument ", call("rt_repr", get("key"))),
                        ]),
                        if_(is_null(get("extra")), set("extra", call("rt_dict_new"))),
                        call("rt_dict_set", non_null(get("extra")), get("key"), arr_get("Vals", field("Dict", "vals", get("d")), get("i"))),
                    ], [
                        if_(eqz(is_null(arr_get("Vals", get("out"), get("j")))), [
                            if_(builtin, [
                                bmsg(sig, "got multiple values for keyword argument "),
                                call("rt_buf_str", b, call("rt_repr", get("key"))),
                                bfail(),
                            ]),
                            fail_named(sig, "got multiple values for parameter ", call("rt_repr", get("key"))),
                        ]),
                        arr_set("Vals", get("out"), get("j"), arr_get("Vals", field("Dict", "vals", get("d")), get("i"))),
                    ]),
                ]),
            ]),
        ]),
        if_(field("Sig", "kwargs", sig), arr_set("Vals", get("out"), op("i32.sub", get("total"), i32(1)),
            select_(is_null(get("extra")), call("rt_dict_new"), get("extra"), V))),

        # defaults; then report all missing ones: "function f missing 2 arguments (a, b)"
        set("k", i32(0)),
        for_i32("s", i32(0), get("kwend"), [
            if_(and_(eqz(and_(get("va"), op("i32.eq", get("s"), get("npos")))),
                     is_null(arr_get("Vals", get("out"), get("s")))), [
                if_(eqz(is_null(get("dflt"))),
                    arr_set("Vals", get("out"), get("s"), arr_get("Vals", get("dflt"), get("s")))),
                if_(is_null(arr_get("Vals", get("out"), get("s"))), inc("k")),
            ]),
        ]),
        if_(get("k"), [
            if_(op("i32.eq", get("kind"), i32(1)), [
                # "len: got 0 arguments, want 1"
                bmsg(sig, "got "),
                num(op("i32.sub", get("n"), get("recv"))),
                call("rt_buf_str", b, S(m, " arguments, want ")),
                if_(or_(get("va"), op("i32.lt_s", get("minpos"), op("i32.sub", get("npos"), get("recv")))),
                    call("rt_buf_str", b, S(m, "at least "))),
                num(get("minpos")),
                bfail(),
            ]),
            if_(op("i32.eq", get("kind"), i32(2)), [
                # "sorted: missing argument for iterable"
                bmsg(sig, "missing argument for "),
                set("s", i32(0)),
                while_(eqz(and_(eqz(and_(get("va"), op("i32.eq", get("s"), get("npos")))),
                                is_null(arr_get("Vals", get("out"), get("s"))))), inc("s"), label = "first"),
                call("rt_buf_str", b, as_("Str", arr_get("Vals", get("names"), get("s")))),
                bfail(),
            ]),
            start_msg(sig),
            call("rt_buf_str", b, S(m, " missing ")),
            num(get("k")),
            call("rt_buf_str", b, select_(op("i32.eq", get("k"), i32(1)), S(m, " argument ("), S(m, " arguments ("), STR)),
            set("j", i32(0)),
            for_i32("s", i32(0), get("kwend"), [
                if_(and_(eqz(and_(get("va"), op("i32.eq", get("s"), get("npos")))),
                         is_null(arr_get("Vals", get("out"), get("s")))), [
                    if_(get("j"), call("rt_buf_str", b, S(m, ", "))),
                    call("rt_buf_str", b, as_("Str", arr_get("Vals", get("names"), get("s")))),
                    inc("j"),
                ]),
            ]),
            call("rt_buf_byte", b, i32(41)),
            call("rt_fail", call("rt_buf_to_str", b)),
        ]),
        get("out"),
    ])

    # Exact-length copy of a list's elements (for f(*args) call sites).
    add_func(m, "rt_vals_of_list", [("l", V)], [VALS], [
        call("rt_vals_concat", field("List", "items", as_("List", get("l"))), field("List", "len", as_("List", get("l"))),
             arr_new_default("Vals", i32(0)), i32(0)),
    ])

    # f(*x): append x's elements to the call's positional list l.
    add_func(m, "rt_star_args", [("l", LIST), ("x", V)], [], [
        if_(eqz(or_(or_(or_(is_("List", get("x")), is_("Tuple", get("x"))), or_(is_("Dict", get("x")), is_("Set", get("x")))), or_(is_("Range", get("x")), is_("Lazy", get("x"))))),
            type_err1(m, "argument after * must be iterable, not ", get("x"), "")),
        call("rt_list_extend", get("l"), get("x")),
    ])

    # f(**x): merge dict x into the call's keyword dict d. f (the callee,
    # evaluated first) picks starlark-go's message for a repeated name.
    add_func(m, "rt_kwargs_update", [("d", V), ("x", V), ("f", V)], [], locals = [("src", ref("Dict", True)), ("i", I32), ("k", V)], body = [
        if_(eqz(is_("Dict", get("x"))), type_err1(m, "argument after ** must be a mapping, not ", get("x"), "")),
        set("src", as_("Dict", get("x"))),
        for_i32("i", i32(0), field("Dict", "used", get("src")), [
            set("k", arr_get("Vals", field("Dict", "keys", get("src")), get("i"))),
            if_(eqz(is_null(get("k"))), [
                if_(eqz(is_("Str", get("k"))), type_err1(m, "keywords must be strings, not ", get("k"), "")),
                if_(eqz(is_null(call("rt_dict_get", as_("Dict", get("d")), get("k")))),
                    call("rt_kwargs_repeated", get("f"), get("k"))),
                call("rt_dict_set", as_("Dict", get("d")), get("k"), arr_get("Vals", field("Dict", "vals", get("src")), get("i"))),
            ]),
        ]),
    ])

    # Keyword k given twice in a call of f: fail as starlark-go does for f
    # (struct: the last one wins, no error).
    add_func(m, "rt_kwargs_repeated", [("f", V), ("k", V)], [], locals = [("sig", ref("Sig", True)), ("name", ref("Str", True)), ("b", BUF)], body = [
        if_(is_("Bound", get("f")), set("f", field("Bound", "fn", as_("Bound", get("f"))))),
        if_(eqz(is_("Func", get("f"))), fail_(m, "got multiple values for a keyword argument")),
        set("sig", field("Func", "sig", as_("Func", get("f")))),
        set("name", field("Sig", "name", get("sig"))),
        set("b", call("rt_buf_new")),
        if_(eqz(field("Sig", "kind", get("sig"))), [
            call("rt_buf_str", get("b"), S(m, "function ")),
            call("rt_buf_str", get("b"), non_null(get("name"))),
            call("rt_buf_str", get("b"), S(m, " got multiple values for parameter ")),
        ], [
            if_(call("rt_str_eq", non_null(get("name")), S(m, "struct")), "return"),
            call("rt_buf_str", get("b"), non_null(get("name"))),
            if_(call("rt_str_eq", non_null(get("name")), S(m, "dict")), call("rt_buf_str", get("b"), S(m, ": duplicate keyword arg: ")), [
                # positional-only builtins take no keywords at all
                if_(and_(op("i32.eq", field("Sig", "kind", get("sig")), i32(1)), eqz(field("Sig", "kwargs", get("sig")))), [
                    call("rt_buf_str", get("b"), S(m, ": unexpected keyword arguments")),
                    call("rt_fail", call("rt_buf_to_str", get("b"))),
                ]),
                call("rt_buf_str", get("b"), S(m, ": got multiple values for keyword argument ")),
            ]),
        ]),
        call("rt_buf_value", get("b"), get("k"), i32(1)),
        call("rt_fail", call("rt_buf_to_str", get("b"))),
    ])

def _format(m):
    # Digits of x in base 2..16 (negative values get a leading '-').
    add_func(m, "rt_buf_radix", [("b", BUF), ("x", I64), ("base", I32), ("upper", I32)], [], locals = [
        ("i", I32),
        ("j", I32),
        ("t", I32),
        ("d", I32),
        ("a", U8A),
    ], body = [
        if_(op("i64.lt_s", get("x"), i64(0)),
            call("rt_buf_byte", get("b"), i32(45)),
            set("x", op("i64.sub", i64(0), get("x")))),
        set("i", field("Buf", "len", get("b"))),
        ("loop", None, "digits"),
        set("d", op("i32.sub", i32(0), op("i32.wrap_i64", op("i64.rem_s", get("x"), op("i64.extend_i32_s", get("base")))))),
        call("rt_buf_byte", get("b"), select_(op("i32.lt_u", get("d"), i32(10)),
                                               op("i32.add", get("d"), i32(48)),
                                               op("i32.add", get("d"), select_(get("upper"), i32(55), i32(87), I32)), I32)),
        set("x", op("i64.div_s", get("x"), op("i64.extend_i32_s", get("base")))),
        br_if("digits", op("i64.ne", get("x"), i64(0))),
        "end",
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

    # fmt % args: %s %r %d %i %x %X %o %c %%, and %(key)s with a dict.
    add_func(m, "rt_format", [("fmt", STR), ("args", V)], [V], locals = [
        ("f", U8A),
        ("n", I32),
        ("i", I32),
        ("j", I32),
        ("c", I32),
        ("items", ref("Vals", True)),
        ("nargs", I32),
        ("ai", I32),
        ("v", V),
        ("b", BUF),
        ("mapping", I32),
        ("key", V),
        ("pb", ref("Buf", True)),
    ], body = [
        set("f", field("Str", "b", get("fmt"))),
        set("n", arr_len(get("f"))),
        set("b", call("rt_buf_new")),
        set("mapping", i32(0)),
        if_(is_("Tuple", get("args")), [
            set("items", _items(as_("Tuple", get("args")))),
            set("nargs", arr_len(get("items"))),
        ], [
            set("items", arr_fixed("Vals", get("args"))),
            set("nargs", i32(1)),
        ]),
        set("i", i32(0)),
        set("ai", i32(0)),
        while_(op("i32.lt_s", get("i"), get("n")), [
            set("c", arr_get_u("U8", get("f"), get("i"))),
            inc("i"),
            if_(op("i32.ne", get("c"), i32(37)), [  # not '%'
                call("rt_buf_byte", get("b"), get("c")),
                br("loop"),
            ]),
            if_(op("i32.ge_s", get("i"), get("n")), fail_(m, "incomplete format")),
            set("c", arr_get_u("U8", get("f"), get("i"))),
            inc("i"),
            if_(op("i32.eq", get("c"), i32(37)), [call("rt_buf_byte", get("b"), i32(37)), br("loop")]),
            if_(op("i32.eq", get("c"), i32(40)), [  # %(key)
                if_(eqz(is_("Dict", get("args"))), fail_(m, "format requires a mapping")),
                set("mapping", i32(1)),
                set("j", get("i")),
                while_(and_(op("i32.lt_s", get("j"), get("n")), op("i32.ne", arr_get_u("U8", get("f"), get("j")), i32(41))),
                       inc("j"), label = "key"),
                if_(op("i32.ge_s", get("j"), get("n")), fail_(m, "incomplete format key")),
                set("key", call("rt_slice", get("fmt"), call("rt_int", op("i64.extend_i32_s", get("i"))),
                                call("rt_int", op("i64.extend_i32_s", get("j"))), null("eq"))),
                set("v", call("rt_dict_get", as_("Dict", get("args")), get("key"))),
                if_(is_null(get("v")), fail_(m, "format: key not found in mapping")),
                set("i", op("i32.add", get("j"), i32(1))),
                if_(op("i32.ge_s", get("i"), get("n")), fail_(m, "incomplete format")),
                set("c", arr_get_u("U8", get("f"), get("i"))),
                inc("i"),
            ], [
                if_(op("i32.ge_s", get("ai"), get("nargs")), fail_(m, "not enough arguments for format string")),
                set("v", arr_get("Vals", get("items"), get("ai"))),
                inc("ai"),
            ]),
            # %d %i %x %X %o of a float: its integer part
            if_(and_(is_("Float", get("v")), or_(or_(op("i32.eq", get("c"), i32(100)), op("i32.eq", get("c"), i32(105))),
                    or_(or_(op("i32.eq", get("c"), i32(120)), op("i32.eq", get("c"), i32(88))), op("i32.eq", get("c"), i32(111))))), [
                set("pb", call("rt_buf_new")),
                call("rt_buf_byte", non_null(get("pb")), i32(37)),
                call("rt_buf_byte", non_null(get("pb")), get("c")),
                call("rt_buf_str", non_null(get("pb")), S(m, " format requires integer: ")),
                set("v", call("rt_float_to_int", field("Float", "v", as_("Float", get("v"))), call("rt_buf_to_str", non_null(get("pb"))))),
            ]),
            # %e %f %g %E %G
            if_(or_(or_(op("i32.eq", get("c"), i32(101)), op("i32.eq", get("c"), i32(102))),
                    or_(or_(op("i32.eq", get("c"), i32(103)), op("i32.eq", get("c"), i32(69))), op("i32.eq", get("c"), i32(71)))), [
                if_(eqz(call("rt_is_num", get("v"))), [
                    set("b", call("rt_buf_new")),
                    call("rt_buf_byte", get("b"), i32(37)),
                    call("rt_buf_byte", get("b"), get("c")),
                    call("rt_buf_str", get("b"), S(m, " format requires float, not ")),
                    call("rt_buf_str", get("b"), call("rt_type", get("v"))),
                    call("rt_fail", call("rt_buf_to_str", get("b"))),
                ]),
                call("rt_buf_float", get("b"), call("rt_f64", get("v")), get("c")),
                br("loop"),
            ]),
            if_(and_(eqz(call("rt_is_int", get("v"))), or_(or_(op("i32.eq", get("c"), i32(100)), op("i32.eq", get("c"), i32(105))),
                    or_(or_(op("i32.eq", get("c"), i32(120)), op("i32.eq", get("c"), i32(88))), op("i32.eq", get("c"), i32(111))))), [
                set("b", call("rt_buf_new")),
                call("rt_buf_byte", get("b"), i32(37)),
                call("rt_buf_byte", get("b"), get("c")),
                call("rt_buf_str", get("b"), S(m, " format requires integer: cannot convert ")),
                call("rt_buf_str", get("b"), call("rt_type", get("v"))),
                call("rt_buf_str", get("b"), S(m, " to int")),
                call("rt_fail", call("rt_buf_to_str", get("b"))),
            ]),
            if_(op("i32.eq", get("c"), i32(115)), call("rt_buf_value", get("b"), get("v"), is_("Bytes", get("v"))),  # s (bytes: quoted)
            if_(op("i32.eq", get("c"), i32(114)), call("rt_buf_value", get("b"), get("v"), i32(1)),  # r
            if_(and_(is_("Big", get("v")), or_(or_(op("i32.eq", get("c"), i32(100)), op("i32.eq", get("c"), i32(105))),
                    or_(or_(op("i32.eq", get("c"), i32(120)), op("i32.eq", get("c"), i32(88))), op("i32.eq", get("c"), i32(111))))),
                call("rt_buf_bigradix", get("b"), get("v"),
                     select_(op("i32.eq", get("c"), i32(111)), i32(8), select_(or_(op("i32.eq", get("c"), i32(120)), op("i32.eq", get("c"), i32(88))), i32(16), i32(10), I32), I32),
                     op("i32.eq", get("c"), i32(88))),
            if_(or_(op("i32.eq", get("c"), i32(100)), op("i32.eq", get("c"), i32(105))),  # d i
                call("rt_buf_radix", get("b"), call("rt_i64", get("v")), i32(10), i32(0)),
            if_(op("i32.eq", get("c"), i32(120)), call("rt_buf_radix", get("b"), call("rt_i64", get("v")), i32(16), i32(0)),  # x
            if_(op("i32.eq", get("c"), i32(88)), call("rt_buf_radix", get("b"), call("rt_i64", get("v")), i32(16), i32(1)),  # X
            if_(op("i32.eq", get("c"), i32(111)), call("rt_buf_radix", get("b"), call("rt_i64", get("v")), i32(8), i32(0)),  # o
            if_(op("i32.eq", get("c"), i32(99)),  # c
                call("rt_fmt_c", get("b"), get("v")),
                fail_(m, "unsupported format character"))))))))),
        ]),
        # as starlark-go: never "too many" when the operand is a mapping
        if_(and_(eqz(or_(get("mapping"), is_("Dict", get("args")))), op("i32.lt_s", get("ai"), get("nargs"))),
            fail_(m, "too many arguments for format string")),
        call("rt_buf_to_str", get("b")),
    ])

    # The % operator: string formatting or integer modulo.
    # %c of v, as starlark-go: a code point, or a one-rune string
    add_func(m, "rt_fmt_c", [("b", BUF), ("v", V)], [], locals = [("a", U8A), ("n", I32), ("k", I32), ("x", I64)], body = [
        if_(call("rt_is_int", get("v")), [
            if_(call("rt_is_small", get("v")), set("x", call("rt_i64", get("v"))), set("x", i64(-1))),
            if_(or_(op("i64.lt_s", get("x"), i64(0)), op("i64.gt_s", get("x"), i64(0x10ffff))),
                call("rt_fail", call("rt_str_concat", S(m, "%c format requires a valid Unicode code point, got "), call("rt_str", get("v"))))),
            call("rt_buf_str", get("b"), as_("Str", call("rt_chr", get("v")))),
            "return",
        ]),
        if_(eqz(is_("Str", get("v"))), type_err1(m, "%c format requires int or single-character string, not ", get("v"), "")),
        set("a", field("Str", "b", as_("Str", get("v")))),
        set("n", arr_len(get("a"))),
        if_(eqz(get("n")), fail_(m, "%c format requires a single-character string")),
        set("k", call("rt_utf8_seq", get("a"), i32(0), get("n"))),
        if_(eqz(get("k")), set("k", i32(1))),
        if_(op("i32.ne", get("k"), get("n")), fail_(m, "%c format requires a single-character string")),
        # an invalid byte is U+FFFD (as Go's WriteRune of DecodeRune's result)
        if_(eqz(call("rt_utf8_seq", get("a"), i32(0), get("n"))), call("rt_buf_rune", get("b"), i32(0xfffd)),
            call("rt_buf_str", get("b"), as_("Str", get("v")))),
    ])

    add_func(m, "rt_percent", [("a", V), ("b", V)], [V], [
        if_(is_("Str", get("a")), ret(call("rt_format", as_("Str", get("a")), get("b")))),
        call("rt_mod", get("a"), get("b")),
    ])

def _sorting(m):
    def less(a, b):
        # i32: element order respecting `reverse` (stable either way)
        return select_(get("rev"), call("rt_lt", b, a), call("rt_lt", a, b), I32)

    # sorted(x, key=None, reverse=False): stable bottom-up merge sort that
    # moves keys and values together.
    # kw: key was passed by keyword (starlark-go then quotes its name in errors)
    add_func(m, "rt_sorted", [("x", V), ("key", V), ("rev", I32), ("kw", I32)], [V], locals = [
        ("src", VALS),
        ("n", I32),
        ("ks", VALS),
        ("vs", VALS),
        ("tk", VALS),
        ("tv", VALS),
        ("sw", VALS),
        ("w", I32),
        ("i", I32),
        ("lo", I32),
        ("mid", I32),
        ("hi", I32),
        ("p", I32),
        ("q", I32),
        ("o", I32),
    ], body = [
        # as starlark-go's UnpackArgs: key omitted (null or Absent), or a callable
        if_(eqz(or_(or_(or_(is_("List", get("x")), is_("Tuple", get("x"))), or_(is_("Dict", get("x")), is_("Set", get("x")))), or_(is_("Range", get("x")), is_("Lazy", get("x"))))),
            type_err1(m, "sorted: for parameter iterable: got ", get("x"), ", want iterable")),
        if_(ref_eq(get("key"), gget("Absent")), set("key", null("eq"))),
        if_(eqz(or_(is_null(get("key")), or_(is_("Func", get("key")), is_("Bound", get("key"))))),
            if_(get("kw"), type_err1(m, "sorted: for parameter \"key\": got ", get("key"), ", want callable"),
                type_err1(m, "sorted: for parameter key: got ", get("key"), ", want callable"))),
        set("src", _items(call("rt_iter", get("x")))),
        set("n", arr_len(get("src"))),
        set("vs", call("rt_vals_concat", get("src"), get("n"), arr_new_default("Vals", i32(0)), i32(0))),
        set("ks", call("rt_vals_concat", get("src"), get("n"), arr_new_default("Vals", i32(0)), i32(0))),
        # key is Starlark code running while x is iterated: x may not change
        if_(eqz(is_null(get("key"))), [
            call("rt_iter_track", get("x"), i32(2)),
            for_i32("i", i32(0), get("n"), [
                arr_set("Vals", get("ks"), get("i"),
                        call("rt_call", get("key"), arr_fixed("Vals", arr_get("Vals", get("vs"), get("i"))), null("eq"))),
            ]),
            call("rt_iter_track", get("x"), i32(-2)),
        ]),
        set("tk", arr_new_default("Vals", get("n"))),
        set("tv", arr_new_default("Vals", get("n"))),
        set("w", i32(1)),
        while_(op("i32.lt_s", get("w"), get("n")), [
            set("i", i32(0)),
            while_(op("i32.lt_s", get("i"), get("n")), [
                set("lo", get("i")),
                set("mid", op("i32.add", get("i"), get("w"))),
                if_(op("i32.gt_s", get("mid"), get("n")), set("mid", get("n"))),
                set("hi", op("i32.add", get("mid"), get("w"))),
                if_(op("i32.gt_s", get("hi"), get("n")), set("hi", get("n"))),
                set("p", get("lo")),
                set("q", get("mid")),
                for_i32("o", get("lo"), get("hi"), [
                    if_(and_(op("i32.lt_s", get("q"), get("hi")),
                             or_(op("i32.ge_s", get("p"), get("mid")),
                                 less(arr_get("Vals", get("ks"), get("q")), arr_get("Vals", get("ks"), get("p"))))), [
                        arr_set("Vals", get("tk"), get("o"), arr_get("Vals", get("ks"), get("q"))),
                        arr_set("Vals", get("tv"), get("o"), arr_get("Vals", get("vs"), get("q"))),
                        inc("q"),
                    ], [
                        arr_set("Vals", get("tk"), get("o"), arr_get("Vals", get("ks"), get("p"))),
                        arr_set("Vals", get("tv"), get("o"), arr_get("Vals", get("vs"), get("p"))),
                        inc("p"),
                    ]),
                ], label = "merge"),
                set("i", op("i32.add", get("i"), op("i32.shl", get("w"), i32(1)))),
            ], label = "pass"),
            set("sw", get("ks")), set("ks", get("tk")), set("tk", get("sw")),
            set("sw", get("vs")), set("vs", get("tv")), set("tv", get("sw")),
            set("w", op("i32.shl", get("w"), i32(1))),
        ]),
        new("List", get("n"), get("vs"), i32(0)),
    ])

def _freezing(m):
    v = get("v")
    # Deep-freeze v (Starlark freezes a module's values once it has been
    # loaded). Lists, dicts and functions carry a flag, which also stops
    # cycles; tuples just pass through to their elements.
    add_func(m, "rt_freeze", [("v", V)], [], locals = [
        ("items", ref("Vals", True)),
        ("n", I32),
        ("i", I32),
        ("d", ref("Dict", True)),
        ("f", ref("Func", True)),
    ], body = [
        if_(is_("List", v), [
            if_(op("i32.and", field("List", "frozen", as_("List", v)), i32(1)), "return"),
            setfield("List", "frozen", as_("List", v), op("i32.or", field("List", "frozen", as_("List", v)), i32(1))),
            set("items", field("List", "items", as_("List", v))),
            set("n", field("List", "len", as_("List", v))),
        ], if_(is_("Tuple", v), [
            set("items", _items(as_("Tuple", v))),
            set("n", arr_len(get("items"))),
        ], if_(is_("Dict", v), [
            set("d", as_("Dict", v)),
            if_(op("i32.and", field("Dict", "frozen", get("d")), i32(1)), "return"),
            setfield("Dict", "frozen", get("d"), op("i32.or", field("Dict", "frozen", get("d")), i32(1))),
            for_i32("i", i32(0), field("Dict", "used", get("d")), [
                call("rt_freeze", arr_get("Vals", field("Dict", "keys", get("d")), get("i"))),
                call("rt_freeze", arr_get("Vals", field("Dict", "vals", get("d")), get("i"))),
            ]),
            "return",
        ], if_(is_("Set", v), [
            call("rt_freeze", field("Set", "d", as_("Set", v))),
            "return",
        ], if_(is_("Struct", v), [
            call("rt_freeze", field("Struct", "d", as_("Struct", v))),
            "return",
        ], if_(is_("Bound", v), [
            call("rt_freeze", field("Bound", "recv", as_("Bound", v))),
            "return",
        ], if_(is_("Func", v), [
            set("f", as_("Func", v)),
            if_(field("Func", "frozen", get("f")), "return"),
            setfield("Func", "frozen", get("f"), i32(1)),
            if_(eqz(is_null(field("Func", "defaults", get("f")))), [
                set("items", field("Func", "defaults", get("f"))),
                for_i32("i", i32(0), arr_len(get("items")), call("rt_freeze", arr_get("Vals", get("items"), get("i")))),
            ]),
            if_(eqz(is_null(field("Func", "env", get("f")))), [
                set("items", field("Func", "env", get("f"))),
                for_i32("i", i32(0), arr_len(get("items")),
                        call("rt_freeze", field("Cell", "v", as_("Cell", arr_get("Vals", get("items"), get("i")))))),
            ]),
            "return",
        ], "return"))))))),
        for_i32("i", i32(0), get("n"), call("rt_freeze", arr_get("Vals", get("items"), get("i")))),
    ])

def _intrinsics(m):
    """Primitives only lib/prelude.star can call (see PRELUDE_INTRINSICS in
    compiler/codegen.star)."""
    s, sub, lo, hi = get("s"), get("sub"), get("lo"), get("hi")
    P = [("s", V), ("sub", V), ("lo", V), ("hi", V)]
    L = [("a", U8A), ("b", U8A), ("n", I32), ("i", I32), ("j", I32), ("start", I32), ("end", I32), ("step", I32)]

    # _find(s, sub, lo, hi) / _rfind: index of the first / last occurrence of
    # sub entirely inside s[lo:hi] (lo, hi already clamped), or -1.
    for name, backward in [("rt_find", False), ("rt_rfind", True)]:
        add_func(m, name, P, [V], locals = L, body = [
            set("a", field("Str", "b", as_("Str", s))),
            set("b", field("Str", "b", as_("Str", sub))),
            set("n", arr_len(get("b"))),
            set("start", op("i32.wrap_i64", call("rt_i64", lo))),
            set("end", op("i32.sub", op("i32.wrap_i64", call("rt_i64", hi)), get("n"))),  # last start position
            if_(op("i32.gt_s", get("start"), get("end")), ret(op("ref.i31", i32(-1)))),
            set("i", get("end") if backward else get("start")),
            set("step", i32(-1 if backward else 1)),
            while_(op("i32.ge_s", get("i"), get("start")) if backward else op("i32.le_s", get("i"), get("end")), [
                set("j", i32(0)),
                while_(and_(op("i32.lt_s", get("j"), get("n")),
                            op("i32.eq", arr_get_u("U8", get("a"), op("i32.add", get("i"), get("j"))), arr_get_u("U8", get("b"), get("j")))),
                       inc("j"), label = "cmp"),
                if_(op("i32.eq", get("j"), get("n")), ret(op("ref.i31", get("i")))),
                set("i", op("i32.add", get("i"), get("step"))),
            ]),
            op("ref.i31", i32(-1)),
        ])

    # _bytes_to_str(list of ints 0..255) -> string
    add_func(m, "rt_bytes_to_str", [("l", V)], [V], locals = [("t", VALS), ("a", U8A), ("i", I32), ("x", I64)], body = [
        set("t", _items(call("rt_iter", get("l")))),
        set("a", arr_new_default("U8", arr_len(get("t")))),
        for_i32("i", i32(0), arr_len(get("t")), [
            set("x", call("rt_i64", arr_get("Vals", get("t"), get("i")))),
            if_(op("i64.gt_u", get("x"), i64(255)), fail_(m, "byte value out of range")),
            arr_set("U8", get("a"), get("i"), op("i32.wrap_i64", get("x"))),
        ]),
        new("Str", i32(0), get("a")),
    ])

    # _frozen(x) / _iterating(x): the two parts of a list's or dict's
    # (or set's) "frozen" field; rt_flag_ref finds the field's owner
    add_func(m, "rt_flags", [("x", V)], [I32], [
        if_(is_("List", get("x")), ret(field("List", "frozen", as_("List", get("x"))))),
        if_(is_("Dict", get("x")), ret(field("Dict", "frozen", as_("Dict", get("x"))))),
        if_(is_("Set", get("x")), ret(field("Dict", "frozen", field("Set", "d", as_("Set", get("x")))))),
        i32(0),
    ])
    add_func(m, "rt_frozen", [("x", V)], [V], [call("rt_bool", op("i32.and", call("rt_flags", get("x")), i32(1)))])
    add_func(m, "rt_iterating", [("x", V)], [V], [call("rt_bool", op("i32.shr_u", call("rt_flags", get("x")), i32(1)))])

    # A loop over x starts (delta 2) or ends (-2): count it in x's flags,
    # so x can't be changed meanwhile. Other values aren't tracked.
    add_func(m, "rt_iter_track", [("x", V), ("delta", I32)], [], [
        if_(is_("List", get("x")), [
            setfield("List", "frozen", as_("List", get("x")), op("i32.add", field("List", "frozen", as_("List", get("x"))), get("delta"))),
            "return",
        ]),
        if_(is_("Set", get("x")), set("x", field("Set", "d", as_("Set", get("x"))))),
        if_(is_("Dict", get("x")),
            setfield("Dict", "frozen", as_("Dict", get("x")), op("i32.add", field("Dict", "frozen", as_("Dict", get("x"))), get("delta")))),
    ])

    # _case(s, mode) / _classify(s, mode): see rt_str_case / rt_str_class
    add_func(m, "rt_case_v", [("s", V), ("mode", V)], [V], [
        call("rt_str_case", as_("Str", get("s")), op("i32.wrap_i64", call("rt_i64", get("mode")))),
    ])
    add_func(m, "rt_class_v", [("s", V), ("mode", V)], [V], [
        call("rt_bool", call("rt_str_class", as_("Str", get("s")), op("i32.wrap_i64", call("rt_i64", get("mode"))))),
    ])

    # _absent(): a value no Starlark code can make (a parameter default
    # meaning "omitted"); _is_absent(v)
    add_func(m, "rt_absent", [], [V], [gget("Absent")])
    add_func(m, "rt_is_absent", [("v", V)], [V], [call("rt_bool", ref_eq(get("v"), gget("Absent")))])

    # _set_dict(s): the dict holding set s's elements as keys
    add_func(m, "rt_set_dict", [("s", V)], [V], [field("Set", "d", as_("Set", get("s")))])

    # _unhashable(x): the type name that makes x unhashable, or None
    add_func(m, "rt_unhashable", [("x", V)], [V], locals = [("t", VALS), ("i", I32), ("r", V)], body = [
        if_(is_("Tuple", get("x")), [
            set("t", _items(as_("Tuple", get("x")))),
            for_i32("i", i32(0), arr_len(get("t")), [
                set("r", call("rt_unhashable", arr_get("Vals", get("t"), get("i")))),
                if_(eqz(ref_eq(get("r"), gget("None"))), ret(get("r"))),
            ]),
            ret(gget("None")),
        ]),
        if_(is_("Struct", get("x")), [
            set("t", _items(call("rt_iter", call("rt_m_values", field("Struct", "d", as_("Struct", get("x"))))))),
            for_i32("i", i32(0), arr_len(get("t")), [
                set("r", call("rt_unhashable", arr_get("Vals", get("t"), get("i")))),
                if_(eqz(ref_eq(get("r"), gget("None"))), ret(get("r"))),
            ]),
            ret(gget("None")),
        ]),
        if_(or_(is_("List", get("x")), or_(is_("Dict", get("x")), is_("Set", get("x")))), ret(call("rt_type", get("x")))),
        gget("None"),
    ])

    # _to_bytes(x): a string's bytes, or a list of ints 0..255 (checked by
    # the caller, lib/prelude.star's bytes()) as bytes
    add_func(m, "rt_to_bytes", [("x", V)], [V], locals = [("t", VALS), ("a", U8A), ("i", I32)], body = [
        if_(is_("Str", get("x")), ret(str_bytes(as_("Str", get("x"))))),
        set("t", _items(call("rt_iter", get("x")))),
        set("a", arr_new_default("U8", arr_len(get("t")))),
        for_i32("i", i32(0), arr_len(get("t")), [
            arr_set("U8", get("a"), get("i"), op("i32.wrap_i64", call("rt_i64", arr_get("Vals", get("t"), get("i"))))),
        ]),
        new("Bytes", i32(0), get("a")),
    ])

    # _struct_new(d): a struct with the entries of dict d (fields sorted)
    add_func(m, "rt_struct_new", [("d", V)], [V], locals = [("keys", LIST), ("nd", DICT), ("i", I32), ("k", V)], body = [
        set("keys", as_("List", call("rt_sorted", get("d"), null("eq"), i32(0), i32(0)))),
        set("nd", call("rt_dict_new")),
        for_i32("i", i32(0), field("List", "len", get("keys")), [
            set("k", arr_get("Vals", field("List", "items", get("keys")), get("i"))),
            call("rt_dict_set", get("nd"), get("k"), call("rt_dict_get", as_("Dict", get("d")), get("k"))),
        ]),
        new("Struct", get("nd")),
    ])

    # _struct_dict(s): the dict holding struct s's fields (never mutated)
    add_func(m, "rt_struct_dict", [("s", V)], [V], [field("Struct", "d", as_("Struct", get("s")))])

    # _bound(x, name): the bound method x.name (name is a method of x's type)
    add_func(m, "rt_bound", [("x", V), ("name", V)], [V], [
        new("Bound", get("x"), as_("Func", call("rt_dict_get", non_null(gget("method_funcs")), get("name"))), as_("Str", get("name"))),
    ])

    # _error(msg): fail as the builtin being called ("Error in split: msg");
    # _error_plain(msg): "Error: msg".
    add_func(m, "rt_error", [("msg", V)], [V], [call("rt_fail_ex", as_("Str", get("msg")), i32(0)), "unreachable"])
    add_func(m, "rt_error_plain", [("msg", V)], [V], [call("rt_fail_ex", as_("Str", get("msg")), i32(1)), "unreachable"])

def _hashing(m):
    # hash(x), as starlark-go: for a string, Java's String.hashCode over its
    # code points (each invalid UTF-8 byte counts as U+FFFD; like
    # starlark-go, code points above U+FFFF are not split into surrogates);
    # for bytes, 32-bit FNV-1a (non-negative).
    add_func(m, "rt_hash_builtin", [("x", V)], [V], locals = [
        ("a", U8A),
        ("n", I32),
        ("i", I32),
        ("k", I32),
        ("j", I32),
        ("r", I32),
        ("h", I32),
    ], body = [
        if_(is_("Bytes", get("x")), [
            set("a", field("Bytes", "b", as_("Bytes", get("x")))),
            set("h", i32(0x811c9dc5)),
            for_i32("i", i32(0), arr_len(get("a")), [
                set("h", op("i32.mul", op("i32.xor", get("h"), arr_get_u("U8", get("a"), get("i"))), i32(0x01000193))),
            ]),
            ret(call("rt_int", op("i64.extend_i32_u", get("h")))),
        ]),
        if_(eqz(is_("Str", get("x"))), type_err1(m, "hash: got ", get("x"), ", want string or bytes")),
        set("a", field("Str", "b", as_("Str", get("x")))),
        set("n", arr_len(get("a"))),
        set("h", i32(0)),
        set("i", i32(0)),
        while_(op("i32.lt_s", get("i"), get("n")), [
            set("k", call("rt_utf8_seq", get("a"), get("i"), get("n"))),
            if_(eqz(get("k")), [set("r", i32(0xfffd)), set("k", i32(1))], [
                set("r", arr_get_u("U8", get("a"), get("i"))),
                if_(op("i32.eq", get("k"), i32(2)), set("r", op("i32.and", get("r"), i32(0x1f)))),
                if_(op("i32.eq", get("k"), i32(3)), set("r", op("i32.and", get("r"), i32(0x0f)))),
                if_(op("i32.eq", get("k"), i32(4)), set("r", op("i32.and", get("r"), i32(0x07)))),
                for_i32("j", i32(1), get("k"), [
                    set("r", op("i32.or", op("i32.shl", get("r"), i32(6)),
                                op("i32.and", arr_get_u("U8", get("a"), op("i32.add", get("i"), get("j"))), i32(0x3f)))),
                ]),
            ]),
            set("h", op("i32.add", op("i32.mul", get("h"), i32(31)), get("r"))),
            set("i", op("i32.add", get("i"), get("k"))),
        ]),
        call("rt_int", op("i64.extend_i32_s", get("h"))),
    ])

def _structs(m):
    # " (did you mean .n?)" for the candidate n (in list l) nearest to name, or ""
    add_func(m, "rt_hint", [("name", V), ("l", V)], [STR], locals = [("h", V)], body = [
        set("h", call("rt_nearest", as_("Str", get("name")), field("List", "items", as_("List", get("l"))), i32(0), field("List", "len", as_("List", get("l"))))),
        if_(is_("Str", get("h")), ret(call("rt_str_concat", call("rt_str_concat", S(m, " (did you mean ."), as_("Str", get("h"))), S(m, "?)")))),
        S(m, ""),
    ])
    # _nearest(name, list) for the prelude: the nearest candidate, or None
    add_func(m, "rt_nearest_v", [("name", V), ("l", V)], [V], [
        call("rt_nearest", as_("Str", get("name")), field("List", "items", as_("List", get("l"))), i32(0), field("List", "len", as_("List", get("l")))),
    ])

    # x.name for a struct x: the field's value, or a plain error at the "."
    add_func(m, "rt_struct_attr", [("x", V), ("name", V)], [V], locals = [("v", V)], body = [
        set("v", call("rt_dict_get", field("Struct", "d", as_("Struct", get("x"))), get("name"))),
        if_(is_null(get("v")), [
            call("rt_fail_ex", call("rt_str_concat", call("rt_str_concat", call("rt_str_concat", S(m, "struct has no ."), as_("Str", get("name"))), S(m, " attribute")),
                                    call("rt_hint", get("name"), call("rt_sorted", field("Struct", "d", as_("Struct", get("x"))), null("eq"), i32(0), i32(0)))), i32(1)),
            "unreachable",
        ]),
        get("v"),
    ])

    # a + b: the fields of both; b's win
    add_func(m, "rt_struct_add", [("a", ref("Struct")), ("b", ref("Struct"))], [V], locals = [("d", DICT), ("src", DICT), ("i", I32), ("j", I32), ("k", V)], body = [
        set("d", call("rt_dict_new")),
        for_i32("j", i32(0), i32(2), [
            set("src", field("Struct", "d", select_(get("j"), get("b"), get("a"), ref("Struct")))),
            for_i32("i", i32(0), field("Dict", "used", get("src")), [
                set("k", arr_get("Vals", field("Dict", "keys", get("src")), get("i"))),
                if_(eqz(is_null(get("k"))),
                    call("rt_dict_set", get("d"), get("k"), arr_get("Vals", field("Dict", "vals", get("src")), get("i")))),
            ]),
        ], label = "side"),
        call("rt_struct_new", get("d")),
    ])

def _methods(m):
    x, a, b = get("x"), get("a"), get("b")
    NONE = gget("None")

    def no_method(name):
        # starlark-go: "Error: int has no .append field or method" (plain)
        return [call("rt_fail_ex", call("rt_str_concat", call("rt_type", x), S(m, " has no ." + name + " field or method")), i32(1)), "unreachable"]

    def method(name, nargs, body, locals = []):
        params = [("x", V)] + [p for p in [("a", V), ("b", V)][:nargs]]
        add_func(m, "rt_m_" + name, params, [V], body + [no_method(name)], locals = locals)

    method("append", 1, [
        if_(is_("List", x), [
            check_mutable(m, field("List", "frozen", as_("List", x)), "append: cannot append to frozen list", "append: cannot append to list during iteration"),
            call("rt_list_append", as_("List", x), a),
            ret(NONE),
        ]),
    ])
    method("extend", 1, [
        if_(is_("List", x), [
            check_mutable(m, field("List", "frozen", as_("List", x)), "extend: cannot extend frozen list", "extend: cannot extend list during iteration"),
            call("rt_want_iterable", a, S(m, "extend")),
            call("rt_list_extend", as_("List", x), a),
            ret(NONE),
        ]),
    ])
    method("pop", 2, [
        if_(is_("List", x), [
            if_(eqz(is_null(b)), fail_(m, "pop: got 2 arguments, want at most 1")),
            set("l", as_("List", x)),
            check_mutable(m, field("List", "frozen", get("l")), "pop: cannot pop from frozen list", "pop: cannot pop from list during iteration"),
            if_(_absent(a), [
                if_(eqz(field("List", "len", get("l"))), fail_(m, "pop: index -1 out of range: empty list")),
                set("i", op("i32.sub", field("List", "len", get("l")), i32(1))),
            ], set("i", call("rt_norm_index", a, field("List", "len", get("l")), S(m, "pop: "), S(m, "list")))),
            set("v", arr_get("Vals", field("List", "items", get("l")), get("i"))),
            arr_copy("Vals", field("List", "items", get("l")), get("i"),
                     field("List", "items", get("l")), op("i32.add", get("i"), i32(1)),
                     op("i32.sub", op("i32.sub", field("List", "len", get("l")), get("i")), i32(1))),
            setfield("List", "len", get("l"), op("i32.sub", field("List", "len", get("l")), i32(1))),
            ret(get("v")),
        ]),
        if_(is_("Set", x), [
            if_(eqz(is_null(a)), call("rt_fail", call("rt_str_concat", call("rt_str_concat", S(m, "pop: got "),
                call("rt_str", op("ref.i31", select_(is_null(b), i32(1), i32(2), I32)))), S(m, " arguments, want 0")))),
            set("sd", field("Set", "d", as_("Set", x))),
            check_mutable(m, field("Dict", "frozen", get("sd")), "pop: cannot delete from frozen hash table", "pop: cannot delete from hash table during iteration"),
            if_(eqz(field("Dict", "len", get("sd"))), fail_(m, "pop: empty set")),
            set("i", i32(0)),
            while_(is_null(arr_get("Vals", field("Dict", "keys", get("sd")), get("i"))), inc("i"), label = "first"),
            set("v", arr_get("Vals", field("Dict", "keys", get("sd")), get("i"))),
            drop(call("rt_dict_delete", non_null(get("sd")), get("v"))),
            ret(get("v")),
        ]),
        if_(is_("Dict", x), [
            if_(is_null(a), fail_(m, "pop: got 0 arguments, want at least 1")),
            check_mutable(m, field("Dict", "frozen", as_("Dict", x)), "pop: cannot delete from frozen hash table", "pop: cannot delete from hash table during iteration"),
            set("v", call("rt_dict_delete", as_("Dict", x), a)),
            if_(is_null(get("v")), [
                if_(eqz(is_null(b)), ret(b)),
                fail_(m, "pop: missing key"),
            ]),
            ret(get("v")),
        ]),
    ], locals = [("l", ref("List", True)), ("i", I32), ("v", V), ("sd", ref("Dict", True))])
    method("get", 2, [
        if_(is_("Dict", x), [
            set("v", call("rt_dict_get", as_("Dict", x), a)),
            if_(is_null(get("v")), ret(select_(is_null(b), NONE, b, V))),
            ret(get("v")),
        ]),
    ], locals = [("v", V)])
    method("setdefault", 2, [
        if_(is_("Dict", x), [
            set("v", call("rt_dict_get", as_("Dict", x), a)),
            if_(is_null(get("v")), [
                check_mutable(m, field("Dict", "frozen", as_("Dict", x)), "setdefault: cannot insert into frozen hash table", "setdefault: cannot insert into hash table during iteration"),
                set("v", select_(is_null(b), NONE, b, V)),
                call("rt_dict_set", as_("Dict", x), a, get("v")),
            ]),
            ret(get("v")),
        ]),
    ], locals = [("v", V)])

    # keys / values / items: fresh lists, in insertion order
    for name, which in [("keys", 0), ("values", 1), ("items", 2)]:
        if which == 0:
            elem = arr_get("Vals", field("Dict", "keys", get("d")), get("i"))
        elif which == 1:
            elem = arr_get("Vals", field("Dict", "vals", get("d")), get("i"))
        else:
            elem = new("Tuple", arr_fixed(
                "Vals",
                arr_get("Vals", field("Dict", "keys", get("d")), get("i")),
                arr_get("Vals", field("Dict", "vals", get("d")), get("i")),
            ))
        method(name, 0, [
            if_(is_("Dict", x), [
                set("d", as_("Dict", x)),
                set("out", call("rt_list_new", field("Dict", "len", get("d")))),
                for_i32("i", i32(0), field("Dict", "used", get("d")), [
                    if_(eqz(is_null(arr_get("Vals", field("Dict", "keys", get("d")), get("i")))),
                        call("rt_list_append", non_null(get("out")), elem)),
                ]),
                ret(get("out")),
            ]),
        ], locals = [("d", ref("Dict", True)), ("out", ref("List", True)), ("i", I32)])

    method("join", 1, [
        if_(is_("Str", x), [
            call("rt_want_iterable", a, S(m, "join")),
            set("t", _items(call("rt_iter", a))),
            set("buf", call("rt_buf_new")),
            for_i32("i", i32(0), arr_len(get("t")), [
                set("e", arr_get("Vals", get("t"), get("i"))),
                if_(eqz(is_("Str", get("e"))), type_err1(m, "join: in list, want string, got ", get("e"), "")),
                if_(get("i"), call("rt_buf_str", non_null(get("buf")), as_("Str", x))),
                call("rt_buf_str", non_null(get("buf")), as_("Str", get("e"))),
            ]),
            ret(call("rt_buf_to_str", non_null(get("buf")))),
        ]),
    ], locals = [("t", ref("Vals", True)), ("buf", ref("Buf", True)), ("i", I32), ("e", V)])

    # Lazy sequences (lib/runtime.star $Lazy): "abc".elems() iterates ["a",
    # "b", "c"]; elem_ords() byte values; codepoints() / codepoint_ords() the
    # UTF-8 sequences / code points; b"ab".elems() byte values.
    def lazy(kind):
        return new("Lazy", i32(kind), as_("Str", x))

    method("elems", 0, [
        if_(is_("Str", x), ret(lazy(LAZY_ELEMS))),
        if_(is_("Bytes", x), ret(new("Lazy", i32(LAZY_BYTES_ELEMS), bstr(x)))),
    ])
    method("elem_ords", 0, [if_(is_("Str", x), ret(lazy(LAZY_ELEM_ORDS)))])
    method("codepoints", 0, [if_(is_("Str", x), ret(lazy(LAZY_CODEPOINTS)))])
    method("codepoint_ords", 0, [if_(is_("Str", x), ret(lazy(LAZY_CODEPOINT_ORDS)))])

# Methods the compiler may call: name -> (min args, max args).
# (elem_ords is defined in _methods below, next to elems.)
METHODS = {
    "append": (1, 1),
    "extend": (1, 1),
    "pop": (0, 2),
    "get": (1, 2),
    "setdefault": (1, 2),
    "keys": (0, 0),
    "values": (0, 0),
    "items": (0, 0),
    "join": (1, 1),
    "elems": (0, 0),
    "elem_ords": (0, 0),
    "codepoints": (0, 0),
    "codepoint_ords": (0, 0),
}

def add_builtins(m):
    _misc(m)
    _slicing(m)
    _conversions(m)
    _files(m)
    _functions(m)
    _format(m)
    _sorting(m)
    _freezing(m)
    _intrinsics(m)
    _hashing(m)
    _structs(m)
    _methods(m)

def add_test_builtins(m):
    """Builtins for running starlark-go's own test files (tests/upstream/),
    as in its starlarktest package. Only programs compiled with --test can
    see them (they need add_runtime(m, test = True)); they are not part of
    the language:
      test_catch(f)          f()'s error message, or None if it succeeds
      test_error(msg)        report a test failure and carry on
      test_matches(pat, s)   s matches regular expression pat (host syntax)
      test_freeze(x)         deep-freeze x; returns it
      test_floateq(x, y)     x == y within 1 ULP"""
    # The host calls f() through this export, inside its own try/catch: a
    # Starlark error unwinds the Wasm frames in between. (Loops cut short
    # this way stay counted as iterating over their sequence.)
    add_func(m, "rt_test_call0", [("f", V)], [], [
        call("rt_call", get("f"), arr_new_default("Vals", i32(0)), null("eq")),
        "drop",
    ], export = "test_call0")
    add_func(m, "rt_test_catch", [("f", V)], [V], locals = [("n", I32)], body = [
        set("n", call("host_catch", get("f"))),
        if_(op("i32.lt_s", get("n"), i32(0)), ret(gget("None"))),
        new("Str", i32(0), call("rt_mem_take", get("n"))),
    ])
    add_func(m, "rt_test_error", [("msg", V)], [V], locals = [("b", U8A), ("n", I32)], body = [
        set("b", field("Str", "b", as_("Str", call("rt_str", get("msg"))))),
        set("n", arr_len(get("b"))),
        if_(op("i32.gt_s", get("n"), i32(65536)), set("n", i32(65536))),
        call("rt_mem_put", get("b"), i32(0), get("n")),
        call("host_test_error", i32(0), get("n")),
        gget("None"),
    ])
    # pattern at memory 0, the string right after it (64 KiB in all)
    add_func(m, "rt_test_matches", [("pat", V), ("s", V)], [V], locals = [
        ("p", U8A),
        ("b", U8A),
        ("np", I32),
        ("ns", I32),
        ("i", I32),
    ], body = [
        if_(eqz(is_("Str", get("pat"))), type_err1(m, "test_matches: for parameter pattern: got ", get("pat"), ", want string")),
        if_(eqz(is_("Str", get("s"))), type_err1(m, "test_matches: for parameter str: got ", get("s"), ", want string")),
        set("p", field("Str", "b", as_("Str", get("pat")))),
        set("b", field("Str", "b", as_("Str", get("s")))),
        set("np", arr_len(get("p"))),
        if_(op("i32.gt_s", get("np"), i32(4096)), fail_(m, "test_matches: pattern too long")),
        set("ns", arr_len(get("b"))),
        if_(op("i32.gt_s", op("i32.add", get("np"), get("ns")), i32(65536)), set("ns", op("i32.sub", i32(65536), get("np")))),
        call("rt_mem_put", get("p"), i32(0), get("np")),
        for_i32("i", i32(0), get("ns"), [
            op("i32.add", get("np"), get("i")),
            arr_get_u("U8", get("b"), get("i")),
            ("i32.store8", 0),
        ]),
        call("rt_bool", call("host_matches", get("np"), get("ns"))),
    ])
    add_func(m, "rt_test_freeze", [("v", V)], [V], [call("rt_freeze", get("v")), get("v")])
    add_func(m, "rt_test_floateq", [("x", V), ("y", V)], [V], [
        if_(eqz(call("rt_is_num", get("x"))), type_err1(m, "test_floateq: got ", get("x"), ", want float")),
        if_(eqz(call("rt_is_num", get("y"))), type_err1(m, "test_floateq: got ", get("y"), ", want float")),
        call("rt_bool", call("host_floateq", call("rt_f64", get("x")), call("rt_f64", get("y")))),
    ])
