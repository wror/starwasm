# With contagious None (on here: the program has a reactive variable), a def
# that keeps an argument (here: in a list it was given) is checked with the
# argument's None: a str | None can't go where a str is wanted.

def keep(acc, name):
    acc.append(name.upper())
    return len(acc)

names = ["A"]
d = {"a": "b"}
n = keep(names, d.get("a"))

tick : 1
