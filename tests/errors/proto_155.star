f = proto.file("p3.proto")
a = f.Repeats(i32s = [1]).i32s.append
a()
