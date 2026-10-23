# Top-level names resolve in source order, as starlark-go with
# GlobalReassign (bin/starhost): before its first binding, a name means the
# builtin of that name; after, the global.
print(len("abc"))
len = 1
print(len)
print(str(2))

def show():
    return str  # in a function: the global, whatever the order

str = "shadowed"
print(show())

# x += y: iterable y extends a list in place; anything else is x + y
def iadd(x, y):
    x += y
    return x

print(iadd([1], (2, 3)), iadd([1], {4: 5}), iadd([1], range(2)), iadd([1], "ab".elems()))
print(iadd((1,), (2,)), iadd("a", "b"), iadd(1, 2))
