f = proto.file("p3.proto")
m = f.Repeats(i32s=[1,2])
r = m.i32s
for x in r:
    r.append(1)
