# option:globalredefine
# Top-level functions bound again (--globalredefine; starlark-go's
# AllowGlobalReassign allows it): a function bound more than once is a
# module variable, set by each def as it runs.

def f(n = 2):
    return n

def g():
    return f() + 1  # the f of the moment

def once(x):  # bound once: compiled as without the option
    return x * 2

print(f, f(), g(), once(3))
first = f

def f(n = 10, *args, **kwargs):
    return (n * 2, args, sorted(kwargs.items()))

print(f, f(), f(1, 2, k = 3), g, first(), first == f)

def g():
    return "g: " + repr(f(4))

print(g())

# ... by an assignment, before and after its def
f = lambda: 7
print(g, f())
h = 1
print(h)

def h(x):
    return x + 1

print(h(h(1)))
h = h(1) + 0
print(type(h), h)

# ... in an if and a loop, and defined there only
for i in range(3):
    def step(x, i = i):
        return x + i

    if i == 1:
        def f():
            return "f in if"

print(step(10), f())
if True:
    def only_here(x):
        return [x]

print(only_here(1))

# a closure made from the function's value keeps that value
def make():
    def inner():
        return 1

    return inner

keep = make()

def make():
    return lambda: 2

print(keep(), make()())

# its defaults are evaluated at each def; errors name the function
n = 5

def d(a, b = n):
    return a + b

n = 6

def d(a, b = n, c = n + 1):
    return a + b + c

print(d(1), d(1, 1), d(1, 1, 1))
