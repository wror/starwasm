# error: if None: it is always an error
# option:contagiousnone
def f():
    if None:
        return 1
    return 2

print(f())
