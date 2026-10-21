load("util.star", "twice", tw = "twice")

THREE = 3
_secret = 42
counter = {"inits": 0}
counter["inits"] += 1

def square(x):
    return x * x

def apply_twice(f, x):
    return twice(f, x)

def via_alias(x):
    return tw(square, x)

def uses_private():
    return _secret

print("mathlib init", THREE)

def append_default(x, acc = []):
    acc.append(x)
    return acc
