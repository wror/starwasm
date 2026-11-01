# The proto module (starlark-go's lib/proto): descriptors, messages,
# repeated and map fields, enums. Schemas: tests/proto/*.proto, compiled
# into tests/proto/test.binpb (see tests/proto/README.md).
p3 = proto.file("p3.proto")
p2 = proto.file("p2.proto")
print(proto, type(proto), dir(proto))
print(p3, type(p3), dir(p3), p3 == proto.file("p3.proto"))
print(p3.Scalars, type(p3.Scalars), dir(p3.Scalars), dir(p3.Node))
print(p3.Node.Inner, p3.Node.Inner.Kind, p3.Node.Inner.Kind.LEAF, p3.Node.name, type(p3.Node.name), dir(p3.Node.name))
print(type(proto.file), proto.file, proto.marshal, proto.unmarshal_text)
f = proto.has
print(f, f(p3.Scalars(i32 = 1), "i32"))

# enums
C = p3.Color
print(C, type(C), dir(C), C.RED, type(C.RED), dir(C.RED), str(C.BLUE), repr(C.GREEN))
print(C.RED.index, C.RED.name, C.RED.number, C.RED.type, C.BLUE.number, C(2), C("BLUE"), C(-3), C(C.RED))
print(C.RED == C(1), C.RED == 1, C.RED != C.GREEN, C.RED.type == C, C == p3.Color, {C.RED: 1}[C("RED")])
print(p2.Size.BIG, p2.Size(3), p2.Size.LARGE == p2.Size.BIG, p2.Size.BIG.index)

# scalars
s = p3.Scalars()
print(s, s.d, s.f, s.i32, s.i64, s.u32, s.u64, s.s32, s.s64, s.fx32, s.fx64, s.sfx32, s.sfx64, s.b, repr(s.s), s.by, s.color, s.opt_i32, s.opt_s)
print(proto.has(s, "i32"), proto.has(s, "opt_i32"), proto.has(s, p3.Scalars.color))
s.i32 = 0
s.opt_i32 = 0
s.color = 0
s.s = ""
print(s, proto.has(s, "i32"), proto.has(s, "opt_i32"), proto.has(s, "color"))
s.d = 0.1
s.f = 0.1
s.i32 = -2147483648
s.i64 = -9223372036854775808
s.u32 = 4294967295
s.u64 = 18446744073709551615
s.s32 = -5
s.s64 = 1 << 62
s.fx32 = 7
s.fx64 = 1 << 63
s.sfx32 = -1
s.sfx64 = -2
s.b = True
s.s = "héllo"
s.by = "abc"
s.color = "GREEN"
s.opt_s = "x"
print(s)
print(s.f, s.d, s.by, type(s.by), s.color, type(s.color), s.u64)
s.by = b"\x00\xff"
s.d = 3
s.f = 1
s.color = C.BLUE
print(s.by, s.d, s.f, s.color)
s.d = -0.0
print(s, proto.has(s, "d"))
s.opt_s = None
s.color = None
print(s)
print(p3.Scalars(d = float("inf"), f = float("-inf")), p3.Scalars(d = float("nan")))

# construction
print(p3.Scalars(i32 = 1, s = "a"), p3.Scalars({"i32": 2}), p3.Scalars(p3.Scalars(i32 = 3, opt_s = "z")), p3.Scalars())
n = p3.Node(name = "root", left = {"name": "l"}, right = p3.Node(name = "r"), inner = {"x": 4, "kind": "LEAF"})
print(n, n.left.name, n.right, n.inner.kind, n.inner.x)
print(n.descriptor, n.inner.descriptor, n.descriptor == p3.Node)

# oneofs
n = p3.Node(num = 3)
print(n, n.num, repr(n.text), proto.has(n, "num"), proto.has(n, "text"))
n.text = "t"
print(n, proto.has(n, "num"), n.num, n.text)
n.sub = {"x": 9}
print(n, n.sub, n.text)
n.num = 0
print(n, proto.has(n, "num"))

# submessages: defaults are frozen empty messages; values alias
m = p3.Node()
print(m.left, m.left.left, proto.has(m, "left"), m.inner == m.inner)
i = p3.Node.Inner(x = 1)
m.inner = i
i.x = 2
print(m.inner.x, m)
m2 = p3.Node(m)
m2.inner.x = 3
print(m.inner.x, m2.inner.x)
m.inner = None
print(m, m2)

