f = proto.file("p3.proto")
proto.unmarshal_text(f.Node, "inner { x: 1 >")
