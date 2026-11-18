# A value that may be None must be tested before it is used.

def find(xs, want):
    for x in xs:
        if x == want:
            return x
    return None

def shout(d):
    v = d.get("k")
    return v.upper()

def count(n = None):
    return range(n)

def takes_int(n):
    return n + 1

def pass_on(d):
    return takes_int(d.get("a"))

def fields(p = None):
    return p.name

# counts[k] += 1 stores None where k is missing (the lookup is None, and
# so is None + 1), so the dict's values may be None: a dict[str, int]
# won't do
def bump_all(counts):
    for k in counts:
        counts[k] += 1
    return counts

bumped = bump_all({"a": 1})
