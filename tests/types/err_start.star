# Mistakes in the annotation file itself are reported there.

def area(shape):
    return shape.width * shape.height

def scale(v, k):
    return [x * k for x in v]

def pick(r, field):
    return getattr(r, field)

def tail(r):
    return r.id

limit = 10
names = ["a"]
