l = [3, 1, 2]
l.append(4)
l.extend([5, 6])
l.extend((7,))
print(l, len(l), l.pop(), l.pop(0), l)
a = []
b = a
b += [1, 2]
print(a, a == b)
t = (1, 2)
u = t
u += (3,)
print(t, u)
d = {"one": 1, "two": 2}
print(d.get("one"), d.get("three"), d.get("three", 3), d.setdefault("two", 22), d.setdefault("four", 4))
print(d.keys(), d.values(), d.items())
print(d.pop("one"), d.pop("zzz", "dflt"), d)
d["one"] = 111
print(d, len(d), "one" in d)
nested = {"k": [1, {"x": (2, 3)}]}
nested["k"][1]["y"] = [4]
print(nested)
(p, q), r = (1, 2), 3
[s1, s2] = "ab".elems()
print(p, q, r, s1, s2)
for i, (x, y) in enumerate([(1, 2), (3, 4)]):
    print(i, x, y)
print(list((1, 2)), tuple([3, 4]), list(), tuple(), dict(), list({"a": 1}))
print([[i, j] for i in range(3) for j in range(i)])
print({i: i * i for i in range(4) if i})
x = "outer"
print([x for x in range(3)], x)
print([1, [2, (3,)]] == [1, [2, (3,)]], (1, 2) < (1, 2, 0), [] < [0], {"a": 1} == {"a": 1})
m = {}
for i in range(200):
    m[i] = i
for i in range(0, 200, 2):
    m.pop(i)
print(len(m), m.get(1), m.get(2), list(m.keys())[:5])
for i in range(1000, 1010):
    m[i] = -i
print(len(m), m[1009], list(m.values())[-3:])
grid = [[0] * 3 for _ in range(2)]
grid[1][2] = 9
print(grid, list(range(10, 0, -3)), list(range(3)))
