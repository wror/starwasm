# A module whose proto values are frozen once loaded (tests/errors/proto_*).
p3 = proto.file("p3.proto")
M = p3.Scalars(i32 = 1)
R = p3.Repeats(i32s = [1, 2])
MP = p3.Maps(s2i = {"a": 1})
