# With contagious None (on here: the program has a reactive variable), a
# def that tests, compares or sorts values of a type parameter gives None
# when they are None. Its type says so with the bound Contagious, and a call
# with values that may have a None in them is then T | None. A def that only
# passes them on, or counts them, isn't affected. (Contagious looks inside:
# a for loop over a list marks it too, so a call with a None among the
# elements is T | None even where only the list's truth is used.)
def n_true(xs):
    n = 0
    for x in xs:
        if x:
            n += 1
    return n
def use(d, k):
    return n_true([d.get(k)])
def use_ok(xs):
    return n_true([1, 2])
def later(xs):
    return sorted(xs)
def use_later(d, k):
    return later([d.get(k)])
def same(a, b):
    return a == b
def use_same(d, k):
    return same([d.get(k)], [1])
def ident(x):
    return x
def use_ident(d, k):
    return ident([d.get(k)])
def through(xs):
    return n_true(xs)
def use_through(d, k):
    return through([d.get(k)])
def count(xs):
    return len(xs)
def use_count(d, k):
    return count([d.get(k)])
tick : 1
