f = proto.file("p3.proto")
m = f.Scalars()
m.i32 += 1
print(m)
m.i32 *= 1 << 40
