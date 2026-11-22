# Reactive definitions may build and fill collections of their own
# (EXTENSIONS.md, "Reactive variables", "Mutation").
load("modules/journal.star", "collect", "fresh")

def build(n):
    xs = []
    for i in range(n):
        xs.append(i * 2)
    groups = {}
    for x in xs:
        groups.setdefault(x % 3, []).append(x)
    return xs, groups

def fill(out, n):
    for i in range(n):
        out.append(i)
    return out

def add(n, step):
    n += step
    return n

def sorted_copy(xs):
    ys = list(xs)
    ys.append(0)
    return sorted(ys)

log = ["start"]
log.append("more")  # (the top level runs once: it may mutate)

n : 3
built : build(n)
filled : fill([], n)
total : add(n, 2)
copied : sorted_copy([n, 1])
loaded : collect([], n)
made : fresh(n)
squares : [x * x for x in range(n)]
