# Closures: capture, late binding, sharing, nesting, recursion.

def make_adder(n):
    def add(x):
        return x + n
    return add

add5 = make_adder(5)
add10 = make_adder(10)
print(add5(1), add10(1), add5(add10(100)))

# Late binding: the closure sees the variable, not its value at creation.
def late():
    x = 1
    def get():
        return x
    x = 2
    return get()
print(late())

# Two closures sharing one captured variable (mutated through a container,
# since Starlark has no `nonlocal`).
def counter():
    state = {"n": 0}
    def inc():
        state["n"] += 1
        return state["n"]
    def peek():
        return state["n"]
    return inc, peek
inc, peek = counter()
inc()
inc()
print(peek(), inc(), peek())

# Each call gets fresh cells.
c1, p1 = counter()
c2, p2 = counter()
c1()
print(p1(), p2())

# Three levels: the middle function never uses `a` itself but must pass it down.
def outer(a):
    def middle(b):
        def inner(c):
            return [a, b, c]
        return inner
    return middle
print(outer(1)(2)(3))

# A nested function calling itself recursively (captures its own name).
def fact_via_helper(n):
    def helper(k):
        if k < 2:
            return 1
        return k * helper(k - 1)
    return helper(n)
print(fact_via_helper(10))

# Mutual recursion between nested functions.
def parity(n):
    def ev(k):
        return True if k == 0 else od(k - 1)
    def od(k):
        return False if k == 0 else ev(k - 1)
    return ev(n), od(n)
print(parity(7))

# Captured parameter, captured loop variable (late binding: last value).
def loop_capture():
    fs = []
    for i in range(3):
        fs.append(lambda: i)
    return [f() for f in fs]
print(loop_capture())

# Defaults are evaluated when the def runs: this is the classic way to
# capture the current value.
def loop_capture_defaults():
    fs = []
    for i in range(3):
        def f(i = i):
            return i * 10
        fs.append(f)
    return [f() for f in fs]
print(loop_capture_defaults())

# Comprehension variables captured by lambdas.
print([g() for g in [lambda: j for j in range(3)]])
print([g(1) for g in [(lambda x, k = k: x + k) for k in range(3)]])

# Module-level names inside closures are just globals.
scale = 3
def scaler():
    return lambda x: x * scale
s = scaler()
scale = 4
print(s(5))
