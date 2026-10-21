#!/bin/sh
# Differential compile tests: each tests/compile/*.star and tests/errors/*.star
# is run by starlark-go (bin/starhost) and compiled to Wasm and run by Node.
# Stdout must match, and both must succeed or both must fail. Programs named
# err_* and everything in tests/errors/ are expected to fail; when both fail,
# stderr (traceback with file:line:col of every frame, and the message) must
# be byte-identical too. Tests run in parallel (JOBS, default: CPU count);
# each is tests/compile_one.sh.
cd "$(dirname "$0")/.."
# The compiler to test; default: the interpreted one. test.sh also runs
# these with the self-compiled compiler (node host/run.mjs out/stage2.wasm --).
COMPILER=${COMPILER:-bin/starhost compiler/main.star}
export COMPILER
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
