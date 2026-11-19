# option:globalreassign
# With --globalreassign a reactive variable may be defined again: the
# last definition replaces the earlier one everywhere (y, defined between
# the two, follows the new x), and its value counts as a change of x.
a : 1
x : a + 1
y : x * 10
print("y", y)
x : a + 2
print("x", x, "y", y)

# redefined by a value that reads no reactive variable: a source, which
# standard input updates and nothing recomputes
b : a * 3
b : 100
print("b", b)

# a relation keeps its members; shipment follows the new order
an order:
    qty: request.qty

a shipment:
    of: order.qty

an order:
    qty: request.qty * 2
    note: "doubled"

print("orders", order)
print("shipments", shipment)
