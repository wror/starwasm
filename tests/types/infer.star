# Inference without annotations: literals, containers, defs, let-polymorphism.

count = 3
ratio = 1.5
name = "starwasm"
raw = b"bytes"
flag = True
nothing = None
numbers = [1, 2, 3]
mixed_numbers = [1, 2.5]
pair = (1, "one")
ages = {"ann": 31, "bob": 27}
empty = []
nested = [[1], [2, 3]]
seen = set([1, 2])

def identity(x):
    return x

def twice(f, x):
    return f(f(x))

def inc(x):
    return x + 1

def half(x):
    return x / 2

def greet(name, punctuation = "!"):
    return "hello, " + name + punctuation

def first(xs):
    return xs[0]

def total(xs):
    t = 0
    for x in xs:
        t += x
    return t

def swap(p):
    a, b = p
    return (b, a)

def compose(f, g):
    return lambda x: f(g(x))

def apply_all(fs, x):
    return [f(x) for f in fs]

def describe(*args, sep = ", ", **kwargs):
    return sep.join([str(a) for a in args] + sorted(kwargs.keys()))

def nothing_much():
    pass

# a polymorphic def is used at several types
i = identity(1)
s = identity("s")
four = twice(inc, 2)
quarter = half(half(1))
hello = greet("world")
head = first(numbers)
initial = first(name)
sum_ = total(numbers)
sum_ages = total(ages.values())
swapped = swap(pair)
length_plus_one = compose(inc, len)
n = length_plus_one("abc")
results = apply_all([inc, lambda v: v * 2], 10)
text = describe(1, "two", x = 3)

# comprehensions, slices, builtins
squares = [k * k for k in range(5)]
by_length = {w: len(w) for w in name.split("a") if w}
upper = name.upper()[1:3]
ordered = sorted(ages.items(), key = lambda kv: kv[1])
longest = max([len(k) for k in ages])
zipped = zip(numbers, ["a", "b", "c"])
indexed = enumerate(numbers)
last = numbers[-1]
tail = numbers[1:]
found = ages.get("ann")
found_or_zero = ages.get("ann", 0)
