# builtins and methods as values
fs = [print, len, str, repr, type, bool, int, list, tuple, dict, range, enumerate, sorted,
      min, max, zip, reversed, all, any, hasattr, getattr, dir, ord, chr, abs, set, bytes, struct, fail]
print([str(f) for f in fs])
print(len == len, min == min, len != str, {len: 1, min: 2}[min])
print(bool(), bool(0), bool([1]), list(), list("ab".elems()), tuple(), tuple([1]), dict())
calls = [
    (len, ["abc"]), (str, [1]), (repr, ["x"]), (type, [()]), (bool, [1]), (int, ["42"]),
    (list, [(1, 2)]), (tuple, [[1]]), (dict, []), (enumerate, [["a"]]),
    (sorted, [[3, 1, 2]]), (min, [3, 1]), (max, [[3, 1]]), (zip, [[1, 2], "ab".elems()]),
    (reversed, [[1, 2]]), (all, [[1, 0]]), (any, [[1, 0]]), (hasattr, ["", "split"]),
    (getattr, [{}, "keys"]), (dir, [[]]), (ord, ["a"]), (chr, [98]), (abs, [-3]),
    (set, [[1, 1]]), (bytes, ["hi"]), (struct, []),
]
for f, args in calls:
    print(f, f(*args))
print(list(range(3)), list(range(1, 4)), list(range(10, 0, -3)))
print(sorted([3, 1, 2], reverse = True), sorted(["b", "A"], key = len))
srt = sorted
print(srt(["bb", "a", "ccc"], key = len, reverse = True))
mx = max
print(mx([1, 5, 2], key = lambda x: -x), mx(1, 2))
s = "a-b-c"
sp = s.split
print(sp("-"), sp("-", 1), type(sp), sp)
l = [1]
ap = l.append
ap(2)
ap(3)
print(l, ap, [].append == [].append, ap == ap)
d = {"a": 1}
g = d.get
d["b"] = 2
print(g("b"), g("z", "dflt"), g("z"), d.keys, d.items())
it = d.items
print(it(), sorted(d.values()))
st = set([1, 2])
ad = st.add
ad(3)
print(st, st.union, st.issubset)
up = "abc".upper
print(up(), [up() for _ in range(2)])
fmt = "{}-{}".format
print(fmt(1, 2), fmt(b"x", "y"))
pop = [1, 2, 3].pop
print(pop(), pop(0))
j = ", ".join
print(j(["x", "y"]))
print(getattr("abc", "upper")(), getattr([], "nope", 42), getattr(d, "get")("a"), hasattr(d, "nope"))
meth = "upper"
print(getattr("xy", meth)(), getattr([3], "index")(3))
print(type(len), type(min), type(ap), type(lambda: 1), str(len), repr(ap))
def apply(f, *args):
    return f(*args)
print(apply(len, "abcd"), apply("x".join, ["a", "b"]), apply(max, 1, 9, 3))
print([f("xy") for f in [len, str, repr]])
