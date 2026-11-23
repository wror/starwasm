# With contagious None (on here: the program has a reactive variable), these
# can fail on values of the right types too, and so give T | None: a format
# not written out (or whose fields aren't all filled by name), partition by
# a separator that may be empty, popitem, a slice by a step that may be 0,
# bytes of anything but a string, read_file, int by a base not written out,
# a % format whose values' types aren't known, startswith with a prefix
# whose type isn't known. What is written out is checked instead: a format
# written out, int("12"), a % format with values of known types.

def formatted(fmt, n):
    return fmt.format(n)

def filled(n):
    return "{} of {}".format(n, n + 1)      # every field has an argument

def named(n):
    return "{n}".format(n = n)

def parted(s, sep):
    return s.partition(sep)[0]

def parted_ok(s):
    return s.partition(",")[0]

def popped(d):
    return d.popitem()

def record():
    d = {"a": 1}
    d.popitem()
    return d["a"]                   # (no longer a record's entry)

def stepped(xs, k):
    return xs[::k]

def reversed_ok(xs):
    return xs[::-1]

def made(xs):
    return bytes(xs)

def read(path):
    return read_file(path)

def based(s, b):
    return int(s, b)

def percent(n):
    return "%d items" % (n,)        # n must be a number

def percent_s(x):
    return "%s and %r" % (x, x)

def starts(s, p):
    return s.startswith(p)

tick : 1
