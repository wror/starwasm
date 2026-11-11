# The bounds of a def's type parameters are checked where it is called;
# the notes point into the def, at what needs them.

def size(x):
    return len(x)

def total(xs):
    t = 0
    for x in xs:
        t += x
    return t

def biggest(a, b):
    return a if a > b else b

def add(a, b):
    return a + b

def at(c, i):
    return c[i]

def keyed(r, field):
    return getattr(r, field)

size(3)
total(7)
total(["a", "b"])
biggest(None, None)
biggest(1, "a")
add(1, "a")
add([1], (2,))
at([1, 2], "zero")
at(5, 0)
keyed(struct(a = 1), "b")
keyed([1], "a")
