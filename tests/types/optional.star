# None: a value that may be None has type T | None, and must be tested
# before it is used as a T.

def find(xs, want):
    for x in xs:
        if x == want:
            return x
    return None

def after_test(xs):
    r = find(xs, 3)
    if r == None:
        return 0
    return r + 1

def in_conditional(xs):
    r = find(xs, 3)
    return r + 1 if r != None else 0

def reassigned(d):
    v = d.get("k")
    if not v:
        v = 7
    return v * 2

def or_default(d):
    v = d.get("k")
    return (v or 0) + 1

def and_test(d, k):
    v = None
    if k in d:
        v = d[k]
    if v != None and v > 3:
        return v
    return -1

def best_of(d):
    best = None
    for k, v in d.items():
        if best == None or v > best:
            best = v
    return best

def greet(name = None):
    if name:
        return "hi " + name
    return "hi"

def length(s):
    if s == None:
        return 0
    return len(s)

def previous(xs):
    prev = None
    out = []
    for x in xs:
        if prev != None:
            out.append(x - prev)
        prev = x
    return out

def lookup(d, key, default = None):
    if key in d:
        return d[key]
    return default

top = best_of({"a": 1})
hi = greet()
hi_bob = greet("bob")
zero = length(None)
three = length("abc")
steps = previous([1, 4, 9])
hit = lookup({"a": 1}, "a")
