# starwasm

A self-hosting Starlark → WebAssembly (WasmGC) compiler, written in Starlark.

**[▶ Try the REPL in your browser](https://wror.github.io/starwasm/)**: the
compiler, compiled to Wasm by itself, runs in the page and compiles each
input you type. (Needs a browser with WebAssembly GC: Chrome/Edge 119+,
Firefox 120+, Safari 18.2+.)

From a checkout, with Go and Node ≥ 22:

    (cd host && go build -o ../bin/starhost .)
    node host/repl.mjs                 # the REPL in a terminal
    node host/run.mjs prog.star        # run a program
    node host/typecheck.mjs prog.star  # check its types (infers them into prog.starit)
    ./test.sh                          # everything

See [NOTES.md](NOTES.md) for the design and layout, and
[EXTENSIONS.md](EXTENSIONS.md) for features beyond starlark-go.
