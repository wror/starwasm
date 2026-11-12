# option:contagiousnone
# Contagious None (EXTENSIONS.md): an operation on None gives None; only
# == and != with None written out tell.

def show(*args):
    print(*[repr(a) for a in args])

def ident(v):
    return v

def nothing():
    pass

def early(v):
    if v == None:
        return
    return v

x = None
one = 1
s = struct(a = 1, n = None, f = ident, g = abs)
d = {"k": 1}
l = [3, 1, 2]

# the user's examples
show(x == None, x != None, x > None, x == x, x.foo, abs(x))
show(None == x, None != x, one == None, one != None, x == 1, x != 1, 1 == x)

# operators
show(x + 1, 1 + x, x - 1, x * 2, x / 2, x // 2, x % 2, "%d" % x, x & 1, x | 1, x ^ 1, x << 1, 1 >> x)
show(x < 1, 1 <= x, x >= x, x in [1], 1 in x, x not in [1], 1 not in x)
show(-x, +x, ~x, not x, not not x)
show(x and 1, x or 1, 1 and x, 0 or x, x or x)

# attributes, indexing, slicing, calling
show(x.foo, x.foo.bar, x[0], l[x], d[x], x[1:2], l[x:2], l[0:x], "abc"[::x])
show(x(), x(1, k = 2), x.foo(), x.upper(), x.foo(1).bar[2].baz)
show(s.n, s.n.a, s.n(), s.n + 1, s.missing_is_error if False else "ok")

# builtin functions and methods: None in, None out, uncalled
show(abs(x), len(x), str(x), repr(x), type(x), bool(x), int(x), float(x), list(x), tuple(x), hash(x))
show(sorted(x), reversed(x), enumerate(x), zip(l, x), range(x), min(x, 1), max(1, x), any(x), all(x), dict(x))
show(getattr(x, "a"), getattr(x, "a", 1), getattr(s, x), hasattr(x, "a"), dir(x))
show("a,b".split(x), ",".join(x), "abc".startswith(x), "{}".format(x), l.index(x), l.extend(x), d.pop(x))
show(len(*x), len(**x), ident(*x), ident(**x), s.f(*x))

# arguments that are only stored, printed or given back are no operation
l.append(x)
l.insert(0, x)
show(l, d.get("zz", x), d.setdefault("n", x), d, getattr(s, "zz", x), struct(a = x), dict(a = x), sorted([2, 1], key = x))
print(x, [x], (x, 1))

# a def is called: None is an argument like any other
show(ident(x), ident(v = x), s.f(x), (lambda v: [v])(x))
# through a value: a builtin isn't called, a def is
fs = [abs, ident, "x".upper, l.append, s.g]
show([f(x) for f in fs[:3]], fs[3](x), fs[4](x), l)
show(s.f(1), s.g(-2), fs[0](-3), fs[1](4))

# conditions: None is false, and so is anything computed from it
def conds(v):
    out = []
    if v:
        out.append("v")
    if not v:
        out.append("not v")
    if v > 1:
        out.append("v > 1")
    if not v > 1:
        out.append("not v > 1")
    if v != 1:
        out.append("v != 1")
    if v == None:
        out.append("v == None")
    if v != None:
        out.append("v != None")
    out.append("yes" if v else "no")
    out.append([1 for _ in range(2) if v] + [2 for _ in range(1) if not v])
    return out

show(conds(x))
show(conds(2))

# statements: nothing interrupts the program
def statements(v):
    out = []
    for i in v:
        out.append(i)
    for i in range(v):
        out.append(i)
    for i, j in [v, (1, 2)]:
        out.append((i, j))
    a, b = v
    (c, [e, f]) = v
    out.append((a, b, c, e, f))
    out += [k for k in v] + [k for k in v.items()]
    m = [1, 2]
    dd = {}
    m[v] = 5
    m[0] += v
    v[0] = 5
    v[0] += 1
    v.field = 5
    v.field += 1
    dd[v] = "none key"
    dd["k"] = v
    n = v
    n += 1
    out.append((m, dd, n))
    return out

show(statements(x))

# everything else is as ever
show(early(1), early(x), nothing(), 1 + 1, [1, 2][1], "a".upper(), len("abc"), 3 > 2, not 1, l == l, s.a)
