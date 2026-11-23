# With contagious None (on here: the program has a reactive variable), a dict
# key or set element that can't be hashed fails at run time, and so gives
# None: the checker rejects it.

def index(rows):
    return {row: 1 for row in rows}

by_row = index([[1, 2]])
pairs = {(1, [2]): "a"}
seen = set([[1]])

tick : 1

def keyed(s):
    return {s: s.a}                 # s's other fields are keys' too

by_struct = keyed(struct(a = 1, b = [2]))
