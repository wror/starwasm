f = proto.file("p3.proto")
proto.unmarshal(f.Repeats, b"\x0a\x02\x01")
