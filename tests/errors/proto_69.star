f = proto.file("p3.proto")
proto.unmarshal_text(f.Scalars, "i32: 1 i32: 2")
