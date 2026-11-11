# What a def needs of an argument whose type it doesn't fix is kept as a
# bound of its type parameter, and checked where the def is used.

def size(x):
    return len(x)

def elements(x):
    return [e for e in x]

def has(c, x):
    return x in c

def at(c, i):
    return c[i]

def put(c, i, v):
    c[i] = v

def add(a, b):
    return a + b

def biggest(a, b):
    return a if a > b else b

def middle(x):
    return x[1:-1]

def drain(x):
    return x.pop()

def negate(x):
    return -x

n1 = size([1, 2])
n2 = size("abc")
n3 = size({"a": 1})
e1 = elements((1, 2))
e2 = elements({"a": 1})
e3 = elements(range(3))
h1 = has([1], 1)
h2 = has("abc", "b")
h3 = has({"k": 0}, "k")
a1 = at([1.5], 0)
a2 = at({"k": "v"}, "k")
a3 = at("abc", 1)
p1 = put([1], 0, 2)
p2 = put({"a": 1}, "b", 2)
s1 = add(1, 2)
s2 = add(1, 2.5)
s3 = add("a", "b")
s4 = add([1], [2])
s5 = add((1, "a"), (2.5,))
s6 = add(struct(a = 1), struct(b = 2))
b1 = biggest(1, 2)
b2 = biggest("a", "b")
m1 = middle([1, 2, 3])
m2 = middle("abc")
d1 = drain([1])
d2 = drain(set(["a"]))
g1 = negate(1)
g2 = negate(1.5)
