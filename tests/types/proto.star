# The proto module, typed from the schema (tests/proto/*.proto, given as
# --descriptor_set=tests/proto/test.binpb by tests/types.sh).
p3 = proto.file("p3.proto")
p2 = proto.file("p2.proto")

# enums: values by attribute, by number, by name
C = p3.Color
red = C.RED
green = C("GREEN")
blue = C(-3)
same = C(red)
kind = p3.Node.Inner.Kind.LEAF
size = p2.Size.BIG
number = red.number
label = red.name + "/" + str(red.index)
enum_of = red.type

# messages: made by field, from a dict or another message; fields read
s = p3.Scalars(i32 = 1, s = "a", by = "raw", color = "RED", d = 2)
copy = p3.Scalars(s)
from_dict = p3.Scalars({"i32": 2})
n = p3.Node(name = "root", left = {"name": "l"}, right = p3.Node(name = "r"), inner = p3.Node.Inner(x = 4))
name = n.name
depth = n.left.left.left.name
inner_x = n.inner.x
inner_kind = n.inner.kind
oneof_num = n.num
legacy = n.legacy.size
desc = n.descriptor
ratio = p2.Legacy(id = 1).ratio

# fields assigned (None clears one)
s.i32 = 7
s.i32 += 1
s.d = 3
s.f = 0.5
s.by = b"\x00"
s.color = 2
s.color = C.BLUE
s.opt_s = None
n.inner = {"x": 9}

# repeated and map fields
r = p3.Repeats(i32s = [3, 1, 2], ss = ["a", "b"], msgs = [p3.Scalars(s = "x")], ds = range(3))
nums = r.i32s
first = r.i32s[0]
total = len(r.i32s)
doubled = [x * 2 for x in r.i32s]
joined = "-".join(r.ss)
ordered = sorted(r.i32s)
r.i32s.append(10)
r.i32s[0] = 30
r.msgs.append({"i32": 5})
r.colors = ["RED", "GREEN"]
r.bys = ("a", "b")
texts = [m.s for m in r.msgs]

mp = p3.Maps(s2i = {"b": 2, "a": 1}, i2m = {5: p3.Scalars(s = "five")})
count = mp.s2i["a"]
keys = sorted(mp.s2i)
has_a = "a" in mp.s2i
as_dict = dict(mp.i2s)
five = mp.i2m[5].s
mp.s2i["c"] = 3
mp.b2c[True] = "BLUE"

# the module's functions
present = proto.has(s, "i32") and proto.has(s, p3.Scalars.color)
field = p3.Scalars.i32
value = proto.get_field(s, field)
ext = proto.get_field(p2.Legacy(id = 1), p2.ext_ss)
proto.set_field(s, p3.Scalars.s, "z")
wire = proto.marshal(s)
back = proto.unmarshal(p3.Scalars, wire)
text = proto.marshal_text(back)
again = proto.unmarshal_text(p3.Node, "name: 'x'")

# defs: a message is read like a struct of its fields; what a def stores
# in one is checked where it is called
def label_of(m):
    return m.name + ":" + str(len(m.kids))

def set_bytes(m, v):
    m.by = v
    return m

def parse(desc, data):
    return proto.unmarshal(desc, data)

def names(nodes):
    return [x.name for x in nodes]

labelled = label_of(n)
stored = set_bytes(s, "text")
parsed = parse(p3.Node, wire)
kid_names = names(n.kids)
