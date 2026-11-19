# A relation with a condition (`a name when cond:`) updates the members for
# which cond is true, instead of the member with the triggering change's
# id; cond reads the member as the self-reference.
dingbat:
    b: "foo"
    c: "bar"

# (its members come from its condition: a relation computed from others
# can't be assigned)
a wally when (dingbat.b == wally.e or wally.e == "") and not dingbat.b.startswith("a"):
    e: dingbat.b
    f: dingbat.c

# with no member matching, cond reads the identity (a new member): here
# the first item of each name is added, and later ones update it
item:
    name: ""
    qty: 0

a stock when item.name != "" and (stock.name == item.name or stock.name == ""):
    name: item.name
    total: stock.total + item.qty
    updates: stock.updates + 1

print("wally", wally)
print("stock", stock)
