# error: reactive_err_nested_function.star:6:16: function g refers to reactive variable x
x : 1
def f():
    y = 2
    def g():
        return x + y
    return g
print(f()())
