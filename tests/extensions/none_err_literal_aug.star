# error: += None: an operation on None is always None
# option:contagiousnone
def f(y):
    y += None
    return y

print(f(1))
