# error: reactive_err_assign.star:5:5: reactive variable x can only be used in a reactive definition (name : expr) or a top-level expression statement
# A plain variable computed from a reactive one would not be updated; use
# `w : x + 1` instead.
x : 1
w = x + 1
