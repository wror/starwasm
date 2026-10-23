#!/bin/sh
# Tests of starwasm's extensions (EXTENSIONS.md). starlark-go lacks them, so
# there is nothing to compare against: each tests/extensions/<name>.star
# must compile, run successfully and print exactly <name>.out next to it.
# COMPILER as in tests/compile.sh.
cd "$(dirname "$0")/.."
COMPILER=${COMPILER:-bin/starhost compiler/main.star}
mkdir -p out
fail=0
for src in tests/extensions/*.star; do
  name=$(basename "$src" .star)
  wasm="out/ext_$name.wasm"
  if ! $COMPILER "$src" "$wasm" 2> "out/ext_$name.cerr"; then
    echo "extensions/$name: COMPILE FAILED"; sed 's/^/    /' "out/ext_$name.cerr"; fail=1; continue
  fi
  if ! node host/run.mjs "$wasm" > "out/ext_$name.got" 2> "out/ext_$name.goterr"; then
    echo "extensions/$name: FAILED"; sed 's/^/    /' "out/ext_$name.goterr"; fail=1; continue
  fi
  if cmp -s "tests/extensions/$name.out" "out/ext_$name.got"; then
    echo "extensions/$name: ok ($(wc -l < "out/ext_$name.got" | tr -d ' ') lines)"
  else
    echo "extensions/$name: OUTPUT MISMATCH (expected vs got)"
    diff "tests/extensions/$name.out" "out/ext_$name.got" | head -20 | sed 's/^/    /'
    fail=1
  fi
done
exit $fail
