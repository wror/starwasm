# With contagious None (on here: the program has a reactive variable), the
# checker knows every way a value may be None. These are the less obvious
# ones.

# Operations that can fail on values of the right types: shifts (unless by
# a count written out), ord of a string that may not be one character,
# chr, a split by a separator that may be empty, a range whose step may be
# 0, int of a float (infinite or not a number), unpacking a list (of
# another length), and their augmented assignments.
def shifted(k):
    return 1 << k

def by_three(x):
    return x << 3                    # an int written out: can't fail

def code(s):
    return ord(s)

def parts(s, sep):
    return s.split(sep)

def steps(n, k):
    return range(0, n, k)

def rounded(x):
    return int(x * 1.5)

def first_two(xs):
    a, b = list(xs)
    return a

def halved(n, k):
    n //= k
    return n

# A record (a dict or list literal bound once, as closures share state) has
# the entries it is written with; not once it is passed on or aliased, as
# other code may then remove them.
def counter():
    state = {"n": 0}
    def inc():
        state["n"] += 1
        return state["n"]
    return inc

def aliased():
    state = {"n": 0}
    other = state
    other.pop("n")
    return state["n"]

# A comparison looks inside lists, tuples and dicts: it is None if a None
# is met there.
def listed(d, k):
    return [d.get(k)] == [1]

def paired(d, k):
    return (1, d.get(k)) != (1, 2)

def among(d, k):
    return 1 in [d.get(k), 1]

# A None stored in a list or dict makes its elements optional, from where
# the list or dict is made: the module is checked again so.
def stored(d, k):
    xs = ["a"]
    xs[0] = d.get(k)
    return xs

def recorded(d, k):
    state = {"n": 0}
    state["n"] = d.get(k)
    return state["n"]

def filled(d, ks):
    out = [0 for _ in ks]
    for i, k in enumerate(ks):
        out[i] = d.get(k)
    total = 0
    for v in out:
        if v > 0:                    # may be None: the def may fail
            total += v
    return total

def cleared():
    xs = [1]
    xs[0] = None
    return xs

tick : 1
