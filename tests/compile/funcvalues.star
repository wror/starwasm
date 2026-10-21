# Functions as values: top-level defs, lambdas, higher-order functions,
# dynamic calls with keyword args, defaults, *args and **kwargs.

def apply(f, *args, **kwargs):
    return f(*args, **kwargs)

def describe(a, b = 2, *rest, sep = "-", **opts):
    return sep.join([str(a), str(b), str(rest), str(opts)])

def compose(f, g):
    return lambda x: f(g(x))

def my_map(f, xs):
    return [f(x) for x in xs]

def my_filter(pred, xs):
    out = []
    for x in xs:
        if pred(x):
            out.append(x)
    return out

def reduce(f, xs, init):
    acc = init
    for x in xs:
        acc = f(acc, x)
    return acc

square = lambda x: x * x
inc = lambda x, by = 1: x + by
print(square(7), inc(1), inc(1, 5), inc(1, by = 10), inc(by = 2, x = 3))
print(my_map(square, range(5)), my_filter(lambda n: n % 2, range(10)))
print(reduce(lambda a, b: a + b, range(101), 0), reduce(lambda a, b: a if a > b else b, [3, 9, 2], 0))
print(compose(square, inc)(3), compose(inc, square)(3))

f = describe
print(f(1), f(1, 3), f(1, 3, 4, 5), f(1, sep = "+"), f(a = 9, x = "y"))
print(apply(describe, 1, 2, 3, sep = "/", z = 1))
args = [10, 20, 30]
kw = {"sep": ":", "flag": True}
print(describe(*args), describe(*args, **kw), describe(0, *[1], **{"q": 2}))
print(apply(apply, square, 12))

# Functions in data structures, as dict keys, compared by identity.
ops = {"sq": square, "inc": inc, "desc": describe}
print([ops[k](3) for k in ["sq", "inc"]], ops["desc"](1, b = "B"))
table = {square: "square", inc: "inc"}
print(table[square], square == square, square == inc, len(table))

# type / str / repr of functions
print(type(square), str(describe), repr(lambda: 0), describe)

# Returning functions from functions, calling results directly.
def pick(name):
    if name == "sq":
        return square
    return lambda x: -x
print(pick("sq")(4), pick("neg")(4), [pick(n)(2) for n in ["sq", "neg"]])

# A def'd function referenced before its def statement runs is an error in
# Starlark only if called then; here it's referenced after.
def later():
    return early_ref()
def early_ref():
    return "early"
print(later(), apply(later))
