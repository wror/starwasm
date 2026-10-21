#!/bin/sh
# One differential compile test (see tests/compile.sh): writes
# out/c_<name>.result = first line "ok" or "FAIL", then the report text.
src=$1
name=$(basename "$src" .star)
case "$src" in tests/errors/*) name="errors_$name" ;; esac
res="out/c_$name.result"
{
  exp=0; bin/starhost "$src" > "out/c_$name.expect" 2> "out/c_$name.experr" || exp=$?
  if ! $COMPILER "$src" "out/c_$name.wasm" 2> "out/c_$name.cerr"; then
    echo FAIL; echo "compile/$name: COMPILE FAILED"; sed 's/^/    /' "out/c_$name.cerr"; exit 0
  fi
  got=0; node host/run.mjs "out/c_$name.wasm" > "out/c_$name.got" 2> "out/c_$name.goterr" || got=$?
  if ! cmp -s "out/c_$name.expect" "out/c_$name.got"; then
    echo FAIL; echo "compile/$name: OUTPUT MISMATCH (starlark-go vs wasm)"
    diff "out/c_$name.expect" "out/c_$name.got" | head -20 | sed 's/^/    /'
    [ -s "out/c_$name.goterr" ] && sed 's/^/    stderr: /' "out/c_$name.goterr"
  elif [ "$exp" = 0 ] && [ "$got" != 0 ]; then
    echo FAIL; echo "compile/$name: wasm failed but starlark-go succeeded"; sed 's/^/    /' "out/c_$name.goterr"
  elif [ "$exp" != 0 ] && [ "$got" = 0 ]; then
    echo FAIL; echo "compile/$name: starlark-go failed but wasm succeeded"
  elif [ "$exp" != 0 ] && ! cmp -s "out/c_$name.experr" "out/c_$name.goterr"; then
    echo FAIL; echo "compile/$name: TRACEBACK MISMATCH (starlark-go vs wasm)"
    diff "out/c_$name.experr" "out/c_$name.goterr" | sed 's/^/    /'
  else
    case "$name" in
      err_*|errors_*)
        if [ "$exp" = 0 ]; then echo FAIL; echo "compile/$name: expected a failure"
        else echo ok; echo "compile/$name: ok (same traceback: $(tail -1 "out/c_$name.goterr"))"; fi ;;
      *) echo ok; echo "compile/$name: ok ($(wc -l < "out/c_$name.got" | tr -d ' ') lines)" ;;
    esac
  fi
} > "$res"
