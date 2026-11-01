# error: 4:4: cannot reassign global x declared at tests/compile_errors/reassign_tuple.star:2:1
x = 1
def f(): return 1
y, x = 2, 3
