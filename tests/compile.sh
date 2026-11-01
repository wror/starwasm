#!/bin/sh
# Differential compile tests: each tests/compile/*.star and tests/errors/*.star
# is run by starlark-go (bin/starhost) and compiled to Wasm and run by Node.
# Stdout must match, and both must succeed or both must fail. Programs named
# err_* and everything in tests/errors/ are expected to fail; when both fail,
# stderr (traceback with file:line:col of every frame, and the message) must
# be byte-identical too. Tests run in parallel (JOBS, default: CPU count);
# each is tests/compile_one.sh. A program with a line
# "# option:globalreassign" or "# option:recursion" runs with that option
# on, in both.
cd "$(dirname "$0")/.."
# Programs are compiled and run by node host/run.mjs (which caches their
# Wasm in __wasmcache__/), with the options RUNFLAGS, e.g.
# RUNFLAGS=--compiler=out/stage2.wasm; default: none (the compiler built
# from compiler/main.star).
export RUNFLAGS
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
mkdir -p out
files=$(ls tests/compile/*.star tests/errors/*.star)
rm -f out/c_*.result
printf '%s\n' $files | xargs -P "$JOBS" -n 1 sh tests/compile_one.sh
fail=0
for src in $files; do
  name=$(basename "$src" .star)
  case "$src" in tests/errors/*) name="errors_$name" ;; esac
  res="out/c_$name.result"
  if [ ! -s "$res" ]; then echo "compile/$name: NO RESULT"; fail=1; continue; fi
  [ "$(head -1 "$res")" = ok ] || fail=1
  tail -n +2 "$res"
done
exit $fail
