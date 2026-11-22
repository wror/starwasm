# starwasm

A self-hosting [Starlark](https://starlark-lang.org/) → WebAssembly (WasmGC) compiler, written in Starlark.

**[▶ Try the REPL in your browser](https://wror.github.io/starwasm/)**: the
compiler, compiled to Wasm by itself, runs in the page and compiles each
input you type. (Needs a browser with WebAssembly GC: Chrome/Edge 119+,
Firefox 120+, Safari 18.2+.)

From a checkout, with Go ≥ 1.25 and Node ≥ 22 (and curl, for the tests),
at the top of the checkout:

    (cd host && go build -o ../bin/starhost .)       # first: build the compiler

    node host/repl.mjs                                # the REPL in a terminal (.help, .quit)
    node host/run.mjs examples/hello.star             # run a program
    node host/typecheck.mjs examples/hello.star       # check its types (writes examples/hello.starit)
    printf 'qty : 3\n' | node host/run.mjs examples/total.star   # a reactive program
    (cd host && go build -o ../bin/starserve ./serve)
    bin/starserve examples/order/order.star           # a reactive program as a web site: http://localhost:8080/
    bin/starserve --addr=none --descriptor_set=examples/grpc/shop.binpb \
        --grpc=localhost:50061 examples/grpc/prices.star  # ... or a gRPC server (and client: EXTENSIONS.md, "gRPC")

    ./test.sh                                         # build and test everything

A program's first run takes a while (it is compiled); the Wasm is cached
in `__wasmcache__/` next to it.

See [NOTES](NOTES.md) for the design and layout, and
[EXTENSIONS](EXTENSIONS.md) for features beyond starlark-go, and
[PRECEDENCE](PRECEDENCE.md) for the operator precedence the type
checker requires.

New language features on top of starlark:
* reactive variables
* contagious None with provenance
* type inference with row polymorphism and "None safety"
* unambiguous operator precedence
* reactive relations
* basic templating and a simple web framework

The web repl has amenities:
* local storage for replay-based persistence
* tab completion
