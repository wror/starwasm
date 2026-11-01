# Loaded by tests/extensions/reactive_*.star: ordinary functions that the
# main file calls with reactive values.
def area(w, h):
    return w * h

def describe(label, value):
    print("%s: %r" % (label, value))
