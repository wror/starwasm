f = proto.file("p3.proto")
proto.unmarshal_text(f.Scalars, b"i32: 1")
