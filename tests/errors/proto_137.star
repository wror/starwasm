f = proto.file("p3.proto")
proto.unmarshal_text(f.Maps, "s2i { key 'a' }")
