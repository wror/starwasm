def f(a, b, c=1, *, d):
    return a
g = f
g(1, b=2, a=3, d=4)
