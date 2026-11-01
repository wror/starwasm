# A function may read a global assigned later in the file.
def f():
    return x + 1

x = 41
print(f())
print([y + x for y in [1, 2]])

# ... and a loaded name, if called after the load
def g():
    return helper()

load("modules/util.star", "helper")
print(g())
