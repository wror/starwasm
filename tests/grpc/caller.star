# tests/grpc.sh's client: each form posted makes a call of shop.Shop/Place
# (examples/grpc/shop.star) or shop.Prices/Quote (prices.star), and
# index.html shows the replies and failures, in order.
an order:
    customer: "ann"
    sku: "apple"
    qty: 1
    n: 1          # how many items of it

a Place_call:
    customer: order.customer
    side: "BUY"
    items: [struct(sku = order.sku, qty = order.qty)] * order.n
    notes: [struct(key = "n", value = str(order.n))]

an ask:
    sku: "apple"

a Quote_call:
    sku: ask.sku
    asked: "yes"     # not the request's: it comes back in the reply

a reply:
    text: "Place %d: %s (%d; %s)" % (Place_reply.Place_call_id, Place_reply.status, Place_reply.total_qty, ", ".join(Place_reply.skus))

a quote:
    text: "Quote %d: %s %s (asked: %s)" % (Quote_reply.Quote_call_id, Quote_reply.sku, Quote_reply.price, Quote_reply.asked)

a failure:
    text: "Place %d failed: %s: %s (customer %s)" % (Place_failure.Place_call_id, Place_failure.code, Place_failure.message, Place_failure.customer)
