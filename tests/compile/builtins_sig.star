print(int("ff", 16), int("0x10", 0), int("-0b101", 0), int("z", 36), int("0o17", 8), int("010", 8), int("0", 0), int("-0x1F", 16), int("+7", 0), int("000", 0))
print(int(True), int(x = 3.7), int(base = 10, x = "7"), int("123456789012345678901234567890"), int("-0"), int(-2.5), int("Ab", 16), int("0B11", 0))
print(dict([("a", 1)], b = 2), dict(a = 1), dict({"x": 1}), dict(), dict([]), dict([["k", "v"]]), dict({"x": 1}, x = 2), dict(set([(1, 2)])))
print(enumerate(["a", "b"], 1), enumerate("xy".elems(), -3), enumerate([]), enumerate(range(2), 1 << 40))
print(sorted([3, 1, 2], reverse = True), sorted(["b", "a"], key = len), len(*["ab"]), "a-b".split(*["-"]), max(*[1, 5]), "a".join(*[["x", "y"]]))
f = int
g = dict
print(f("10", 2), g(z = 1), str(1), type(1), str(b"x"), "abc".startswith("b", 1), "x".endswith(("y", "x")))
def k(a, b = 2, *c, d = 4, **e):
    return [a, b, c, d, e]
print(k(1), k(1, 2, 3, d = 5, z = 6), k(*[1, 2], **{"d": 0}))
