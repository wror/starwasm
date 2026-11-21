# With contagious None (on in a program with reactive variables): proto
# operations that can fail on values of the right types give None there.
p3 = proto.file("p3.proto")
qty : 3

ok = p3.Scalars(s = "a", i32 = 1, color = "RED", d = 2)
same = p3.Scalars(ok)
ranged = p3.Scalars(i32 = qty)
from_dict = p3.Scalars({"i32": 1})
red = p3.Color("RED")
by_number = p3.Color(qty)
name = ok.s
wire = proto.marshal(ok)
text = proto.marshal_text(ok)
back = proto.unmarshal(p3.Scalars, b"")
legacy = proto.marshal(proto.file("p2.proto").Legacy(id = 1))

def set_count(m, n):
    m.i32 = n
    return m

def set_name(m, s):
    m.s = s
    return m

counted = set_count(p3.Scalars(), 5)
named = set_name(p3.Scalars(), "x")
