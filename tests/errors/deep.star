def f(n):
    if n == 0:
        return 1 // n
    return f(n - 1) + 1

def g(xs, k = len):
    return [k(x) for x in xs]

print(g(["ab", "c"]))
print(f(3))
