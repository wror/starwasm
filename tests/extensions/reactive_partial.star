# In an update, a struct block's field that reads other reactive variables
# is recomputed only if one of them changed; else it keeps its value (for a
# relation, from the member being replaced). Fields that read none
# (constants, counters reading only the variable's own previous value) are
# always recomputed; nested blocks' fields each on their own.
an order:
    qty: request.qty ?? order.qty
    executed: order.executed + (fill.qty ?? 0)   # a new request doesn't add the fill again
    updates: order.updates + 1                   # counts every update of the order
    status: "open"
    cost:
        unit: price.amount ?? 0
        total: (price.amount ?? 0) * (request.qty ?? order.qty)

# a lone block: `seen` keeps the first name until the name changes
a_name : "x"
a_size : 1
tag:
    seen: tag.seen + a_name
    size: a_size

print("orders", order)
print("tag", tag)
