# In a relation's definition, another relation reads as its member for the
# update: the one whose <name>_id (else id) is the update's key. With no
# such member (none matches, or the relation is empty) it reads as None,
# which `??` can replace; a field left None holds the member back, and
# <name>Error says why. A relation that reads no reactive variable starts
# with one member.
a fill:
    qty: 0

an order:
    qty: request.qty ?? order.qty
    executed: order.executed + (fill.qty ?? 0)

# no `??`: an order isn't shipped until it has a fill
a shipment:
    qty: fill.qty
    of: order.qty

print("fills", fill)
print("orders", order)
print("shipments", shipment)
print("shipment errors", [(e.shipment_id, e.field, e.trigger, provenance(e.value)[0][:2]) for e in shipmentError])
