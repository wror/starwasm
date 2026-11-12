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

# Tools (unit tests, the interpreted compiler, generators) are recursive:
# bin/starhost --recursion. Test programs get only the options they name.
for t in tests/*_test.star; do
  bin/starhost --recursion "$t"
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

bin/starhost --recursion examples/demo.star out/demo.wasm
run demo answer
run demo fact 20
run demo main

# Runtime: the same program as plain Starlark (run by starlark-go) and as
# Wasm built on the generated runtime (run by Node) must print the same.
bin/starhost tests/runtime/expect.star > out/runtime_expect.txt
bin/starhost --recursion tests/runtime/build.star out/runtime_test.wasm
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
# .star programs are run by node host/run.mjs, which compiles them when
# needed (see host/wasmcache.mjs), with the compiler built from
# compiler/main.star (by bin/starhost, whenever compiler/ or lib/ changes).
# (The interpreted compiler is checked against the self-compiled one below.)
tests/compile.sh || fail=1
tests/compile_errors.sh || fail=1
# Extensions starlark-go lacks: compared against expected output files,
# with GlobalReassign off (the default) and on.
tests/extensions.sh || fail=1
tests/journal.sh || fail=1
# The type checker (typecheck/): expected inferred types and diagnostics,
# with the checker interpreted and self-compiled.
tests/types.sh || fail=1
RUNFLAGS=--globalreassign tests/extensions.sh > out/extensions_reassign.txt || { cat out/extensions_reassign.txt; fail=1; }
echo "extensions with --globalreassign: $(grep -c ': ok' out/extensions_reassign.txt) ok"

# starlark-go's own test files (tests/upstream/README.md): fails on any
# failure not in tests/upstream/known_failures.txt.
node tests/upstream/run.mjs > out/upstream.txt || { cat out/upstream.txt; fail=1; }
grep '^upstream: [0-9]' out/upstream.txt

# Self-hosting preview: compile the compiler's own front end (lexer +
# parser), run it on every source file in the project, and compare its
# token/AST dump with the interpreted front end's.
bin/starhost --recursion tests/selfhost/gen_frontend_test.star out/frontend.star
n=0
# (The bootstrap below checks the whole compiler; this covers the sources.)
for f in lib/*.star compiler/*.star compiler/ext/*.star typecheck/*.star tests/*.star tests/runtime/*.star tests/selfhost/*.star examples/*.star; do
  # Files in tests/compile_errors fail to lex/parse: both must fail alike.
  s1=0; bin/starhost --recursion out/frontend.star "$f" > out/fe.expect 2> out/fe.experr || s1=1
  s2=0; node host/run.mjs --recursion out/frontend.star -- "$f" > out/fe.got 2> out/fe.goterr || s2=1
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
# compiler must emit the same bytes (or the same compile error) for every
# test program as the interpreted one. (So the tests above, run with the
# compiler host/run.mjs builds, i.e. stage1, hold for both compilers.)
# (the compiler is recursive: it is compiled with --recursion)
bin/starhost --recursion compiler/main.star --recursion compiler/main.star out/stage1.wasm
node host/run.mjs out/stage1.wasm -- --recursion compiler/main.star out/stage2.wasm
node host/run.mjs out/stage2.wasm -- --recursion compiler/main.star out/stage3.wasm
if cmp -s out/stage1.wasm out/stage2.wasm && cmp -s out/stage2.wasm out/stage3.wasm; then
  echo "bootstrap: fixpoint reached, stage1 == stage2 == stage3 ($(wc -c < out/stage1.wasm | tr -d ' ') bytes)"
else
  echo "bootstrap: MISMATCH between stages"; ls -l out/stage*.wasm; fail=1
fi
n=0
nerr=0
for src in tests/compile/*.star tests/compile_errors/*.star tests/extensions/*.star; do
  gr="$(grep -q '^# option:globalreassign' "$src" && printf ' --globalreassign' || true)$(grep -q '^# option:recursion' "$src" && printf ' --recursion' || true)$(grep -q '^# option:contagiousnone' "$src" && printf ' --contagiousnone' || true)$(grep -q '^# option:nocontagiousnone' "$src" && printf ' --nocontagiousnone' || true)"
  s1=0; bin/starhost --recursion compiler/main.star $gr "$src" out/bs_interp.wasm 2> out/bs_interp.err || s1=1
  s2=0; node host/run.mjs out/stage2.wasm -- $gr "$src" out/bs_self.wasm 2> out/bs_self.err || s2=1
  if [ $s1 = 0 ] && [ $s2 = 0 ] && cmp -s out/bs_interp.wasm out/bs_self.wasm; then
    n=$((n+1))
  elif [ $s1 = 1 ] && [ $s2 = 1 ] && [ "$(tail -1 out/bs_interp.err)" = "$(tail -1 out/bs_self.err)" ]; then
    nerr=$((nerr+1))
  else
    echo "bootstrap: self-compiled compiler differs from the interpreted one on $src"; fail=1
  fi
done
echo "bootstrap: self-compiled compiler: identical output on $n programs, identical compile errors on $nerr"

# REPL (host/repl.mjs, on the self-compiled compiler): a scripted session
# against its expected transcript.
if node host/repl.mjs out/stage2.wasm < tests/repl/session.in > out/repl.out 2>&1 &&
   diff -u tests/repl/session.out out/repl.out; then
  echo "repl: ok ($(grep -c . tests/repl/session.in | tr -d ' ') input lines)"
else
  echo "repl: MISMATCH"; fail=1
fi
# The same session as the browser REPL (web/) runs it: files in memory, and
# no live programs (each update of reactive variables replays the session).
if node tests/repl/browser_mode.mjs out/stage2.wasm < tests/repl/session.in > out/repl_browser.out 2>&1 &&
   diff -u tests/repl/session.out out/repl_browser.out; then
  echo "repl (browser mode): ok"
else
  echo "repl (browser mode): MISMATCH"; fail=1
fi
# The type checker in the REPL (:type, :types, :check), both ways.
if node host/repl.mjs out/stage2.wasm < tests/repl/types.in > out/repl_types.out 2>&1 &&
   diff -u tests/repl/types.out out/repl_types.out &&
   node tests/repl/browser_mode.mjs out/stage2.wasm < tests/repl/types.in > out/repl_types_browser.out 2>&1 &&
   diff -u tests/repl/types.out out/repl_types_browser.out; then
  echo "repl types: ok"
else
  echo "repl types: MISMATCH"; fail=1
fi
# Tab completion (the browser REPL's; Session.complete).
if node tests/repl/complete.mjs out/stage2.wasm > out/repl_complete.out 2>&1 &&
   diff -u tests/repl/complete.out out/repl_complete.out; then
  echo "repl completion: ok"
else
  echo "repl completion: MISMATCH"; fail=1
fi

# Independent validation, if wasm-tools is installed.
if command -v wasm-tools > /dev/null; then
  for f in out/*.wasm $(find . -path '*/__wasmcache__/*.wasm'); do
    wasm-tools validate --features all "$f" || { echo "wasm-tools: $f invalid"; fail=1; }
  done
  echo "wasm-tools validate: done"
fi

exit $fail
