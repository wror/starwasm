f = proto.file("p3.proto")
m = f.Maps(s2i={"a": 1})
m.s2i["b"]
