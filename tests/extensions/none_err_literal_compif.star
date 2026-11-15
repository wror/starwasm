# error: if None: an operation on None is always None
# option:contagiousnone
print([v for v in [1] if None])
