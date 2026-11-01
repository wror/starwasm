# error: 3:33: function fact called recursively
def fact(n):
    return 1 if n == 0 else n * fact(n - 1)
