# A loaded name may be reassigned and loaded again, with GlobalReassign
# (the option line at the end), as starlark-go's own tests of this do.
load("modules/util.star", "helper")

print(helper())
helper = 1
print(helper)
helper += 1
print(helper)
load("modules/util.star", "helper")
print(helper())

def f():
    return helper()

print(f())

# option:globalreassign (top-level names are rebound above)
