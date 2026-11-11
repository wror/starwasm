# A value that may be None must be tested before it is used.

def find(xs, want):
    for x in xs:
        if x == want:
            return x
    return None

def shout(d):
    v = d.get("k")
    return v.upper()

def next_after(xs):
    r = find(xs, 1)
    return r + 1

def count(n = None):
    return range(n)

def takes_int(n):
    return n + 1

def pass_on(d):
    return takes_int(d.get("a"))

def fields(p = None):
    return p.name

def tested_too_late(d):
    v = d.get("k")
    w = v + 1
    if v != None:
        return w
    return 0
