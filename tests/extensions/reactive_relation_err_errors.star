# error: reactive variable orderError defined twice (relation order defines it: its errors)
request:
    name: "foo"
an order:
    product: request.name
orderError : 1
