# Unit tests for lib/wasm.star. Run: bin/starhost tests/wasm_test.star

load("../lib/wasm.star", "EQREF", "I32", "I8", "add_func", "add_type", "array_type", "encode", "flatten", "new_module", "ref", "sleb", "struct_type", "uleb")

failures = []

def check_eq(what, got, want):
    if got != want:
        failures.append("%s: got %r, want %r" % (what, got, want))

# Reference values from the LEB128 Wikipedia article and the Wasm spec.
check_eq("uleb(0)", uleb(0), [0x00])
check_eq("uleb(127)", uleb(127), [0x7f])
check_eq("uleb(128)", uleb(128), [0x80, 0x01])
check_eq("uleb(624485)", uleb(624485), [0xe5, 0x8e, 0x26])
check_eq("sleb(0)", sleb(0), [0x00])
check_eq("sleb(-1)", sleb(-1), [0x7f])
check_eq("sleb(63)", sleb(63), [0x3f])
check_eq("sleb(64)", sleb(64), [0xc0, 0x00])
check_eq("sleb(-64)", sleb(-64), [0x40])
check_eq("sleb(-65)", sleb(-65), [0xbf, 0x7f])
check_eq("sleb(-123456)", sleb(-123456), [0xc0, 0xbb, 0x78])
check_eq("sleb(i64 min)", sleb(-(1 << 63)), [0x80] * 9 + [0x7f])

check_eq(
    "flatten",
    flatten(["a", [("b", 1), ["c"]], [], ("d",)]),
    [("a",), ("b", 1), ("c",), ("d",)],
)

# The smallest useful module: () -> i32 returning 42. Bytes checked by hand
# against the spec's binary format.
m = new_module()
add_func(m, "f", [], [I32], [("i32.const", 42)], export = True)
check_eq("answer module", encode(m, names = False), [
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,  # magic, version
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,  # type: () -> i32
    0x03, 0x02, 0x01, 0x00,  # function: one func of type 0
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,  # export "f" = func 0
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b,  # code: i32.const 42; end
])

# GC types: one rec group, every type marked `sub final`. Checked against
# the WasmGC binary format (rec = 0x4e, sub final = 0x4f, struct = 0x5f,
# array = 0x5e, ref null $t = 0x63 t, packed i8 = 0x78, eqref = 0x6d).
g = new_module()
add_type(g, "P", struct_type([("x", I32, True), ("next", ref("P", True), False)]))
add_type(g, "B", array_type(I8, True))
add_type(g, "V", array_type(EQREF, False))
check_eq("gc type section", encode(g, names = False), [
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x16,  # type section, 22 bytes
    0x01, 0x4e, 0x03,  # 1 rec group of 3 types
    0x4f, 0x00, 0x5f, 0x02, 0x7f, 0x01, 0x63, 0x00, 0x00,  # P: struct {mut i32, (ref null P)}
    0x4f, 0x00, 0x5e, 0x78, 0x01,  # B: array (mut i8)
    0x4f, 0x00, 0x5e, 0x6d, 0x00,  # V: array eqref
])

# Encoding is deterministic: same input, same bytes.
check_eq("determinism", encode(m), encode(m))

if failures:
    fail("%d failure(s):\n  %s" % (len(failures), "\n  ".join(failures)))
print("wasm_test: ok")
