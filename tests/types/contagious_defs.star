# With contagious None (on here: the program has a reactive variable), a
# builtin given a value that may be None isn't called: the call gives None
# (len(d.get(k)) is int | None). A def is called with the None, so its
# parameter must take one: the argument goes in with its None, as its type
# says. A def whose parameter is a type parameter takes it (and gives what
# that makes of it); one whose parameter can't be None doesn't
# (err_contagious_defs.star): give it a value that isn't None (x ?? default).

def push(acc, x):
    acc.append(x)
    return 0

def pushed(d, k):
    acc = [0]
    push(acc, d.get(k))             # acc is a list[int | None]
    return acc

def wrap(x):
    return [x]

def wrapped(d, k):
    return wrap(d.get(k)) ?? []     # list[int | None]

def double(x):
    return x * 2

def doubled(d, k):
    return double(d.get(k))         # int | None: x * 2 of a None

def size(xs):
    n = 0
    for _ in xs:
        n += 1
    return n

def sized(d, k):
    return size(d.get(k) ?? [])     # a for loop can't take a None

def counted(d, k):
    return len(d.get(k))            # a builtin: int | None

def apply(f, x):
    return f(x)

def applied(d, k):
    return apply(double, d.get(k))

inc = lambda x: x + 1

def lambdas(d, k):
    return inc(d.get(k))            # (x + 1 of a None)

tick : 1
