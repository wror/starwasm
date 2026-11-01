# Without the recursion option, what isn't a statically known cycle is
# allowed: a chain of calls, a parameter shadowing the function's name,
# a lambda that names the function, a comprehension variable named like it.

def a(n):
    return b(n) + 1

def b(n):
    return len(str(n))

def f(f):
    return f(1)

def g():
    h = lambda: g()  # a lambda: calls in it are the lambda's
    return 2

def k():
    return [k() for k in [lambda: 3]]

print(a(100), f(lambda x: x + 1), g(), k())
