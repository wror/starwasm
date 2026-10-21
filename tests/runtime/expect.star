# Reference program, run by starlark-go. tests/runtime/build.star builds the
# same program as Wasm on top of the generated runtime; test.sh checks that
# both print exactly the same lines. Keep the two files in the same order.

# ints: small/boxed boundary, normalization, floor semantics, bit ops
print(42)
print(-7)
print(1073741823 + 1)
print(-1073741824 - 1)
print(1073741824 - 1)
print(1073741824 - 1 == 1073741823)
print(123456789 * 1000)
print(-7 // 2)
print(-7 % 2)
print(7 % -2)
print(7 // -2)
print(1 << 40)
print(-1 >> 3)
print(0xff & 0x0f | 0x100 ^ 1)
print(9223372036854775807)
print(-9223372036854775807 - 1)
print(str(-1234567890123))
print(-(5))

# strings
print("hello" + " " + "world")
print(repr("tab\there \"q\" \\ \x01 é"))
print("ab" * 3)
print("hello"[1])
print("lo" in "hello")
print("x" in "hello")
print(len("héllo"))
print(str((1, "a")))
print(repr("x"))
print(str("x"))

# containers and repr
print([1, "a", None, True, (2,), (3, 4), [], {}])
print([1] + [2, 3])
print((1,) + (2,))
print([0] * 3)
print(2 * (1, "x"))
print(2 in [1, 2, 3])
print([10, 20, 30][-1])
print((10, 20, 30)[0])

# dicts: insertion order, overwrite, mixed key types, boxed-int keys
d = {}
d["b"] = 1
d["a"] = 2
d[3] = "three"
d[(1, 2)] = None
d["b"] = 10
d[1 << 40] = "big"
print(d)
print(len(d))
print(d["a"])
print("a" in d)
print("z" in d)
print(d[(1 << 41) // 2])

# growth
d2 = {}
for i in range(100):
    d2[i * 7] = str(i)
print(len(d2))
print(d2[693])
print(d2[0])
l = []
for i in range(50):
    l.append(i * i)
print(l[49])
print(l[-1])
print(len(l))
s = 0
for k in d2:
    s = s + k
print(s)

# equality and ordering
print([1, (2, "x")] == [1, (2, "x")])
print([1, (2, "x")] == [1, (2, "y")])
print((1, 2) < (1, 3))
print([1, 2] < [1, 2, 0])
print("abc" < "abd")
print("b" < "abc")
print({"a": 1, "b": 2} == {"b": 2, "a": 1})

# type() and truthiness
print(type(1))
print(type(1 << 40))
print(type("s"))
print(type([]))
print(type(()))
print(type({}))
print(type(None))
print(type(True))
print(not [])
print(not [0])
print(not "")
print(not 0)
print(not None)
