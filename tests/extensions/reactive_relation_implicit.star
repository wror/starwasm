# Implicit relations: a name that a relation's definition reads and that
# nothing defines (request, stock) is a relation too: it starts empty, and
# standard input gives it members.
limit = 10

an order:
    product: request.name
    size: min(request.qty, limit)

# in a condition too; a comprehension's variable is not one
a shelf when stock.name == shelf.name or shelf.name == "":
    name: stock.name
    count: shelf.count + len([n for n in stock.added])

# anything can read an implicit relation: a lone definition its current
# member, an observer its list
last:
    name: request.name

print("orders", order)
print("shelves", shelf)
print("requests", request)
print("last", last)
print("request errors", requestError)
