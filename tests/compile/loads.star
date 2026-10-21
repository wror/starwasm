# load(): aliases, a module loaded twice but initialized once, init order,
# loaded functions as values.
load("modules/mathlib.star", "square", "apply_twice", "THREE", "counter", "via_alias", "uses_private", sq = "square")
load("modules/util.star", "helper", h = "helper")

print(square(4), sq(5), apply_twice(square, 3), via_alias(2), THREE, helper(), h())
print(counter, uses_private())
f = square
fs = [square, sq, h]
print(f(9), [sq(i) for i in range(4)], fs[0] == fs[1], fs[2]())
copy = {"inits": counter["inits"]}
copy["inits"] += 10  # a fresh dict is mutable
print(copy, counter)
