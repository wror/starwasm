a, b = range(2)
c, d = "xy".elems()
e, f = {1: 2, 3: 4}
[g] = set([7])
h, i = "é".elem_ords()
for j, k in [range(2), "ab".codepoints()]:
    print(j, k)
print(a, b, c, d, e, f, g, h, i)
