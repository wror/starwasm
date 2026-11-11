# Checked against the annotations in annotated.start.

def area(shape):
    return shape.width * shape.height

def first(xs):
    return xs[0]

def pick(r, field):
    return getattr(r, field)

def mean(values, weight):
    total = 0
    for v in values:
        total += v * weight
    return total / len(values)

def describe(p):
    def show(v):
        return str(v)
    return show(p.name) + ": " + show(p.age)

def longest(items):
    best = None
    for it in items:
        if best == None or len(it) > len(best):
            best = it
    return best

def count_all(xs, start):
    n = start
    for x in xs:
        n += 1
    return n

def render(value, indent = 0, *rest, sep = " ", **options):
    return " " * indent + str(value) + sep.join([str(r) for r in rest])

def callback(f, x):
    return f(x)

limit = 10
names = []
cache = {}
origin = struct(x = 0, y = 0)
handler = None

r = area(struct(width = 2, height = 3))
f = first(["a"])
p = pick(origin, "x")
m = mean([1, 2, 3], 2)
c = callback(lambda v: v + 1, 1)
