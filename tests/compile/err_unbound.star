def f():
    print("before")
    if False:
        y = 1
    return y
print("start")
f()
print("not reached")
