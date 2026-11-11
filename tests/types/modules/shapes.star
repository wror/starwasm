def area(shape):
    return shape.width * shape.height

def scaled(shape, k):
    return shape + struct(width = shape.width * k, height = shape.height * k)

def label(shape):
    return shape.name + " " + str(area(shape))

UNIT = struct(width = 1, height = 1)
_private = 1
