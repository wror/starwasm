#!/bin/sh
# Tests of the type checker (typecheck/, EXTENSIONS.md "Static types").
# For each tests/types/<name>.star, checked with the annotations in
# <name>.start if there is one (modules it loads are in tests/types/modules/):
#   <name>.err exists: the check must fail, and print exactly <name>.err
#                      (the diagnostics, then the summary line)
#   else:              it must succeed, and the inferred types must be
#                      exactly <name>.starit
# Each is checked by the checker interpreted by starlark-go (bin/starhost)
# and by the checker compiled by starwasm (node host/typecheck.mjs); and
# for the ones that succeed, checking again with <name>.starit as the
# annotations must give the same <name>.starit (the two files are in one
# language).
#   tests/types.sh --update    rewrites the expected files instead
cd "$(dirname "$0")/.."
mkdir -p out/types_rt
update=0
[ "${1:-}" = "--update" ] && update=1
fail=0
n=0
nerr=0
starts=$(for f in tests/types/modules/*.start; do printf ' --start=%s' "$f"; done)

# interpreted <file.star> [--start=...]: prints what the driver would
# (types on stdout; else diagnostics and the summary line)
interpreted() {
  if bin/starhost --recursion typecheck/main.star --print "$@" > out/types.out 2> out/types.stderr; then
    cat out/types.out
  else
    cat out/types.out
    tail -1 out/types.stderr | sed -e 's/^Error in fail: fail: //' -e 's/^typecheck: //'
    return 1
  fi
}

for src in tests/types/*.star; do
  name=$(basename "$src" .star)
  own=""
  [ -f "tests/types/$name.start" ] && own="--start=tests/types/$name.start"
  s1=0; interpreted $own $starts "$src" > "out/types_$name.interp" || s1=1
  s2=0; node host/typecheck.mjs --print "$src" > "out/types_$name.wasm" 2>&1 || s2=$?
  if [ -f "tests/types/$name.err" ] || { [ $update = 1 ] && [ $s1 = 1 ]; }; then
    want="tests/types/$name.err"; ws=1
  else
    want="tests/types/$name.starit"; ws=0
  fi
  [ $update = 1 ] && cp "out/types_$name.interp" "$want"
  if [ $s1 != $ws ] || ! cmp -s "$want" "out/types_$name.interp"; then
    echo "types/$name: MISMATCH (interpreted checker; expected vs got)"
    diff "$want" "out/types_$name.interp" | head -20 | sed 's/^/    /'
    fail=1; continue
  fi
  if [ $s2 != $ws ] || ! cmp -s "$want" "out/types_$name.wasm"; then
    echo "types/$name: MISMATCH (compiled checker, status $s2; expected vs got)"
    diff "$want" "out/types_$name.wasm" | head -20 | sed 's/^/    /'
    fail=1; continue
  fi
  if [ $ws = 1 ]; then
    nerr=$((nerr+1)); continue
  fi
  # round trip: the inferred types, as annotations
  rm -rf out/types_rt; mkdir -p out/types_rt
  cp -r tests/types/modules out/types_rt/modules
  cp "$src" out/types_rt/
  cp "$want" "out/types_rt/$name.start"
  rstarts=$(for f in out/types_rt/modules/*.start; do printf ' --start=%s' "$f"; done)
  if ! interpreted "--start=out/types_rt/$name.start" $rstarts "out/types_rt/$name.star" > out/types_rt.out || ! cmp -s "$want" out/types_rt.out; then
    echo "types/$name: ROUND TRIP MISMATCH ($name.starit as $name.start; expected vs got)"
    diff "$want" out/types_rt.out | head -20 | sed 's/^/    /'
    fail=1; continue
  fi
  n=$((n+1))
done
echo "types: $n programs ok (interpreted, compiled, and with their inferred types as annotations), $nerr with the expected errors"
exit $fail
