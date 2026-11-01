f = proto.file("p3.proto")
m = f.Repeats()
m.i32s = [1, "a"]
