#!/bin/sh
# Each tests/compile_errors/*.star starts with "# error: <text>"; compiling
# it must fail with a message containing <text>.
cd "$(dirname "$0")/.."
# The compiler to test; default: the interpreted one. test.sh also runs
# these with the self-compiled compiler (node host/run.mjs out/stage2.wasm --).
COMPILER=${COMPILER:-bin/starhost compiler/main.star}
mkdir -p out
fail=0
n=0
for src in tests/compile_errors/*.star; do
  want=$(head -1 "$src" | sed 's/^# error: //')
  if $COMPILER "$src" out/err.wasm 2> out/err.txt; then
    echo "compile_errors/$(basename "$src"): compiled, but expected error: $want"; fail=1
  elif ! grep -qF -- "$want" out/err.txt; then
    echo "compile_errors/$(basename "$src"): wrong error"; echo "    want: $want"; echo "    got:  $(grep -o 'Error.*' out/err.txt)"; fail=1
  else
    n=$((n+1))
  fi
done
[ $fail = 0 ] && echo "compile errors: ok ($n files)"
exit $fail
