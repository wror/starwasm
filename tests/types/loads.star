# Loaded modules are inferred too (with their own .start files): a loaded
# def is as polymorphic here as where it is defined.
load("modules/shapes.star", "UNIT", "area", "label", grow = "scaled")

square = struct(width = 2, height = 2, name = "square")
a = area(square)
b = area(UNIT)
big = grow(square, 3)
big_name = big.name
text = label(big)
units = [UNIT, grow(UNIT, 2)]
