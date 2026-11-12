#!/bin/sh
# The --journal option of host/run.mjs: a reactive program interrupted
# after part of its input, with a line cut short at the end of the journal
# (as by a crash mid-write), then restarted on the rest of the input, must
# print exactly what one run on all of it prints (the replay re-runs the
# journaled updates), and leave the journal equal to the whole input, the
# cut line dropped. A restart with no input then reproduces it again.
cd "$(dirname "$0")/.."
mkdir -p out
src=tests/extensions/reactive_basic.star
in=tests/extensions/reactive_basic.in
j=out/journal.log
rm -f $j
fail=0
head -15 $in | node host/run.mjs $RUNFLAGS --nocontagiousnone --journal=$j $src > /dev/null 2>&1 || fail=1
printf 'width = 99' >> $j
tail -n +16 $in | node host/run.mjs $RUNFLAGS --nocontagiousnone --journal=$j $src > out/journal.got 2> out/journal.goterr || fail=1
cmp -s out/journal.got tests/extensions/reactive_basic.out || fail=1
cmp -s out/journal.goterr tests/extensions/reactive_basic.err || fail=1
cmp -s $j $in || fail=1
node host/run.mjs $RUNFLAGS --nocontagiousnone --journal=$j $src < /dev/null 2> /dev/null | cmp -s - tests/extensions/reactive_basic.out || fail=1
cmp -s $j $in || fail=1
if [ $fail = 0 ]; then echo "journal: ok"; else echo "journal: MISMATCH (see out/journal.*)"; fi
exit $fail
