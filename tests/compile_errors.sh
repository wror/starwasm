#!/bin/sh
# Each tests/compile_errors/*.star starts with "# error: <text>"; compiling
# it must fail with a message containing <text>. When starlark-go
# (bin/starhost) rejects the file statically too, the compiler's message
# ("line:col: msg") must be exactly starlark-go's first error. A file with
# a line "# option:globalreassign" or "# option:recursion" is compiled (and
# run by starlark-go) with that option on.
cd "$(dirname "$0")/.."
# Compiled by node host/run.mjs --compile, with the options RUNFLAGS (as
# in tests/compile.sh); it prints a compile error as "file:line:col: msg".
mkdir -p out
fail=0
n=0
same=0
for src in tests/compile_errors/*.star; do
  want=$(head -1 "$src" | sed 's/^# error: //')
  gr="$(grep -q '^# option:globalreassign' "$src" && printf ' --globalreassign')$(grep -q '^# option:recursion' "$src" && printf ' --recursion')"
  if node host/run.mjs --compile $RUNFLAGS $gr "$src" 2> out/err.txt; then
    echo "compile_errors/$(basename "$src"): compiled, but expected error: $want"; fail=1
    continue
  elif ! grep -qF -- "$want" out/err.txt; then
    echo "compile_errors/$(basename "$src"): wrong error"; echo "    want: $want"; echo "    got:  $(cat out/err.txt)"; fail=1
    continue
  fi
  n=$((n+1))
  # starlark-go's static error, if it has one (not a run-time traceback)
  sg=$(bin/starhost $gr "$src" 2>&1 > /dev/null | head -1)
  case "$sg" in
    "$src":*)
      got=$(tail -1 out/err.txt)
      if [ "$got" = "$sg" ]; then
        same=$((same+1))
      else
        echo "compile_errors/$(basename "$src"): differs from starlark-go"; echo "    starlark-go: $sg"; echo "    compiler:    $got"; fail=1
      fi ;;
  esac
done
[ $fail = 0 ] && echo "compile errors: ok ($n files; $same identical to starlark-go's)"
exit $fail
