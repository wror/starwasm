f = proto.file("p3.proto")
m = f.Repeats()
m.i32s.extend([1])
