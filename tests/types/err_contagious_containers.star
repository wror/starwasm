# With contagious None (on here: the program has a reactive variable), a set
# made otherwise than by a literal can't be given elements that may be None.

e = {0: 1}
s = set([1])
s.update([e.get(1)])
t = s.union(["a"])

tick : 1
