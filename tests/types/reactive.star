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

# a relation's errors (orderError) are a relation too
print([e.field + " after " + e.trigger for e in orderError])

# an implicit relation (shipment: nothing defines it) has the fields read
a delivery:
    to: shipment.address.upper()
    weight: shipment.kg * 2
print([s.kg for s in shipment], shipmentError)

# A definition, or a field of a struct block, may be None only where it ends
# in `?? None`: an update in which any other one would be None fails as a
# whole. So its type has no None unless it says so; a struct made by
# struct() elsewhere keeps the Nones of its fields.
stock = {"apple": 3}
wanted : "apple"
count : stock.get(wanted)                 # int: an update giving None fails
maybe : stock.get(wanted) ?? None         # int | None
an offer:
    item: request.name
    have: stock[request.name]
    left: stock.get(request.name + "-left") ?? None
    detail:
        price: stock[request.name] * 2
def entry(d, k):
    return struct(n = d[k])
