# option:nocontagiousnone
# reactive_relation_keyed.star without contagious None: a definition that
# reads a relation with no member for the update is skipped instead.
a fill:
    qty: 0

an order:
    qty: request.qty
    executed: order.executed + fill.qty

# no `??`: an order isn't shipped until it has a fill
a shipment:
    qty: fill.qty
    of: order.qty

print("fills", fill)
print("orders", order)
print("shipments", shipment)
print("shipment errors", [(e.shipment_id, e.field, e.trigger) for e in shipmentError])
