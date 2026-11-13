# Reactive variables (an extension): `name : expr` at top level; changes come
# from standard input (reactive_basic.in), and everything depending on them
# is recomputed, transitively, in source order.
load("modules/reactive_mod.star", "area", "describe")

calls = []

def total(items, tax):
    # (no calls.append(...) here: updates run with the module frozen)
    return sum_(items) * (100 + tax) // 100

def sum_(xs):
    n = 0
    for x in xs:
        n += x
    return n

width : 3
height : 4
size : area(width, height)
big : size > 20               # changes less often than size
describe("size", size)
print("big:", big)            # re-run only when big changes

prices : [10, 20]
tax : 10
price_total : total(prices, tax)
describe("total", price_total)

label : "item"
tagged : {label: price_total}
print("tagged", tagged)

# a comprehension variable named like a reactive variable hides it
print("comp", [width for width in range(2)], width)

# a function parameter named like a reactive variable is fine
def scale(width):
    return width * 2

doubled : scale(width)
print("doubled", doubled)
calls.append("done")          # the first run may still mutate
print("calls so far", len(calls))

# option:nocontagiousnone (the errors of updates, here, are errors; with contagious
# None, the default with reactive variables, they give None: none_reactive_errors.star)
