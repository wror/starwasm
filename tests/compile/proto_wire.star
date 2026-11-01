# proto.marshal / proto.unmarshal / proto.marshal_text / proto.unmarshal_text.
# protobuf-go writes the fields of a dynamic message in random order, so
# bytes are compared only for messages with one field; everything else
# goes through a round trip.
p3 = proto.file("p3.proto")
p2 = proto.file("p2.proto")
ed = proto.file("editions.proto")
ft = proto.file("features.proto")

def rt(m):
    data = proto.marshal(m)
    back = proto.unmarshal(m.descriptor, data)
    text = proto.marshal_text(m)
    back2 = proto.unmarshal_text(m.descriptor, text)
    print(back)
    print(text)
    print(back2 == back, str(back2) == str(back), str(back) == str(m))

# one field each: exact bytes
for kw in [
    {"d": 1.5}, {"f": -2.25}, {"i32": -1}, {"i32": 300}, {"i64": -9223372036854775808}, {"u32": 4294967295},
    {"u64": 18446744073709551615}, {"s32": -1}, {"s32": 2147483647}, {"s64": -9223372036854775808},
    {"fx32": 4294967295}, {"fx64": 1 << 63}, {"sfx32": -2}, {"sfx64": -3}, {"b": True}, {"s": "héllo"},
    {"by": b"\x00\x01\xff"}, {"color": "BLUE"}, {"opt_i32": 0}, {"opt_s": ""},
]:
    m = p3.Scalars(**kw)
    print(kw, proto.marshal(m) == proto.marshal(proto.unmarshal(p3.Scalars, proto.marshal(m))), list(proto.marshal(m).elems()))
for kw in [{"i32s": [1, -1, 300]}, {"u64s": [0, 1 << 63]}, {"s32s": [-1, 1]}, {"ds": [0.5]}, {"fs": [1, 2]},
           {"bs": [True, False]}, {"ss": ["a", ""]}, {"bys": [b"x"]}, {"colors": [0, 1, -3]}, {"unpacked": [1, -2]},
           {"fx32s": [1, 2]}, {"msgs": [{"i32": 1}, {}]}, {"u32s": []}]:
    m = p3.Repeats(**kw)
    print(kw, list(proto.marshal(m).elems()))
for kw in [{"s2i": {"a": 1}}, {"i2s": {-1: ""}}, {"b2c": {False: 0}}, {"i2m": {7: {}}}, {"u2b": {1: b"\xff"}}, {"s2d": {-2: 0.0}}]:
    m = p3.Maps(**kw)
    print(kw, list(proto.marshal(m).elems()))
print(list(proto.marshal(p3.Node(sub = {"x": 1})).elems()), list(proto.marshal(p3.Empty()).elems()))
print(list(proto.marshal(p2.Legacy(id = 3)).elems()), list(proto.marshal(p2.Holder(legacy = {"id": 1})).elems()))
print(list(proto.marshal(p2.Legacy(id = 3, grp = {})).elems()))
print(list(proto.marshal(ft.Feat(req = 0)).elems()), list(proto.marshal(ft.Feat(req = 1)).elems()))

# round trips
rt(p3.Scalars(d = 0.1, f = 0.1, i32 = -5, i64 = 1 << 40, u32 = 7, u64 = 1 << 64 - 1, s32 = -9, s64 = -(1 << 50),
              fx32 = 1, fx64 = 2, sfx32 = -3, sfx64 = -4, b = True, s = "tab\t\"q\" \\ é \x7f", by = b"\x00\x80\xff'",
              color = "GREEN", opt_i32 = 0, opt_s = "o"))
rt(p3.Scalars(d = float("inf"), f = float("-inf")))
rt(p3.Scalars(d = 1e100, f = 3.4e38))
rt(p3.Scalars(d = 1e-7, f = 123456789))
rt(p3.Scalars(d = -0.0, f = 1e6))
rt(p3.Repeats(i32s = [1, -1], u64s = [1 << 63], s32s = [-5], ds = [0.25], fs = [1.1], bs = [True], ss = ["x", "y"],
              bys = [b"z"], colors = [1, 2], msgs = [{"i32": 1}, {"s": "s"}], unpacked = [3, -3], fx32s = [9], u32s = [8]))
rt(p3.Maps(s2i = {"b": 2, "a": 1}, i2s = {3: "c", -1: "z"}, b2c = {True: "RED", False: 2}, i2m = {5: {"s": "five"}, 1: {}},
           u2b = {0: b""}, s2d = {-1: 0.5}, s2s = {"": ""}))
rt(p3.Node(name = "root", left = {"name": "l"}, kids = [{"name": "k1"}, {}],
           inner = {"x": 1, "kind": "LEAF"}, text = "t", legacy = {"id": 1, "grp": {"a": 1}}))
