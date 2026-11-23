# With contagious None (on here: the program has a reactive variable), what
# nothing tells the type of may be None, and is shown as `Any | None`; but
# not in a reactive variable's value (an update in which it would be None
# fails, and standard input can't give one inside it), nor in a field that
# an implicit relation's members must have: there it is shown as Any.

an order:
    qty: req.qty                    # members must have qty: Any

print([r.other for r in req])       # other may be missing: Any | None

xs : []                             # xs: list[Any]
seen = []                           # seen: list[Any | None]

tick : 1
