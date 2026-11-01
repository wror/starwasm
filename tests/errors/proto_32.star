f = proto.file("p3.proto")
m = f.Repeats(i32s=[1])
m.i32s[0] = "x"