rt(p3.Node(sub = {}))
rt(p3.Empty())
l = p2.Legacy(id = 1, name = "n", count = 0, ratio = 0.5, tiny = 1, flag = False, raw = b"r", size = "LARGE", big = 5,
              nums = [1, 2], packed_nums = [3, 4], grp = {"a": 1, "b": "b"}, child = {"id": 2}, nan = 0, esc = "e", neg = -2)
proto.set_field(l, p2.ext_i, 7)
proto.set_field(l, p2.Holder.nested_ext, "ne")
proto.set_field(l, p2.ext_msg, {"legacy": {"id": 9}})
print(proto.marshal_text(l))
back = proto.unmarshal(p2.Legacy, proto.marshal(l))
print(back, proto.has(back, p2.ext_i))
print(proto.marshal_text(back))
rt(ed.Test(string_field = "s", int32_field = 5, repeated_field = ["a", "b"], map_field = {"k": "v", "a": "b"}))
rt(ft.Feat(implicit_i = 0, explicit_i = 0, packed = [1, 2], expanded = [3, 4], closed = "TWO", delimited = {"s": "d", "req": 1}, s = "", req = 0))

# hand-made input: unknown fields (kept and written back), merging, wire
# type mismatches, packed and unpacked repeated fields, map entries with
# missing parts, groups
def u(desc, data):
    m = proto.unmarshal(desc, data)
    print(m, list(proto.marshal(m).elems()) if len(str(m)) < 30 else "")
    return m
u(p3.Scalars, b"\x18\x05\xa0\x06\x01")  # i32=5, field 100 varint (unknown)
u(p3.Scalars, b"\x18\x05\x18\x06")  # last one wins
u(p3.Scalars, b"\x1d\x01\x00\x00\x00")  # i32 with a fixed32 wire type: unknown
u(p3.Scalars, b"\xfa\x3e\x02hi")  # field 1007 bytes: unknown
u(p3.Scalars, b"\x0b\x10\x01\x0c")  # a group field 1 (wire type mismatch for d): unknown
u(p3.Repeats, b"\x08\x01\x08\x02\x0a\x02\x03\x04")  # i32s unpacked and packed
u(p3.Repeats, b"\x58\x01\x5a\x01\x02")  # unpacked (field 11) given packed too
u(p3.Maps, b"\x0a\x00\x0a\x03\x0a\x01a\x0a\x05\x10\x07\x0a\x01b")  # entries without key/value; value before key
u(p3.Maps, b"\x1a\x04\x08\x01\x12\x00\x1a\x02\x08\x02")  # message values
u(p3.Node, b"\x2a\x02\x08\x01\x2a\x02\x10\x01")  # inner merged
u(p3.Node, b"\x30\x01\x3a\x01t")  # oneof: the last one wins
u(p3.Node, b"\x3a\x01t\x30\x00")
u(p2.Legacy, b"\x08\x01\x63\x68\x05\x72\x01x\x64")  # group
u(p2.Legacy, b"\x08\x01\xa0\x06\x05")  # the extension ext_i is an unknown field
u(p3.Scalars, b"")
u(p3.Scalars, b"\x18\xff\xff\xff\xff\x0f")  # int32 from a 5-byte varint
u(p3.Scalars, b"\x18\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01")  # -1
u(p3.Scalars, b"\x38\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01")  # sint32 from a 64-bit varint

# the text format, by hand
def t(desc, text):
    print(proto.unmarshal_text(desc, text))
t(p3.Scalars, "")
t(p3.Scalars, "i32: 5 s: 'single' by: \"\\x01\\001\\n\" color: BLUE")
t(p3.Scalars, "i32:-5,u32:0x1f;i64: -0x10 u64: 017 b: t d: 1.5f f: inf")
t(p3.Scalars, "d: -inf f: -Infinity b: 1 color: 2 s: 'a' \"b\" 'c'")
t(p3.Scalars, "# comment\n  i32 : 1 # another\n s: \"\\u00e9\\U0001F600\\ud83d\\ude00\"")
t(p3.Scalars, "d: 1e10 f: .5 i64: - 5 s32: -2147483648 b: False")
t(p3.Repeats, "i32s: [1, 2, 3] i32s: 4 msgs: [{i32: 1}, <s: 'x'>] msgs {} ss: [] colors: [RED, 2]")
t(p3.Maps, "s2i {key: 'a' value: 1} s2i: [{key: 'b' value: 2}, {}] i2m {key: 5 value {i32: 1}} b2c {value: RED}")
t(p3.Node, "name: 'n' left {name: 'l' kids [{name: 'k'}]} inner <x: 3 kind: LEAF> sub {x: 1};")
t(p2.Legacy, "id: 1 Grp { a: 1 } nums: 1 nums: [2] child { id: 2 }")
t(ed.Test, "string_field: 's' map_field {key: 'k' value: 'v'} repeated_field: ['a', 'b']")
t(ft.Feat, "req: 0 delimited { s: 'x' req: 1 } closed: TWO")
