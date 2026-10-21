a = [1]
a.append(a)
print(a, repr(a), str(a))
d = {"k": 1}
d["self"] = d
print(d)
l = [d, a]
print(l)
t = (a, a)
print(t)
b = []
c = [b]
b.append(c)
print(b, c)
x = []
y = [x, x]
print(y)
d2 = {}
d2[1] = [d2]
print(d2)
s = struct(l = a)
print(s)
print("%s %r" % (a, d))
print("{}".format(a))
e = []
e.append({"e": e})
print(e)
# (a struct inside a list inside that struct: starlark-go overflows its
# stack; starwasm prints struct(l = [struct(l = [...])]))
big = []
for i in range(20):
    big = [big, big]
print(len(str(big)))
big.append(big)
print(str(big)[-12:])
