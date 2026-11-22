# descriptor_set: examples/grpc/shop.binpb
# gRPC (EXTENSIONS.md, "gRPC"): the relations bin/starserve gives the
# program are typed from the messages of shop.proto, and what it defines
# for them is checked against them.

def total(items):
    n = 0
    for i in items:
        n += i.qty
    return n

# served: shop.Shop/Place
a Quote_call:
    sku: Place_request.items[0].sku
    customer: Place_request.customer
    qty: total(Place_request.items)
    rush: "rush" in [n.value for n in Place_request.notes]

a Place_response:
    status: "%s: %d at %s" % (Quote_reply.customer, Quote_reply.qty, Quote_reply.price)
    total_qty: Quote_reply.qty
    skus: [Quote_reply.sku]

# called: shop.Prices/Quote, and what comes back
a late:
    sku: Quote_failure.sku
    why: Quote_failure.code + ": " + Quote_failure.message
