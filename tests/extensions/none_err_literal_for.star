# error: for loop over None: it is always an error
# option:contagiousnone
def f():
    for v in None:
        print(v)

f()
