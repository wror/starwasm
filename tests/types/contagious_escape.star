# With contagious None (on here: the program has a reactive variable), a def
# called with a None runs with it. Where the None can only come out of the
# call as (what is computed from it in) the result, the call is checked as
# if the argument weren't None, and is T | None. Where it can get out
# otherwise (stored in a container the def didn't make, returned inside a
# value, kept by a closure, given to a function that can't be followed),
# the argument goes in with its None (typecheck/nones.star, escapes).

def push(acc, x):
    acc.append(x)                   # stores x in a list it didn't make
    return 0

def pushed(d, k):
    acc = [0]
    push(acc, d.get(k))             # so acc is a list[int | None]
    return acc

def wrap(x):
    return [x]                      # returns x inside a list

def wrapped(d, k):
    return wrap(d.get(k)) ?? []     # list[int | None]

def box(x):
    return struct(v = x)

def boxed(d, k):
    return (box(d.get(k)) ?? struct(v = 0)).v      # T | None

def double(x):
    return x * 2                    # only computes with it

def doubled(d, k):
    return double(d.get(k))         # checked as double(T): T | None

def size(xs):
    n = 0
    for _ in xs:
        n += 1
    return n

def sized(d, k):
    return size(d.get(k))           # int | None

def collect(acc, x):
    seen = []
    seen.append(x)                  # into a list it made: no escape...
    return len(seen) + len(acc)

def collected(d, k):
    return collect([1], d.get(k))   # ... so checked as collect(T)

def apply(f, x):
    return f(x)                     # f can't be followed

def applied(d, k):
    return apply(double, d.get(k))

inc = lambda x: x + 1               # a lambda bound once is followed
keep = lambda x: [x]

def lambdas(d, k):
    return (inc(d.get(k)), keep(d.get(k)) ?? [])

tick : 1
