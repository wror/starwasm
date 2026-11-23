# With contagious None (on here: the program has a reactive variable), Any is
# anything, None included: what nothing is known about may be None. Such an
# Any is shown as `Any | None`, and treated as a T | None: operations on it
# give one, a def that tests or loops over it may fail, a variable assigned
# one is optional, and it can't be used where a type that isn't optional is
# wanted. Only ?? gives an Any that isn't None (shown as Any); and an Any in
# a .start file isn't None (`Any | None` is).
cfg = struct(width = 3, name = "w")

def field(name):
    return getattr(cfg, name + "")       # a field not known here

def width():
    w = 0
    w = field("width")                   # so w is optional
    return w

def sure(name):
    return field(name) ?? 0              # Any, not None

def counted(name):
    n = 0
    n = sure(name)                       # (not optional)
    return n

def loop(name):
    for x in field(name):                # may be None, or not iterable
        pass
    return 1

def told(name):
    return field(name) or "none"         # (a or b of different types)

stored = [1]
stored.append(field("width"))            # a list[int | None]

tick : 1
