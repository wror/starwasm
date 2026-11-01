f = proto.file("p2.proto")
proto.marshal(f.Holder(legacy = {"child": {}, "id": 1}))
