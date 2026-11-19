# A reactive variable defined by a struct block that reads no other one is
# the constructor of the values standard input gives it: a struct gives
# fields by name, a list gives them in order, anything else is the first
# field; the fields not given keep the block's values, and a nested block
# is constructed the same way.
request:
    item: "apple"
    qty: 1
    ship:
        city: "Oslo"
        days: 3

print("request", request)

# a relation's members are constructed the same way; a field the block
# doesn't have (a reference, order_id) is kept
a fill:
    qty: 0
    price: 1.5

print("fills", fill)

# not a struct block: the value as given
tags : ["a"]
print("tags", tags)
