# option:contagiousnone
# A None inside a container handed to a builtin or an operator doesn't stop
# the program either (EXTENSIONS.md, contagious None): what fails because
# of it gives a None that starts there.

def show(label, v):
    print(label + ":", repr(v), ["%s %s:%d" % (k, n, line) for k, n, _, line in provenance(v)])

n = None
l = [3, n, 1]

show("sorted", sorted(l))
show("join", ",".join(["a", n]))
show("format", "%d items" % (n,))
show("compare", [n] < [1])
show("tuples", (1, n) >= (1, 2))
show("max", max(l))
show("min with key", min(l, key = lambda v: v))
show("dict", dict([n]))
show("update", {}.update([n]))
show("bytes", bytes([65, n]))
show("spread", abs(*[n]))
show("spread 2", "abc".replace("a", *[n]))
show("range", range(*l))
show("through a value", [f(l) for f in [sorted, max, len]])
show("a method value", [m(["a", n]) for m in [",".join]])

# in a condition, false
def conds():
    out = []
    if [n] < [1]:
        out.append("<")
    if not ([n] < [1]):
        out.append("not <")
    if (n, 1) != (n, 1):
        out.append("!=")
    out.append("yes" if sorted(l) else "no")
    return out

print(conds())

# a loop a builtin was cut out of is over: the list can change again
def after():
    xs = ["a", n, "b"]
    for _ in range(2):
        r = ",".join(xs)
        m = max(xs)
        xs.append("c")
    d = {1: n, 2: 3}
    s = sorted(d.values())
    d[4] = 5
    v = 0
    v += [n] < [1]
    return [xs, r, m, d, s, v]

print(after())

# augmented, and the callbacks of a builtin
def augmented():
    acc = [1]
    acc += sorted(l) or [2]
    return acc

print(augmented(), sorted([3, 1, 2], key = lambda v: -v), sorted(l, key = lambda v: v or 0), [k for k in sorted({"b": n, "a": 1})])

# everything else is as ever
print(sorted([2, 1]), max(1, 2), len("abc"), "%d" % 3, [1] < [2], ",".join(["a", "b"]))
