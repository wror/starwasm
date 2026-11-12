# option:contagiousnone
# Where a None comes from (EXTENSIONS.md, contagious None): provenance(x)
# lists what it passed through, oldest first, as (kind, id, file, line).

load("modules/none_mod.star", "first", "lookup")

def show(label, v):
    print(label + ":", v)
    for kind, name, file, line in provenance(v):
        print("    %s %s (%s:%d)" % (kind, name, file, line))

def ident(v):
    return v

def twice(v):
    w = ident(v)
    return ident(w)

def nothing():
    pass

def bare(v):
    if v:
        return
    return v + 1

def outer():
    def inner():
        return None
    return inner()

def loop(v, n):
    for _ in range(n):
        v = ident(v)
    return v

x = None
show("a literal", x)
show("an operation adds nothing", (x + 1).foo[2])
show("through a function", ident(x))
show("through two, once each", twice(x))
show("round a loop, once each", loop(x, 5))
show("no return value", nothing())
show("a bare return", bare(1))
show("nested", outer())
show("a lambda", (lambda: x)())
show("a default", (lambda v = None: v)())
show("a builtin's result", {}.get("k"))
show("a method's result", [].clear())
show("a stored one, given back", {"k": x}.get("k"))
show("a loaded function", lookup({}, "k"))
show("falling off the end", first([]))
show("print's result", print())
show("the first None operand", ident(x) + nothing())
show("unpacked", [b for a, b in [nothing()]][0])
show("not None", 1)
show("the trace of a trace", provenance(provenance(x)))
print(provenance(x), provenance(1), provenance(x) == provenance(None), ident(x) == None)
