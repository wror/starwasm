f = proto.file("p3.proto")
proto.unmarshal_text(f.Node, "num: 1 text: 'a'")
