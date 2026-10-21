print(hash(""), hash("a"), hash("abc"), hash("héllo"), hash("a" * 100), hash("\U0001F600x"))
print(hash(b""), hash(b"abc"), hash(b"\xff"), hash(b"a" * 100), hash("é"[0:1]), hash("xé"[1:2] + "y"))
h = hash
print(h("starlark"), hash == hash, h, type(h), [hash(s) for s in ["k", "kk"]])
