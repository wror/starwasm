# The reactive extension (EXTENSIONS.md): reactive variables have the type
# of their definition; a struct block is a struct (with the id it gets),
# and a relation is a table: a list of structs.
load("modules/shapes.star", "area")

width : 3
height : 4
size : area(struct(width = width, height = height))
total : total + size
print("size is", size)

request:
    name: "foo"
    qty: 1

an order:
    product: request.name
    size: request.qty

a line when order.product == line.product or line.product == "":
    product: order.product
    count: line.count + order.size

summary:
    last: order.product
    lines: line.count

print(order)
print([o.size for o in order])
