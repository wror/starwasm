# Errors about struct fields.

def area(shape):
    return shape.width * shape.height

def name_of(x):
    return x.name

point = struct(x = 1, y = 2)
print(point.z)
print(point.X)
a = area(struct(width = 3, hieght = 4))
b = name_of(point)
c = name_of("text")
point.x = 5
d = point["x"]

def id_of(r):
    return (struct(id = 0) + r).id

def get(r, field):
    return getattr(r, field)

e = get(point, "w")
f = getattr(point, "q")
g = struct(a = 1, a = 2)
h = point + 1
