#!/bin/sh
# Test that a state change doesn't re-send an outgoing event: runs
# examples/grpc/prices.star (a server) and tests/grpc_refire/refire.star (a
# client, driven by posting forms to it with curl). Asking for a quote
# (the incoming event ask) makes one Quote call. Then changing note, state
# that Quote_call also reads, must make no other call: nothing new came
# in. Fails while it does (it re-evaluates Quote_call, whose member is
# then a new value, so serve/grpc.star calls again). Not run by test.sh
# until that is fixed.
cd "$(dirname "$0")/.."
if ! command -v curl > /dev/null; then
  echo "grpc refire: skipped (no curl)"; exit 0
fi
mkdir -p out
base=${GRPC_REFIRE_PORT:-18570}
p1=$((base + 1)); http=$((base + 2)); shttp=$((base + 3))
u=http://localhost:$http
s=http://localhost:$shttp   # the server's page: the requests it got
ds=--descriptor_set=examples/grpc/shop.binpb
bin/starserve --addr=localhost:$shttp --templates=tests/grpc_refire/server $ds --grpc=localhost:$p1 \
  examples/grpc/prices.star > out/grpc_refire_prices.log 2>&1 &
prices=$!
bin/starserve --addr=localhost:$http $ds --grpc_target=shop.Prices=localhost:$p1 --grpc_timeout=3s \
  tests/grpc_refire/refire.star > out/grpc_refire_client.log 2>&1 &
client=$!
trap 'kill $prices $client 2> /dev/null; wait $prices $client 2> /dev/null' EXIT
up=0
for _ in $(seq 150); do
  curl -s -o /dev/null $u/ && curl -s -o /dev/null $s/ && { up=1; break; }
  sleep 0.2
done
if [ $up = 0 ]; then
  echo "grpc refire: the servers did not start"; sed 's/^/    /' out/grpc_refire_*.log; exit 1
fi
# (counted on the server: on the client, a second reply has the call's id
# and replaces the first in quote)
calls() { curl -s $s/ | grep -c '^<p>'; }
quotes() { curl -s $u/ | grep -c '^<p>'; }
# wait_for <n>: until the server has had n calls and the client shows a quote (at most 3s)
wait_for() {
  for _ in $(seq 30); do
    [ "$(calls)" -ge "$1" ] && [ "$(quotes)" -ge 1 ] && return
    sleep 0.1
  done
}
curl -s -o /dev/null -d 'sku=plum' $u/ask
wait_for 1
if [ "$(calls)" != 1 ] || [ "$(quotes)" != 1 ]; then
  echo "grpc refire: not one call and one quote for the ask"; curl -s $u/ | sed 's/^/    /'; exit 1
fi
curl -s -o /dev/null -d 'note=changed' $u/note
wait_for 2   # (a second call's reply, if one was made)
n=$(calls)
if [ "$n" = 1 ]; then
  echo "grpc refire: ok (one call)"
else
  echo "grpc refire: FAIL: changing note called Quote again ($n calls)"
  echo "    server's requests:"; curl -s $s/ | sed 's/^/      /'
  echo "    client's page:"; curl -s $u/ | sed 's/^/      /'
  exit 1
fi
