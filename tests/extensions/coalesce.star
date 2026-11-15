# x ?? y (EXTENSIONS.md): y if x is None, else x. It is there with or
# without contagious None (here: without).

def loud(v):
    print("evaluated", v)
    return v

def first(xs):
    for x in xs:
        return x

x = None
d = {"a": 0}
print(x ?? 1, 0 ?? 1, "" ?? 1, False ?? 1, [] ?? 1, None ?? 1, x ?? x, x ?? None ?? "last")
print(1 ?? loud(2), x ?? loud(3), d.get("zz") ?? "no zz", d.get("a") ?? "no a", first([]) ?? "empty")
print(x ?? 0 or 5, x ?? 1 + 1, 2 * 3 ?? 4, x ?? 1 == 1, (x ?? 1) if x ?? True else 2, [v ?? 0 for v in [1, x, 3]])
print(len(x ?? []), (x ?? "abc").upper(), [v for v in x ?? (1, 2)], (lambda v: v ?? "lambda")(x))
# without contagious None, None is as in starlark-go
print(x == None, x or "or", type(x), [x] == [None])
