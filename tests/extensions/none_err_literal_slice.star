# error: slice of or by None: an operation on None is always None
# option:contagiousnone
l = [1]
print(l[None:1])
