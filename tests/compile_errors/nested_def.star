# error: 3:14: duplicate parameter: x
def f():
    def g(x, x):
        pass
