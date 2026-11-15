# error: != None: an operation on None is always None
# option:contagiousnone
def f(v):
    if None != v:
        return 1
    return 2

print(f(1))
