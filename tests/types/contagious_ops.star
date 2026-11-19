# With contagious None (on here: the program has a reactive variable),
# None is never taken for False: `or`, `and`, `not`, a conditional
# expression and a comparison on a value that may be None are None too.
# Only ?? replaces a None.
def with_or(d):
    return (d["a"] or 0) + 1         # None or 0 is None

def with_coalesce(d):
    return d["a"] ?? 0

def negated(d):
    return not d["a"]

def chosen(d):
    return 1 if d["a"] else 2

def compared(d):
    return d["a"] == 1

def known(x):
    return x == 1                    # nothing may be None: a bool

# A comparison of a value whose type is only found out later
def compared_early(x, d):
    b = x == 1
    x = d["k"]
    return b

# A test of a value whose type is only found out later: the def may fail
def tested_early(x, d):
    if x:
        return 1
    x = d["k"]
    return 2

# A variable assigned a value that may be None after its type was settled
# otherwise is optional throughout (read before that assignment, it is
# what it was assigned)
def reassigned(d):
    n = "a"
    m = n + "b"
    n = d["k"]
    return n

def in_loop(d, ks):
    n = 0
    for k in ks:
        if n > 3:                    # n may be None: the def may fail
            return 1
        n = d[k]
    return 2

def param_reassigned(x, d):
    y = x + "s"                      # x is what the caller passed
    x = d["k"]
    return x

tick : 1
