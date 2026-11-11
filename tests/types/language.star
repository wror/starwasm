# The annotation language, in its less common forms (language.start).

def pair(a, b):
    return (a, b)

def field_named_l(r):
    return r.L

def apply(f, xs, fallback = None):
    out = []
    for x in xs:
        v = f(x)
        out.append(v if v != None else fallback)
    return out

def outer(x, n):
    def repeat(v):
        return [v] * n
    def unannotated(v):
        return repeat(v) + repeat(x)
    return unannotated(x)

def norm(v):
    return abs(v.x) + abs(v.y)

def keys_and_sizes(d):
    return [(k, len(v)) for k, v in d.items()]

def run(callback = None):
    if callback == None:
        return 0
    return callback("x")

def scale(x, k = 2):
    return x * k

def nothing():
    return None

table = [("a", 1)]
lookup = {}
maybe = None
unit = ()
several = (1, 2, 3)
