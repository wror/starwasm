#!/bin/sh
# Test of bin/starserve (EXTENSIONS.md, "Serving reactive programs"): serves
# examples/order/order.star, sends it the requests below with curl, and
# compares the responses (status line, Location, body) with
# tests/serve/order.out. Then restarts it on the same journal, and checks
# that the orders are back.
cd "$(dirname "$0")/.."
if ! command -v curl > /dev/null; then
  echo "serve: skipped (no curl)"; exit 0
fi
mkdir -p out
port=${SERVE_PORT:-18473}
u=http://localhost:$port
journal=out/serve_order.journal
rm -f "$journal"
pid=
start() {
  bin/starserve --addr=localhost:$port --now=2026-11-13T12:00:00Z --journal="$journal" examples/order/order.star > out/serve.log 2>&1 &
  pid=$!
  for _ in $(seq 100); do
    curl -s -o /dev/null $u/ && return 0
    kill -0 $pid 2> /dev/null || break
    sleep 0.2
  done
  echo "serve: the server did not start"; sed 's/^/    /' out/serve.log; exit 1
}
stop() {
  kill $pid 2> /dev/null; wait $pid 2> /dev/null
}
req() { # req <curl args...>: the request, then the response
  echo "== $*"
  curl -s -i "$@" | tr -d '\r' | grep -v '^Date:\|^Content-Length:\|^Content-Type:'
  echo
}
start
{
  req $u/
  req $u/new
  req $u/style.css -o /dev/null -w '%{http_code} %{content_type}\n'
  req -e $u/new -d 'symbol=ZVZZT&qty=1&price=1.0' $u/order_request
  req -e $u/new -d 'symbol=A<b>"&qty=5&price=2' $u/order_request
  req -e $u/new -d 'symbol=X&qty=abc&price=2' $u/order_request
  req -e $u/new -d 'symbol=X&qty=1&price=1e999' $u/order_request
  req "$u/edit?order=1"
  req -e "$u/edit?order=1" -d 'id=1&order.version=1&symbol=ZVZZT&qty=7&price=1.5' $u/order_request
  req -e "$u/edit?order=1" -d 'id=1&order.version=1&symbol=ZVZZT&qty=9&price=1.5' $u/order_request
  req -d 'id=2&qty=8' $u/order_request
  req $u/index
  req "$u/edit?order=9"
  req $u/nosuch
  req -d 'qty=1' $u/order
  req -d 'qty=1' $u/nosuch
  req -X DELETE $u/order_request
  stop
  start
  echo "== after a restart"
  req $u/index.html
} > out/serve_order.got
stop
if cmp -s tests/serve/order.out out/serve_order.got; then
  echo "serve: ok ($(grep -c '^== ' out/serve_order.got) requests)"
else
  echo "serve: MISMATCH (expected vs got)"
  diff tests/serve/order.out out/serve_order.got | head -30 | sed 's/^/    /'
  exit 1
fi
