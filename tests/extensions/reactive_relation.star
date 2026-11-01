# Relations: a struct block preceded by `a` or `an` defines a reactive list
# of structs. Each recomputation adds a member, or replaces the member with
# the same id, the id being the triggering change's.
request:
    name: "foo"
    qty: 1

an order:
    product: request.name
    size: request.qty

a product_request:
    product: order.product

# a lone struct read from a relation gets the triggering member's id
response:
    name: order.product
    qty: order.size

print("response", response)
print("orders", order)
print("product requests", product_request)
