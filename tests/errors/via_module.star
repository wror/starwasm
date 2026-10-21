load("../compile/modules/mathlib.star", "apply_twice")
def bad(x):
    return x + "!"
print(apply_twice(bad, 1))
