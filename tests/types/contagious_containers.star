# With contagious None (on here: the program has a reactive variable), what a
# builtin stores is checked as an item assignment would be: d.setdefault(k)
# with no default stores None (and gives it back); d.update(...) stores the
# entries of a dict, of pairs, and its keyword arguments; s.update(...) and
# s.union(...) the elements of iterables. A dict made by a literal then
# gets optional values, as with d[k] = v. bytes() looks inside its
# argument: a None among the ints gives None.

def defaulted(k):
    d = {"a": 1}
    v = d.setdefault(k)             # None, stored under k
    return d

def updated(e, k):
    d = {"a": 1}
    d.update({"b": e.get(k)})       # a value that may be None
    d.update([("c", 3)], z = 4)
    return d

def unioned(e, k):
    s = set([1])
    s.update([e.get(k) ?? 0])
    return s.union([2], [3])

def made(e, k):
    return bytes([65, e.get(k)])

tick : 1
