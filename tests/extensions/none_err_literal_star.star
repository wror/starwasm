# error: call with * None: an operation on None is always None
# option:contagiousnone
def f(*a):
    return a

print(f(*None))
