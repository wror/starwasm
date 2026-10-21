#!/bin/sh
# Each tests/compile_errors/*.star starts with "# error: <text>"; compiling
# it must fail with a message containing <text>. When starlark-go
# (bin/starhost) rejects the file statically too, the compiler's message
# ("line:col: msg") must be exactly starlark-go's first error.
cd "$(dirname "$0")/.."
# The compiler to test; default: the interpreted one. test.sh also runs
# these with the self-compiled compiler (node host/run.mjs out/stage2.wasm --).
COMPILER=${COMPILER:-bin/starhost compiler/main.star}
mkdir -p out
fail=0
n=0
same=0
for src in tests/compile_errors/*.star; do
  want=$(head -1 "$src" | sed 's/^# error: //')
  if $COMPILER "$src" out/err.wasm 2> out/err.txt; then
    echo "compile_errors/$(basename "$src"): compiled, but expected error: $want"; fail=1
    continue
  elif ! grep -qF -- "$want" out/err.txt; then
    echo "compile_errors/$(basename "$src"): wrong error"; echo "    want: $want"; echo "    got:  $(grep -o 'Error.*' out/err.txt)"; fail=1
    continue
  fi
  n=$((n+1))
  # starlark-go's static error, if it has one (not a run-time traceback)
  sg=$(bin/starhost "$src" 2>&1 > /dev/null | head -1)
  case "$sg" in
    "$src":*)
      got=$(tail -1 out/err.txt | sed 's/^Error in fail: fail: //; s/^Error: //')
      if [ "$got" = "$sg" ]; then
        same=$((same+1))
      else
        echo "compile_errors/$(basename "$src"): differs from starlark-go"; echo "    starlark-go: $sg"; echo "    compiler:    $got"; fail=1
      fi ;;
  esac
done
[ $fail = 0 ] && echo "compile errors: ok ($n files; $same identical to starlark-go's)"
exit $fail
