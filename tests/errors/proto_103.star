f = proto.file("p3.proto")
m = f.Maps(s2i={"a":1})
r = m.s2i
for x in r:
    r["b"] = 2

# option:globalreassign (top-level control flow or rebinding above)
