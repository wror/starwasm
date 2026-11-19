# A relation's member with a None field isn't applied (EXTENSIONS.md): the
# relation stays as it was, none of the member's fields are updated, and
# what reads the relation isn't recomputed. (The errors are on stderr.)
prices = {"apple": 3, "pear": 2}
request:
    item: "apple"
    qty: 1

# by id: the member with the request's id is replaced, or not at all
an order:
    item: request.item
    price: prices.get(request.item)
    count: order.count + 1

# a None in a nested block counts too
a parcel:
    item: request.item
    cost:
        total: prices[request.item] * request.qty

# a relation that reads no reactive variable, assigned on standard input:
# a member with a None field isn't applied either
a sale:
    item: ""
    price: 0

# computed from the relation: not recomputed when no member is applied
last : order.item
print("last", last)

# with a condition: if any of the new members has a None field, none of
# them is applied
rate : 1
a line when line.qty <= rate:
    qty: line.qty + 1
    share: 100 // (rate - line.qty)

print("orders", order)
print("parcels", parcel)
print("sales", sale)
print("lines", line)

# Each relation has a relation of errors, <name>Error: a member for each
# None that kept a member from being applied
def show(label, errors):
    for e in errors:
        print(label, e.id, e.trigger, repr(e.field), [p[:2] for p in provenance(e.value)][:1])

show("orderError", [struct(id = e.id, trigger = e.trigger, field = e.field, value = e.value) for e in orderError])
print("order ids", [e.order_id for e in orderError])
show("parcelError", parcelError)
show("saleError", saleError)
print("line ids", [(e.line_id, e.field) for e in lineError])

# and it is a relation like any other: read in a definition, it is its
# current member
complaint:
    about: orderError.order_id
    what: orderError.field + " of order, after " + orderError.trigger
print(complaint)
