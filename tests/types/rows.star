# Structs are records over rows (Paszke & Xie, "Infix-Extensible Record
# Types for Tabular Data"): row polymorphism, concatenation anywhere in a
# row, scoped labels, and field names as values.

point = struct(x = 1, y = 2)
named = struct(name = "origin", x = 0, y = 0)

# row polymorphism: any struct with (at least) the fields that are used
def norm1(p):
    return abs(p.x) + abs(p.y)

a = norm1(point)
b = norm1(named)

# a struct that passes through keeps all its fields
def moved(p, dx):
    return p + struct(x = p.x + dx)

def origin_of(p):
    return p + struct(x = 0, y = 0)

c = origin_of(named)
c_name = c.name

# struct + struct concatenates rows; the right operand's fields come
# first (they win), and a row variable can be anywhere in a row
def tagged(r):
    return r + struct(tag = "t")

def with_default_id(r):
    return struct(id = 0) + r

d = tagged(point)
e = with_default_id(point)
e_id = e.id

# scoped labels: a field shadows a later field of the same name
f = point + struct(x = "one")
f_x = f.x
g = with_default_id(struct(id = "mine"))
g_id = g.id

def join(left, right):
    return left + right

h = join(point, struct(z = 3))

# field names are values (first-class labels): getattr with a name that
# is a variable is typed by the name's own type
def get(r, field):
    return getattr(r, field)

def column(table, field):
    return [getattr(r, field) for r in table]

i = get(named, "name")
j = get(named, "x")
key = "y"
k = get(point, key)
table = [named, struct(name = "p", x = 3, y = 4)]
names = column(table, "name")
xs = column(table, "x")

# a table (a list of structs) and functions over it
def where(table, pred):
    return [r for r in table if pred(r)]

def add_column(table, f):
    return [r + struct(extra = f(r)) for r in table]

far = where(table, lambda r: r.x > 1)
wide = add_column(table, lambda r: r.x * 1.5)
extras = column(wide, "extra")

# getattr with a default, hasattr, nested structs
maybe = getattr(point, "z", 0)
has_z = hasattr(point, "z")
line = struct(start = point, end = struct(x = 5, y = 5))
dx = line.end.x - line.start.x
