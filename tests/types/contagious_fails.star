# With contagious None (on here: the program has a reactive variable), an
# error in a statement of a def that isn't in an expression (which would
# give None in its place) makes the call give None. So a def that may read a
# variable before it is assigned, that is recursive (the call may go too
# deep), or that assigns an item of anything but a dict or list it made
# itself (an index out of range, a frozen value: every global after the
# first run, one being iterated over) is T | None; and so is a call with
# *args or **kwargs (how many, and which names, isn't checked). A lambda
# that may fail is T | None itself.

def last(xs):
    for x in xs:
        pass
    return x                        # unassigned if xs is empty

def maybe(c):
    if c:
        y = 1
    return y

def assigned(c):
    if c:
        y = 1
    else:
        y = 2
    return y                        # assigned either way

def returned(c):
    if c:
        return 0
    else:
        y = 2
    return y

LIMIT = 3

def global_read(n):
    return n + LIMIT                # (a global the module always assigns)

def depth(n):
    return 0 if n == 0 else 1 + depth(n - 1)

def ping(n):
    return 0 if n == 0 else pong(n - 1)

def pong(n):
    return ping(n)

def counts(words):
    seen = {}
    for w in words:
        seen[w] = seen.get(w, 0) + 1      # a dict it made: can't fail
    return seen

def setslot(xs, i, v):
    xs[i] = v                       # a list it was given
    return xs

def setfirst(v):
    xs = [0, 0]
    xs[0] = v                       # by an index its literal has
    return xs

def setat(i, v):
    xs = [0, 0]
    xs[i] = v                       # by any index
    return xs

def iterated(d):
    for k in d:
        d[k] = 0                    # while iterating over it
    return d

def pair(a, b):
    return a + b

def spread(xs):
    return pair(*xs)

def named(kw):
    return pair(**kw)

firsts = lambda ps = [[1, 2]]: [a for a, b in ps]     # a list may not have 2 elements

tick : 1
