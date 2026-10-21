def key(x):
    return -x
print(sorted([1, 2], key = key))
print(sorted([3, "a"], key = lambda v: v * 2))
