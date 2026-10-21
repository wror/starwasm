# demo.star — milestone 1: Starlark builds a Wasm module and writes it out.
#
#   bin/starhost examples/demo.star out/demo.wasm
#   node host/run.mjs out/demo.wasm answer      # -> 42
#   node host/run.mjs out/demo.wasm main        # -> 0! .. 20!

load("../lib/wasm.star", "I32", "I64", "add_func", "encode", "import_func", "new_module")

# An emit-time "macro": an ordinary Starlark function that returns Wasm
# code for a counted loop. The Starlark `for`/`if` never runs at Wasm
# runtime; it only decides what gets emitted.
def for_range(var, lo, hi, body):
    return [
        ("i64.const", lo),
        ("local.set", var),
        ("block", None),
        ("loop", None),
        ("local.get", var),
        ("i64.const", hi),
        "i64.ge_s",
        ("br_if", 1),  # exit the block when var >= hi
        body,
        ("local.get", var),
        ("i64.const", 1),
        "i64.add",
        ("local.set", var),
        ("br", 0),  # back to loop head
        "end",
        "end",
    ]

m = new_module()

import_func(m, "host", "print_i64", [I64], [])

add_func(
    m,
    "answer",
    params = [],
    results = [I32],
    body = [("i32.const", 42)],
    export = True,
)

# fact(n) = 1 if n < 2 else n * fact(n - 1)    (recursive, i64)
add_func(
    m,
    "fact",
    params = [("n", I64)],
    results = [I64],
    body = [
        ("local.get", "n"),
        ("i64.const", 2),
        "i64.lt_s",
        ("if", I64),
        ("i64.const", 1),
        "else",
        ("local.get", "n"),
        ("local.get", "n"),
        ("i64.const", 1),
        "i64.sub",
        ("call", "fact"),
        "i64.mul",
        "end",
    ],
    export = True,
)

add_func(
    m,
    "main",
    params = [],
    results = [],
    locals = [("i", I64)],
    body = for_range("i", 0, 21, [
        ("local.get", "i"),
        ("call", "fact"),
        ("call", "print_i64"),
    ]),
    export = True,
)

out = argv[0] if argv else "out/demo.wasm"
write_file(out, encode(m))
