# A gRPC server: shop.Prices/Quote (shop.proto), answered in the update
# that the request makes. EXTENSIONS.md, "gRPC".
#
#   bin/starserve --addr=none --descriptor_set=examples/grpc/shop.binpb \
#       --grpc=localhost:50061 examples/grpc/prices.star
#
# Each request is a new member of Quote_request (a struct of the
# PriceRequest's fields); the answer is the member of Quote_response that
# it makes (a struct of the PriceReply's fields).

PRICES = {"apple": 0.5, "pear": 0.75, "plum": 1.25}

a Quote_response:
    sku: Quote_request.sku
    price: PRICES.get(Quote_request.sku, 1.0)
