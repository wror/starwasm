# error: reactive_err_function.star:5:12: function f refers to reactive variable x (pass it as an argument instead)
# Functions must get reactive values as arguments.
x : 1
def f():
    return x + 1
print(f())
