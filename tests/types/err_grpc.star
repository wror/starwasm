# descriptor_set: examples/grpc/shop.binpb
# Mistakes with gRPC's relations, found from shop.proto.
a Place_response:
    total_qty: "four"
    skus: Place_request.customer
    status: Place_request.items[0].nope

a Quote_call:
    sku: 3

a priced:
    cents: Quote_reply.price * 100 + Quote_reply.weight
