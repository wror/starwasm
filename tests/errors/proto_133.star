f = proto.file("p3.proto")
proto.unmarshal_text(f.Repeats, "i32s: [1 2]")
