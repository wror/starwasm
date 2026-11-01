f = proto.file("p3.proto")
m = f.Repeats(i32s = [3,1,2])
print(sorted(m.i32s), list(m.i32s), tuple(m.i32s), max(m.i32s), "-".join(f.Repeats(ss=["a","b"]).ss), enumerate(m.i32s), [x*2 for x in m.i32s], m.i32s[-1], m.i32s[1:])
