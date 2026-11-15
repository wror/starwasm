# option:contagiousnone
# Contagious None (EXTENSIONS.md): an operation on None gives None, also
# == and != (with None written out they don't compile: none_err_*.star),
# and so does a test of its truth or an iteration over it in an expression
# (in a statement it is an error: none_reactive_errors.star); ?? replaces it.

def show(*args):
    print(*[repr(a) for a in args])

def ident(v):
    return v

def nothing():
    pass

def early(v):
    if (v ?? 0) == 0:
        return
    return v

x = None
one = 1
s = struct(a = 1, n = None, f = ident, g = abs)
d = {"k": 1}
l = [3, 1, 2]

# the user's examples
show(x > x, x == x, x != x, x.foo, abs(x))
show(x == one, one != x, x == 1, x != 1, 1 == x)

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

# conditions: None is neither true nor false: what tests it is None
def conds(v):
    out = []
    if v ?? False:
        out.append("v")
    if (v > 1) ?? True:
        out.append("v > 1, or None")
    out.append("yes" if v else "no")
    out.append("more" if v > 1 else "less")
    out.append(("is" if not v else "not") ?? "neither")
    out.append([v or "or", v and "and", 0 or v, 1 and v, v or v])
    out.append([1 for _ in range(2) if v])
    out.append([i for i in [1, 2] if i > v])
    return out

# a comprehension over None, or with a None condition, is that None
def comps(v):
    return [[i for i in v], {i: 1 for i in v}, [j for i in [[1], v, [2]] for j in i], [i for i in v] ?? [], provenance([i for i in v]) == provenance(v)]

show(conds(x))
show(comps(x))
show(comps([3]))
show(conds(2))

# statements: nothing interrupts the program
def statements(v):
    out = []
    for i in v ?? []:
        out.append(i)
    for i in range(v) ?? range(1):
        out.append(i)
    for i, j in [v, (1, 2)]:
        out.append((i, j))
    a, b = v
    (c, [e, f]) = v
    out.append((a, b, c, e, f))
    out += [k for k in v] ?? ["no k"]
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

# None written out, where it is no operand of an operation
def written(v = None):
    a = None
    b, c = None, [None]
    c.append(None)
    c[0] = None
    d = {None: None, "k": None}
    return [v, a, b, c, d, 0 or None, 1 and None, None if 1 else 2, 3 if 0 else None, ident(None), ident(v = None), d.get("zz", None), struct(a = None)]

show(*written())
print(None, [None], (None,))

# x ?? y: y if x is None, else x (y is evaluated only then)
def loud(v):
    print("evaluated", v)
    return v

show(x ?? 1, 0 ?? 1, "" ?? 1, False ?? 1, [] ?? 1, None ?? 1, x ?? x, x ?? None, x ?? x ?? "last")
show(1 ?? loud(2), x ?? loud(3), x.foo.bar ?? "no bar", d.get("zz") ?? "no zz", nothing() ?? "nothing")
# it binds less than every other operator, and groups from the left
show(x ?? 0 or 5, x ?? 1 + 1, 2 * 3 ?? 4, x ?? 1 == 1, (x ?? 1) if x ?? True else 2, not x ?? "n", [v ?? 0 for v in [1, x, 3]])
show(provenance(x ?? 1), provenance(x ?? nothing()) == provenance(nothing()))

# telling a None: its type is None too
show([type(v) ?? "NoneType" for v in [x, 0, "", []]])

# everything else is as ever
show(early(1), early(x), nothing(), 1 + 1, [1, 2][1], "a".upper(), len("abc"), 3 > 2, not 1, l == l, s.a)
