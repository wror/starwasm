# starwasm

A self-hosting Starlark → WebAssembly (WasmGC) compiler, written in Starlark.

**[▶ Try the REPL in your browser](https://wror.github.io/starwasm/)**: the
compiler, compiled to Wasm by itself, runs in the page and compiles each
input you type. (Needs a browser with WebAssembly GC: Chrome/Edge 119+,
Firefox 120+, Safari 18.2+.)

From a checkout, with Go ≥ 1.25 and Node ≥ 22 (and curl, for the tests),
at the top of the checkout:

    (cd host && go build -o ../bin/starhost .)       # first: it builds the compiler
    node host/repl.mjs                                # the REPL in a terminal (.help, .quit)
    node host/run.mjs examples/hello.star             # run a program
    node host/typecheck.mjs examples/hello.star       # check its types (writes examples/hello.starit)
    printf 'qty : 3\n' | node host/run.mjs examples/total.star   # a reactive program
    (cd host && go build -o ../bin/starserve ./serve)
    bin/starserve examples/order/order.star           # a reactive program as a web site: http://localhost:8080/
    ./test.sh                                         # everything

A program's first run takes a while (it is compiled); the Wasm is cached
in `__wasmcache__/` next to it.

See [NOTES.md](NOTES.md) for the design and layout, and
[EXTENSIONS.md](EXTENSIONS.md) for features beyond starlark-go.
Among them: reactive variables (`total : price * qty`, recomputed as
standard input assigns new values); contagious None, which makes a
running reactive program keep going through errors: what fails becomes a
None that carries the error, and an update in which a variable would be
None where its definition doesn't allow it (`... ?? None`) is undone as a
whole and recorded in that variable's relation of errors; and serving a reactive program as web
pages, from HTML templates.
