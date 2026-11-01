f = proto.file("p2.proto")
proto.unmarshal_text(f.Legacy, "name: 'x'")
