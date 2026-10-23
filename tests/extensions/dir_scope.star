# dir() with no arguments: the names bound in the current scope, sorted,
# as in Python (an extension: starlark-go's dir takes one argument).
load("modules/dir_mod.star", "public", dfn = "fn")
print(dir())
print(public, dfn())
a = 1
print(dir())

def f(p, q = 2, *args, **kwargs):
    print(dir())
    x = 1
    print(dir())
    if p:
        y = 2
    print(dir())
    return x

f(0)
f(1)
print(dir())

def outer():
    v = 1
    w = 2
    unused = 3

    def inner():
        print(dir())  # captures v (used here) and w (used by inner2)

        def inner2():
            return w

        return v + inner2()

    print(dir())
    inner()
    late = 4
    return lambda k: (k, late, dir())

print(outer()(9))

def comp():
    n = 10
    print([dir() for i in range(1)])
    print([(i, j, dir()) for i in range(2) if dir() for j in range(1)])
    print({k: dir() for k in dir()})

comp()
print([dir() for t in [1]])
print(dir())

def shadow():
    def dir():
        return "mine"
    return dir()

print(shadow())

def cells():
    c = 1
    d = 2
    g = lambda: c
    print(dir())
    del_later = None
    return g

cells()
print(dir()[0], len(dir()))
print(dir([])[:3], dir(struct(z = 1, y = 2)))

# dir through a value: the scope of the call site, as in Python.
d = dir
print(d())

def via_value(arg):
    local = 1
    f = d
    get = lambda: dir
    s = struct(fn = dir)
    fns = {"dir": dir, "len": len}
    print(f(), get()(), s.fn(), fns["dir"]())
    print(f([])[:2], fns["len"]([1, 2]), [g() for g in [dir]])
    return (lambda inner: d())(0)

print(via_value(5))
