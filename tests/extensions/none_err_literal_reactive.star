# error: 4:23: == None: an operation on None is always None
# Contagious None is on by default in a program with reactive variables.
n : 4
print("unset" if n == None else n)