# repeated fields
r = p3.Repeats(i32s = [3, 1, 2], ss = ["a", "b"], msgs = [{"i32": 1}, p3.Scalars(s = "x")], colors = [1, "GREEN", C.BLUE])
print(r)
print(type(r.i32s), type(r.msgs), type(r.colors), type(r.u64s), r.i32s, len(r.i32s), r.i32s[0], r.i32s[-1], list(r.i32s))
print(sorted(r.i32s), tuple(r.i32s), max(r.i32s), "-".join(r.ss), list(enumerate(r.ss)), [x * 2 for x in r.i32s], r.colors[2], r.msgs[1].s)
print(bool(r.i32s), bool(r.u64s), r.u64s, dir(r.i32s), r.i32s.append, type(r.i32s.append))
r.i32s.append(10)
r.i32s[0] = 30
r.i32s[-2] = 20
print(r.i32s)
a = r.i32s
a.append(4)
print(r.i32s, a)
r.i32s = [7]
print(r.i32s, a)
r.i32s = (1, 2)
r.ss = r.ss
print(r)
r.fs = [0.1, 2]
r.ds = range(3)
r.bs = [True, False]
r.bys = ["a", b"b"]
r.u32s = []
print(r)
r.i32s = None
r.msgs[0].i32 = 5
print(r, r.i32s)
for x in r.msgs:
    print(x)
print([m.s for m in r.msgs], all(r.bs), any(r.bs), min(r.ds), list(reversed(r.ds)), zip(r.ds, r.fs))

# map fields
mp = p3.Maps(s2i = {"b": 2, "a": 1}, i2s = {3: "c", -1: "z"}, b2c = {True: "RED", False: 2}, i2m = {5: {"s": "five"}})
print(mp)
print(type(mp.s2i), type(mp.i2m), type(mp.b2c), mp.s2i, len(mp.s2i), mp.s2i["a"], mp.i2s[-1], mp.b2c[True], mp.i2m[5].s)
print(dict(mp.s2i), list(mp.s2i), sorted(mp.s2i), [k for k in mp.i2s], "a" in mp.s2i, "z" in mp.s2i, 1 in mp.s2i, str(mp.s2i))
d = {"x": 0}
d.update(mp.s2i)
print(d, dict(mp.i2s), bool(mp.s2i), bool(mp.s2d), mp.s2d, dir(mp.s2i))
mp.s2i["c"] = 3
mp.s2i["a"] = 10
mp.i2m[6] = p3.Scalars(i32 = 6)
print(mp.s2i, mp.i2m)
mp.s2i = {"z": 26}
print(mp.s2i)
mp.s2i = mp.i2s and {"q": 1}
mp.s2s = {"k": "v"}
mp.u2b = {1: "one", 2: b"\x02"}
mp.s2d = {-5: 1, 3: 0.5}
print(mp)
mp.s2i = None
print(mp.s2i, proto.has(mp, "s2i"))

# hashing and equality of the values
x = {p3: 1, p3.Scalars: 2, C: 3, C.RED: 4, p3.Scalars.i32: 5}
s1 = p3.Scalars()
x[s1] = 6
print(x[p3], x[p3.Scalars], x[C], x[C(1)], x[p3.Scalars.i32], x[s1], s1 == s1, s1 == p3.Scalars(), s1 != s1)
print(r.i32s == r.i32s, mp.s2i == mp.s2i, p3.Scalars == p3.Node, proto == proto)

# proto2: defaults, required, groups
l = p2.Legacy(id = 1)
print(l, l.name, l.count, l.ratio, l.tiny, l.flag, l.raw, l.size, l.big, l.nan, l.esc, l.neg, l.grp, l.child.name)
print(proto.has(l, "name"), dir(l))
l.name = "anon"
l.grp = {"a": 1, "b": "bee"}
print(l, proto.has(l, "name"), l.grp.b)

# extensions
print(p2.ext_i, type(p2.ext_i), p2.Holder.nested_ext, p2.Holder.legacy, dir(p2), dir(p2.Holder), dir(p2.ext_i))
print(proto.has(l, p2.ext_i))
proto.set_field(l, p2.ext_i, 5)
proto.set_field(l, p2.Holder.nested_ext, "ne")
proto.set_field(l, p2.ext_size, "SMALL")
print(l, proto.get_field(l, p2.ext_i), proto.get_field(l, p2.ext_size), proto.has(l, p2.ext_i), proto.has(l, p2.Holder.nested_ext))
print(proto.get_field(p3.Scalars(i32 = 3), p3.Scalars.i32))
m = p3.Scalars()
proto.set_field(m, p3.Scalars.i32, 9)
print(m)

# editions
ed = proto.file("editions.proto")
t = ed.Test(string_field = "s", int32_field = 0, repeated_field = ["a"], map_field = {"k": "v"})
print(t, proto.has(t, "int32_field"), type(t.repeated_field), type(t.map_field), ed.ext_string_field)
ft = proto.file("features.proto")
fe = ft.Feat(implicit_i = 0, explicit_i = 0, closed = "TWO", req = 0)
print(fe, proto.has(fe, "implicit_i"), proto.has(fe, "explicit_i"), fe.delimited, ft.Closed(1))
fe.delimited = {"s": "d"}
print(fe)
