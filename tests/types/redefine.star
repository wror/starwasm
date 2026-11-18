# A reactive variable defined again (the compiler's --globalreassign): its
# type is its last definition's, which replaces the earlier one.
an order:
    qty: request.qty

an order:
    qty: request.qty * 2
    note: "doubled"

print([o.note for o in order])
