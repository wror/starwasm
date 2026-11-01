# error: reactive_err_default.star:3:11: reactive variable x can only be used
x : 1
def f(a = x):
    return a
