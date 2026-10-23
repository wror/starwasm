#!/bin/sh
# Build the host if needed, run Starlark unit tests, build example modules
# and compare their output against golden files, and run the runtime's
# differential test against starlark-go.
set -eu
cd "$(dirname "$0")"

if [ ! -x bin/starhost ] || [ host/main.go -nt bin/starhost ]; then
  (cd host && go build -o ../bin/starhost .)
fi
if [ ! -x bin/upstreamhost ] || [ host/upstream/main.go -nt bin/upstreamhost ]; then
  (cd host && go build -o ../bin/upstreamhost ./upstream)
fi

for t in tests/*_test.star; do
  bin/starhost "$t"
done

mkdir -p out
fail=0
run() { # run <name> <export> [args...]
  name=$1; shift
  golden="tests/golden/$name.$1.txt"
  got=$(node host/run.mjs "out/$name.wasm" "$@")
  if [ "$got" = "$(cat "$golden")" ]; then
    echo "$name.$1: ok"
  else
    echo "$name.$1: MISMATCH"; echo "--- want"; cat "$golden"; echo "--- got"; echo "$got"
    fail=1
  fi
}

bin/starhost examples/demo.star out/demo.wasm
run demo answer
run demo fact 20
run demo main

# Runtime: the same program as plain Starlark (run by starlark-go) and as
# Wasm built on the generated runtime (run by Node) must print the same.
bin/starhost tests/runtime/expect.star > out/runtime_expect.txt
bin/starhost tests/runtime/build.star out/runtime_test.wasm
node host/run.mjs out/runtime_test.wasm main > out/runtime_got.txt || true
if diff -u out/runtime_expect.txt out/runtime_got.txt; then
  echo "runtime differential: ok ($(wc -l < out/runtime_expect.txt | tr -d ' ') lines)"
else
  echo "runtime differential: MISMATCH (diff above is starlark-go vs wasm)"
  fail=1
fi

# Runtime error paths: each export must exit 1 with the golden message.
: > out/runtime_errors.txt
for e in $(sed 's/:.*//' tests/golden/runtime_errors.txt); do
  printf '%s: ' "$e" >> out/runtime_errors.txt
  status=0
  node host/run.mjs out/runtime_test.wasm "$e" 2>> out/runtime_errors.txt >/dev/null || status=$?
  if [ "$status" != 1 ]; then
    echo "$e: expected exit status 1, got $status"
    fail=1
  fi
done
if diff -u tests/golden/runtime_errors.txt out/runtime_errors.txt; then
  echo "runtime errors: ok"
else
  echo "runtime errors: MISMATCH"
  fail=1
fi

# Compiler: differential tests of compiled programs vs starlark-go.
tests/compile.sh || fail=1
tests/compile_errors.sh || fail=1
# Extensions starlark-go lacks: compared against expected output files.
tests/extensions.sh || fail=1

# starlark-go's own test files (tests/upstream/README.md): fails on any
# failure not in tests/upstream/known_failures.txt.
node tests/upstream/run.mjs > out/upstream.txt || { cat out/upstream.txt; fail=1; }
grep '^upstream: [0-9]' out/upstream.txt

# Self-hosting preview: compile the compiler's own front end (lexer +
# parser), run it on every source file in the project, and compare its
# token/AST dump with the interpreted front end's.
bin/starhost tests/selfhost/gen_frontend_test.star out/frontend.star
bin/starhost compiler/main.star out/frontend.star out/frontend.wasm
n=0
# (The bootstrap below checks the whole compiler; this covers the sources.)
for f in lib/*.star compiler/*.star compiler/ext/*.star tests/*.star tests/runtime/*.star tests/selfhost/*.star examples/*.star; do
  # Files in tests/compile_errors fail to lex/parse: both must fail alike.
  s1=0; bin/starhost out/frontend.star "$f" > out/fe.expect 2> out/fe.experr || s1=1
  s2=0; node host/run.mjs out/frontend.wasm -- "$f" > out/fe.got 2> out/fe.goterr || s2=1
  if cmp -s out/fe.expect out/fe.got && [ $s1 = $s2 ]; then
    n=$((n+1))
  else
    echo "frontend self-test: MISMATCH on $f"; diff out/fe.expect out/fe.got | head -5; fail=1
  fi
done
echo "frontend self-test: $n files parsed identically by interpreted and compiled front ends"

# Bootstrap: the compiler compiles itself.
#   stage1 = interpreted compiler (starlark-go) compiling the compiler
#   stage2 = stage1 compiling the compiler;  stage3 = stage2 compiling it
# All three must be byte-identical (a fixpoint), and the self-compiled
# compiler must pass the same tests and emit the same bytes for every
# test program as the interpreted one.
bin/starhost compiler/main.star compiler/main.star out/stage1.wasm
node host/run.mjs out/stage1.wasm -- compiler/main.star out/stage2.wasm
node host/run.mjs out/stage2.wasm -- compiler/main.star out/stage3.wasm
if cmp -s out/stage1.wasm out/stage2.wasm && cmp -s out/stage2.wasm out/stage3.wasm; then
  echo "bootstrap: fixpoint reached, stage1 == stage2 == stage3 ($(wc -c < out/stage1.wasm | tr -d ' ') bytes)"
else
  echo "bootstrap: MISMATCH between stages"; ls -l out/stage*.wasm; fail=1
fi
COMPILER="node host/run.mjs out/stage2.wasm --" tests/compile.sh > out/selfhosted_compile.txt || { cat out/selfhosted_compile.txt; fail=1; }
COMPILER="node host/run.mjs out/stage2.wasm --" tests/compile_errors.sh > out/selfhosted_errors.txt || { cat out/selfhosted_errors.txt; fail=1; }
COMPILER="node host/run.mjs out/stage2.wasm --" tests/extensions.sh > out/selfhosted_extensions.txt || { cat out/selfhosted_extensions.txt; fail=1; }
n=0
for src in tests/compile/*.star; do
  bin/starhost compiler/main.star "$src" out/bs_interp.wasm 2> /dev/null || continue
  node host/run.mjs out/stage2.wasm -- "$src" out/bs_self.wasm
  if cmp -s out/bs_interp.wasm out/bs_self.wasm; then
    n=$((n+1))
  else
    echo "bootstrap: self-compiled compiler emits different bytes for $src"; fail=1
  fi
done
echo "bootstrap: self-compiled compiler passes all compile tests; identical output on $n programs"

# REPL (host/repl.mjs, on the self-compiled compiler): a scripted session
# against its expected transcript.
if node host/repl.mjs out/stage2.wasm < tests/repl/session.in > out/repl.out 2>&1 &&
   diff -u tests/repl/session.out out/repl.out; then
  echo "repl: ok ($(grep -c . tests/repl/session.in | tr -d ' ') input lines)"
else
  echo "repl: MISMATCH"; fail=1
fi

# Independent validation, if wasm-tools is installed.
if command -v wasm-tools > /dev/null; then
  for f in out/*.wasm; do
    wasm-tools validate --features all "$f" || { echo "wasm-tools: $f invalid"; fail=1; }
  done
  echo "wasm-tools validate: done"
fi

exit $fail
