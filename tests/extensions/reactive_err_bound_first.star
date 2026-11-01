# error: reactive_err_bound_first.star:4:1: cannot define reactive variable x: x is already bound
# A plain variable cannot later become reactive.
x = 1
x : 2
