# error: iteration over None: an operation on None is always None
# option:contagiousnone
def f():
    for v in None:
        print(v)

f()
