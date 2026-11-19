# total.star — reactive variables: each line of standard input such as
# `qty : 3` gives a new value, and what depends on it is recomputed:
#
#     printf 'qty : 3\nprice : 2.5\n' | node host/run.mjs examples/total.star

price : 10.0
qty : 1
total : price * qty
print("total", total)
