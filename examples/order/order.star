# An order book served over HTTP (EXTENSIONS.md, "Serving relations"):
#
#     bin/starserve examples/order/order.star      # then open http://localhost:8080/order
#
# The forms in order_create.html and order_update.html post an
# order_request; each one adds or replaces the order with its id.

# What a form sends: the values here give the fields' types (and are what a
# field the form leaves out gets). `time` is filled in by the server.
order_request:
    symbol: "ZVZZT"
    qty: 1
    price: 1.0
    time: ""

an order:
    clordid: str(order_request.id)
    symbol: order_request.symbol
    qty: order_request.qty
    price: order_request.price
    lastupdate: order_request.time
    version: order.version + 1
