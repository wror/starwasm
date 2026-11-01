# error: 4:26: function walk called recursively
def count(tree):
    def walk(t):
        return 1 + sum_([walk(c) for c in t])
    return walk(tree)

def sum_(xs):
    return len(xs)
