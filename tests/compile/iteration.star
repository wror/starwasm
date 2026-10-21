l = [1, 2]
for x in l:
    pass
l.append(3)
for x in l:
    break
l.append(4)
def f():
    for x in l:
        for y in l:
            return x + y
print(f())
l.append(5)
def g():
    for x in l:
        if x == 2:
            return [y for y in l]
print(g())
l.append(6)
d = {1: 2}
for k, v in d.items():
    d[3] = 4
for k in d.keys():
    d[5] = 6
for k in list(d):
    d.pop(k)
print(l, d, max(l), min(l, key = lambda v: -v), sorted(l, key = lambda v: v % 3))
m = [[1]]
for x in m:
    x.append(2)
s = set([1])
for k in s:
    s |= set([3])
print(m, s, [z for z in l if z > 2], {k: k for k in l})
t = (1, 2)
for x in t:
    l.append(x)
print(l, min("cab".elems()), max(range(5)), max([1, 3], [2]))
for x in range(3):
    l.append(x)
print(l)
