# With contagious None (on here: the program has a reactive variable), a def
# is called with an argument's None: a parameter that can't be None (it is
# looped over, or a str: .upper()) can't be given a value that may be.

def size(xs):
    n = 0
    for _ in xs:
        n += 1
    return n

def shout(s):
    return s.upper() + "!"

lists = {"a": [1]}
names = {1: "ann"}
count = size(lists.get("b"))
loud = shout(names.get(2))

tick : 1
