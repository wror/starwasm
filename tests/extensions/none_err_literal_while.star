# error: while None: it is always an error
# option:contagiousnone
# option:globalreassign
def f():
    while None:
        return 1
    return 2

print(f())
