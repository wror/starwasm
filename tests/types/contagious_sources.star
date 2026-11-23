# With contagious None (on here: the program has a reactive variable), the
# checker gives Any only where it can't do better, and that Any may be None.
# zip(*rows), min(*xs), max(*xs), dict(**kw) are typed from their argument;
# a call with **kw gives its values to the parameters; sorted's key may
# return anything (its result isn't Any); struct(**d), whose fields aren't
# known, is Any | None.

def pair(a, b):
    return a + b

def named(n):
    return pair(**{"a": 1, "b": n})

rows = [[1, 2], [3, 4]]
cols = zip(*rows)
low = min(*[3, 1])
copied = dict(**{"a": 1})
opened = struct(**copied)
ordered = sorted([struct(k = 1)], key = lambda x: x.k)

tick : 1
