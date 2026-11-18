#!/bin/sh
# Tests template.star: the unit tests, then each testdata/errors/*.star,
# which must fail with the message on its first line.
# Usage: template/test.sh [starlark interpreter]   (default: bin/starhost)
set -u
cd "$(dirname "$0")"
star=${1:-../bin/starhost}
fail=0
"$star" template_test.star || fail=1
for f in testdata/errors/*.star; do
  want=$(sed -n '1s/^# error: //p' "$f")
  if got=$("$star" "$f" 2>&1); then
    echo "$f: expected an error"; fail=1
  else
    case $got in
      *"$want"*) ;;
      *) echo "$f: want error: $want"; echo "  got: $got"; fail=1 ;;
    esac
  fi
done
[ $fail = 0 ] && echo "template errors: ok"
exit $fail
