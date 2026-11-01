f = proto.file("p3.proto")
def g():
    return f.Scalars(i32 = "bad")
g()
