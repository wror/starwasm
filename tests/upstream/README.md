# starlark-go's own tests

`node tests/upstream/run.mjs` runs the test scripts that ship with
go.starlark.net (the version `host/go.mod` pins) against starwasm. test.sh
runs it too.

    node tests/upstream/run.mjs              # all files
    node tests/upstream/run.mjs bool.star    # some files
    node tests/upstream/run.mjs -v           # every verdict's details
    COMPILER="node host/run.mjs out/stage2.wasm --" node tests/upstream/run.mjs

It needs `bin/starhost`, `bin/upstreamhost`
(`cd host && go build -o ../bin/upstreamhost ./upstream`, which test.sh
does) and the starlark-go source, found with `go list -m` in host/ (or set
`STARLARK_GO_DIR`). Results: `out/upstream/report.txt`,
`out/upstream/results.json`; each chunk's files are in
`out/upstream/<file>-<chunk>/`.

## Files run

As starlark-go's TestExecFile, TestResolve and TestParseErrors:

- starlark/testdata: assign, bool, builtins, bytes, control, dict, float,
  function, int, list, misc, set, string, tuple, recursion, while: compiled
  with `--test` and run.
- starlarkstruct/testdata/struct.star: its first 19 lines (the rest needs
  the Go test's `gensym`).
- resolve/testdata/resolve.star: compiled only; static errors.
- syntax/testdata/errors.star and scan.star: parsed only
  (tests/upstream/parse_only.star, on starwasm's front end).

Not run: json, math, time, proto (Go library modules), module.star (tests
starlarkstruct's module type, which assert.star replaces with struct),
benchmark, bazel, paths, function_param (not test scripts).

A few lines that use the Go test's values (`hasfields`, `fibonacci`) are
blanked out (line numbers stay put); see FILES in run.mjs. assign.star's
chunk 34 is all about hasfields and shows as n/a.

## How a chunk runs

Files are split into chunks at `---` lines; `### "regexp"` on a line means
that line must fail with a matching error (as
go.starlark.net/internal/chunkedfile). Every chunk runs three ways:

- **upstream**: `bin/upstreamhost -options=file`, starlark-go with only the
  dialect options the chunk names (`option:set` etc.). This checks the
  harness: these all pass except the hasfields chunk.
- **reference**: `bin/upstreamhost -options=starwasm`, starlark-go with
  every option on (as bin/starhost and the compiler) and starwasm's
  predeclared names.
- **starwasm**: the chunk compiled with `compiler/main.star --test` and run
  by Node; for syntax/testdata, parsed by parse_only.star.

`load("assert.star", "assert", "freeze")` finds `tests/upstream/assert.star`,
copied next to each chunk: starlark-go's starlarktest/assert.star on five
test-only builtins that only `--test` programs see (TEST_BUILTINS in
compiler/codegen.star; add_test_builtins in lib/builtins.star;
bin/upstreamhost has the same):

    test_catch(f)          f()'s error message, or None
    test_error(msg)        report an assertion failure and carry on
    test_matches(pat, s)   regexp match (host syntax: Go's / JavaScript's)
    test_freeze(x)         deep-freeze x
    test_floateq(x, y)     equal within 1 ULP

`test_catch` works through the host: the `catch` import calls f via the
`test_call0` export inside a JavaScript try/catch, so a Starlark error
unwinds the Wasm frames in between. A for loop cut short this way stays
counted as iterating over its sequence (no test depends on it).

## Verdicts

- **pass**: every assertion holds and every `###` error happens.
- **first**: static chunk; starwasm reported the first expected error and
  stopped (starlark-go's resolver reports all of them).
- **static**: the expected run-time error (a load() of a missing name),
  reported by starwasm's compiler instead.
- **wording**: static chunk; starwasm's first error is on the expected line
  but worded differently. Only run-time errors are meant to match
  starlark-go's text.
- **dialect**: the reference fails too: the chunk depends on an option
  being off (e.g. "global variable cannot be reassigned"), or on a name
  starwasm doesn't predeclare (the resolver tests' `M`, `U`).
- **n/a**: the upstream run fails (needs a Go-only test value).
- **known**: a failure listed in known_failures.txt.
- **FAIL**: anything else. run.mjs exits 1 on these, and on a listed
  known failure that passes now.
