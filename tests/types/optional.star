# None: a value that may be None has type T | None, and must be tested
# before it is used as a T.

def find(xs, want):
    for x in xs:
        if x == want:
            return x
    return None

def after_test(xs):
    r = find(xs, 3)
    if r == None:
        return 0
    return r + 1

def in_conditional(xs):
    r = find(xs, 3)
    return r + 1 if r != None else 0

def reassigned(d):
    v = d.get("k")
    if not v:
        v = 7
    return v * 2

def or_default(d):
    v = d.get("k")
    return (v or 0) + 1

def and_test(d, k):
    v = None
    if k in d:
        v = d[k]
    if v != None and v > 3:
        return v
    return -1

def best_of(d):
    best = None
    for k, v in d.items():
        if best == None or v > best:
            best = v
    return best

def greet(name = None):
    if name:
        return "hi " + name
    return "hi"

def length(s):
    if s == None:
        return 0
    return len(s)

def previous(xs):
    prev = None
    out = []
    for x in xs:
        if prev != None:
            out.append(x - prev)
        prev = x
    return out

def lookup(d, key, default = None):
    if key in d:
        return d[key]
    return default

top = best_of({"a": 1})
hi = greet()
hi_bob = greet("bob")
zero = length(None)
three = length("abc")
steps = previous([1, 4, 9])
hit = lookup({"a": 1}, "a")

# Division: x / y and x // y are None where y is zero (the error becomes
# a None), so they may be None, unless y is a nonzero number literal.
# And arithmetic on a value that may be None may be None (None is
# contagious): only operands that can't be None give a result that can't.

def ratio(a, b):
    return a / b

def floor_ratio(a, b):
    return a // b

def halves(n):
    return n / 2, n // 2, n / -2.5

def by_zero(n):
    return n / 0

def ratio_or(a, b):
    return (a / b) ?? 0.0

def scaled(total):
    total /= 4
    return total

def ratio_tested(a, b):
    r = a / b
    if r == None:
        return 0.0
    return r + 1

def divide_in_place(total, n):
    total /= n
    return total

def average(xs):
    total = 0.0
    for x in xs:
        total += x
    return total / len(xs) + 1

def plus_one(d):
    return d.get("k") + 1

def product(d):
    return d.get("a") * d.get("b")

def accumulate(xs):
    best = None
    for x in xs:
        best += x
    return best

def plain(a, b):
    return a + b * 2

def suffixed(d):
    return d.get("k") + "!"

in_place = divide_in_place(1.0, 2)
plus = plus_one({"k": 1})
prod = product({"a": 2.0})
acc = accumulate([1, 2])

# Formatting: "%s" % x is None where x is (None is contagious through
# %), but a None inside a tuple of values is formatted as "None".
def formatted(d):
    return "%s" % d.get("k")

def formatted_in_tuple(d):
    return "%s!" % (d.get("k"),)

# Lookups: x[i] is None where i is out of range or not a key (the error
# becomes a None), so it may be None; but not a tuple's element at an
# index that is known to be in range.
def lookup_key(d, k):
    return d[k]

def lookup_or(xs, i):
    return xs[i] ?? 0

def pair_first(p):
    t = (p, "x")
    return t[0]

def count_words(words):
    counts = {}
    for w in words:
        counts[w] = (counts.get(w) ?? 0) + 1
    return counts

key_found = lookup_key({"a": 1}, "a")
indexed = lookup_or([1, 2], 5)
paired = pair_first(1.5)
words = count_words(["a", "b", "a"])
