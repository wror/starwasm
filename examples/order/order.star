# An order book served over HTTP (EXTENSIONS.md, "Serving reactive programs"):
#
#     bin/starserve examples/order/order.star      # then open http://localhost:8080/
#
# The pages are index.html (the orders), new.html and edit.html?order=<id>;
# their forms post to /order_request, a relation that reads no other
# reactive variable. A request without an id is a new one; one with an id
# replaces that request, and so updates that order.

# What a form sends: the values here give the fields' types (and are what a
# field the form leaves out gets). `time` is filled in by the server.
an order_request:
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
