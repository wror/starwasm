# With contagious None (on here: the program has a reactive variable), an
# operation that can fail on values of the right types gives None, so its
# type is T | None, as is a def's that returns one or tests, loops over or
# unpacks one. ?? gives back a T.
def ratio(a, b):
    return a / b

def scaled(a, b):
    return ratio(a, b) * 10          # an operation on T | None: T | None

def safe(a, b):
    return ratio(a, b) ?? 0

def half(n):
    return n / 2                     # by a nonzero number written out

def sign(xs, i):
    if xs[i] > 0:                    # a test that may be None fails
        return 1
    return -1

def counter():
    state = {"n": 0}                 # a record: its entries are there
    def inc():
        state["n"] += 1              # but this may fail: once a global holds
                                     # inc, state is frozen (so inc() is T | None)
        return state["n"]
    return inc

def first(xs):
    return xs[0]

def parse(s):
    return int(s)

def names(rows):
    out = []
    for r in rows:
        out.append(r.get("name"))    # append keeps a maybe None
    return out

tick : 1
