# error: reactive variable x would depend on itself: x -> y -> x
# option:globalreassign
a : 1
x : a
y : x + 1
x : y * 2
