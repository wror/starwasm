def f():
    def g():
        return y
    print("calling")
    r = g()
    y = 1
    return r
f()
