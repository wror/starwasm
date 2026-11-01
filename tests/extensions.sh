#!/bin/sh
# Tests of starwasm's extensions (EXTENSIONS.md). starlark-go lacks them, so
# there is nothing to compare against: each tests/extensions/<name>.star
# must compile, run successfully and print exactly <name>.out next to it.
# Optional files next to it:
#   <name>.in    standard input for the program (else it gets none)
#   <name>.err   its exact standard error (else stderr must be empty)
# A test whose first line is "# error: <text>" must instead fail to compile
# with a message containing <text>.
# A test with a line "# option:globalreassign" or "# option:recursion" is
# compiled with that option. Each is compiled (if needed) and run by
# node host/run.mjs, with the options RUNFLAGS as in tests/compile.sh.
cd "$(dirname "$0")/.."
mkdir -p out
fail=0
nerr=0
for src in tests/extensions/*.star; do
  name=$(basename "$src" .star)
  want=$(head -1 "$src" | sed -n 's/^# error: //p')
  opts="$(grep -q '^# option:globalreassign' "$src" && printf ' --globalreassign')$(grep -q '^# option:recursion' "$src" && printf ' --recursion')"
  if [ -n "$want" ]; then
    if node host/run.mjs --compile $RUNFLAGS $opts "$src" 2> "out/ext_$name.cerr"; then
      echo "extensions/$name: compiled, but expected error: $want"; fail=1
    elif ! grep -qF -- "$want" "out/ext_$name.cerr"; then
      echo "extensions/$name: wrong error"; echo "    want: $want"; echo "    got:  $(tail -1 "out/ext_$name.cerr")"; fail=1
    else
      nerr=$((nerr+1))
    fi
    continue
  fi
  if ! node host/run.mjs --compile $RUNFLAGS $opts "$src" 2> "out/ext_$name.cerr"; then
    echo "extensions/$name: COMPILE FAILED"; sed 's/^/    /' "out/ext_$name.cerr"; fail=1; continue
  fi
  input=/dev/null
  [ -f "tests/extensions/$name.in" ] && input="tests/extensions/$name.in"
  if ! node host/run.mjs $RUNFLAGS $opts "$src" < "$input" > "out/ext_$name.got" 2> "out/ext_$name.goterr"; then
    echo "extensions/$name: FAILED"; sed 's/^/    /' "out/ext_$name.goterr"; fail=1; continue
  fi
  experr=/dev/null
  [ -f "tests/extensions/$name.err" ] && experr="tests/extensions/$name.err"
  if ! cmp -s "tests/extensions/$name.out" "out/ext_$name.got"; then
    echo "extensions/$name: OUTPUT MISMATCH (expected vs got)"
    diff "tests/extensions/$name.out" "out/ext_$name.got" | head -20 | sed 's/^/    /'
    fail=1
  elif ! cmp -s "$experr" "out/ext_$name.goterr"; then
    echo "extensions/$name: STDERR MISMATCH (expected vs got)"
    diff "$experr" "out/ext_$name.goterr" | head -20 | sed 's/^/    /'
    fail=1
  else
    echo "extensions/$name: ok ($(wc -l < "out/ext_$name.got" | tr -d ' ') lines)"
  fi
done
[ $nerr -gt 0 ] && echo "extensions: $nerr compile-error tests ok"
exit $fail
