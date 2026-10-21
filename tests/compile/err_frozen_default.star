# A loaded function's default values are frozen too.
load("modules/mathlib.star", "append_default")
print(append_default(1, []))
print(append_default(2))
