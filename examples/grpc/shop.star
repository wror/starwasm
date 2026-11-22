# A gRPC server that is a client too: shop.Shop/Place (shop.proto), which
# asks shop.Prices/Quote (prices.star) the price of the order's first item
# before it answers. EXTENSIONS.md, "gRPC".
#
#   bin/starserve --addr=none --descriptor_set=examples/grpc/shop.binpb \
#       --grpc=localhost:50062 --grpc_target=shop.Prices=localhost:50061 \
#       examples/grpc/shop.star
#
# A request (a member of Place_request) makes a call (a member of
# Quote_call, which keeps what the answer will need: the fields that the
# PriceRequest hasn't aren't sent, but come back in the reply); the reply
# (a member of Quote_reply) makes the answer, a member of Place_response,
# reading nothing else, so that it is made once, when the reply comes.
# All three have the request's id (an implicit id carries through
# relations), which is how the answer is found.

def total(items):
    n = 0
    for i in items:
        n += i.qty
    return n

a Quote_call:
    sku: Place_request.items[0].sku
    customer: Place_request.customer
    qty: total(Place_request.items)
    skus: [i.sku for i in Place_request.items]

a Place_response:
    status: "%s: %d at %s" % (Quote_reply.customer, Quote_reply.qty, Quote_reply.price)
    total_qty: Quote_reply.qty
    skus: Quote_reply.skus
