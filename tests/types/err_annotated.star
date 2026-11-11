# Programs that don't keep the promises of err_annotated.start.

def area(shape):
    return shape.width * shape.depth

def first(xs):
    return xs[0] + 1

def identity(x):
    return str(x)

def find(xs, want):
    for x in xs:
        if x == want:
            return x

def mean(values):
    total = "0"
    for v in values:
        total += v
    return total / len(values)

def size(x):
    return len(x) + x.count

limit = "ten"
names = [1, 2]
a = area(struct(width = 1, height = 2, depth = 3))
b = first(["a"])
c = find([1], 1) + 1
