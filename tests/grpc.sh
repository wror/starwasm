#!/bin/sh
# Test of gRPC in bin/starserve (EXTENSIONS.md, "gRPC"): runs
# examples/grpc/prices.star (a server), examples/grpc/shop.star (a server
# that calls prices) and tests/grpc/caller.star (a client, driven by
# posting forms to it with curl), and compares the caller's page, which
# shows the replies and failures, with tests/grpc/caller.out. Then stops
# the price server, and the shop, and checks the failures.
cd "$(dirname "$0")/.."
if ! command -v curl > /dev/null; then
  echo "grpc: skipped (no curl)"; exit 0
fi
mkdir -p out
base=${GRPC_PORT:-18560}
p1=$((base + 1)); p2=$((base + 2)); http=$((base + 3))
u=http://localhost:$http
ds=--descriptor_set=examples/grpc/shop.binpb
bin/starserve --addr=none $ds --grpc=localhost:$p1 examples/grpc/prices.star > out/grpc_prices.log 2>&1 &
prices=$!
bin/starserve --addr=none $ds --grpc=localhost:$p2 --grpc_target=shop.Prices=localhost:$p1 --grpc_timeout=3s \
  examples/grpc/shop.star > out/grpc_shop.log 2>&1 &
shop=$!
bin/starserve --addr=localhost:$http $ds --grpc_target=shop.Shop=localhost:$p2 --grpc_target=shop.Prices=localhost:$p1 \
  --grpc_timeout=3s tests/grpc/caller.star > out/grpc_caller.log 2>&1 &
caller=$!
# (and wait for them to end: the next run listens on the same ports)
trap 'kill $prices $shop $caller 2> /dev/null; wait $prices $shop $caller 2> /dev/null' EXIT
up=0
for _ in $(seq 150); do
  curl -s -o /dev/null $u/ && { up=1; break; }
  sleep 0.2
done
if [ $up = 0 ]; then
  echo "grpc: the servers did not start"; sed 's/^/    /' out/grpc_*.log; exit 1
fi
# post <path> <form> <lines>: post, then wait until the page has that many lines
post() {
  curl -s -o /dev/null -d "$2" $u/$1
  for _ in $(seq 100); do
    [ "$(curl -s $u/ | grep -c '^<p>')" -ge "$3" ] && return
    sleep 0.1
  done
}
post order 'customer=bob&sku=pear&qty=3' 1
post order 'customer=cy&sku=kiwi&qty=2&n=2' 2
post ask 'sku=plum' 3
post order 'customer=di&n=0' 4          # no items: the shop refuses it
kill $prices; wait $prices 2> /dev/null
post order 'customer=ed&sku=pear' 5    # the shop gets no price: no answer in time
kill $shop; wait $shop 2> /dev/null
post order 'customer=fay' 6            # no shop
curl -s $u/ | sed -e 's/&quot;/"/g' -e 's/127\.0\.0\.1:[0-9]*/ADDR/g' -e 's/DEADLINE_EXCEEDED: [^(]*(/DEADLINE_EXCEEDED: ... (/' > out/grpc_caller.got
if cmp -s tests/grpc/caller.out out/grpc_caller.got; then
  echo "grpc: ok ($(wc -l < out/grpc_caller.got | tr -d ' ') answers)"
else
  echo "grpc: MISMATCH (expected vs got)"
  diff tests/grpc/caller.out out/grpc_caller.got | sed 's/^/    /'
  exit 1
fi
