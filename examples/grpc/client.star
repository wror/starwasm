# A gRPC client with web pages: posting the form on / calls
# shop.Shop/Place (shop.star) and the page shows the replies.
# EXTENSIONS.md, "gRPC".
#
#   bin/starserve --addr=localhost:8080 --descriptor_set=examples/grpc/shop.binpb \
#       --grpc_target=shop.Shop=localhost:50062 examples/grpc/client.star
#
# Each new member of Place_call is a call; its reply is a member of
# Place_reply (with Place_call_id), or, if it fails, of Place_failure
# (code, message).

an order:            # what the form posts
    customer: "ann"
    sku: "apple"
    qty: 1

a Place_call:
    customer: order.customer
    side: "BUY"
    items: [struct(sku = order.sku, qty = order.qty), struct(sku = "plum", qty = 1)]
    notes: [struct(key = "via", value = "web")]

a placed:
    call: Place_reply.Place_call_id
    order_id: Place_reply.id
    status: Place_reply.status
    skus: ", ".join(Place_reply.skus)

a failed:
    call: Place_failure.Place_call_id
    code: Place_failure.code
    message: Place_failure.message
