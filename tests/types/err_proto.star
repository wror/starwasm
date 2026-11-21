# Mistakes with protocol buffers, found from the schema.
p3 = proto.file("p3.proto")
p4 = proto.file("p4.proto")
S = p3.Scalar
s = p3.Scalars(i33 = 1)
t = p3.Scalars(i32 = "one", color = "REDD")
x = s.i33
s.s = 1
s.color = "BLEU"
c = p3.Color("PURPLE")
v = p3.Color.RED.value
has = proto.has(s, "nope")
f = proto.get_field(s, p3.Node.name)
g = proto.get_field(s, "i32")
r = p3.Repeats()
r.i32s.append("x")
found = 1 in r.i32s
mp = p3.Maps()
n = mp.s2i[1]
m = proto.unmarshal(p3.Scalars, "text")
b = proto.marshal(1)
p3.Node = None

def set_bytes(m, v):
    m.by = v

set_bytes(p3.Node(), "x")

def title(node):
    return node.name.title()

# what literals say
u = p3.Scalars(u32 = -1, color = 7)
w = p3.Node(inner = {"y": 1}, kids = [{"nam": "k"}])
both = p3.Scalars({"i32": 1}, s = "x")
r.colors = ["RED", "PURPLE"]
mp.b2c = {True: 9}
