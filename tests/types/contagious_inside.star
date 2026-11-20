# With contagious None (on here: the program has a reactive variable), a
# builtin that looks inside an argument gives None where it meets a None
# there (EXTENSIONS.md, "None further in"): sorted, min, max, join,
# startswith and endswith with a tuple, dict of pairs, % formatting (but
# by %s and %r, which show it). Its result is then T | None, and the call
# is checked on the argument without its Nones. Builtins that only copy,
# count or show the elements (list, len, str, zip...) don't.
def srt(d, k):
    return sorted([1, d.get(k)])
def srt_ok(xs):
    return sorted(xs)
def srt_tuples(d, k):
    return sorted([(1, d.get(k))])
def srt_key(xs, d):
    return sorted(xs, key = lambda x: d.get(x))
def mx(d, k):
    return max([1, d.get(k)])
def mx_one(xs):
    return max(xs)
def mx_two(a, b):
    return max(a, b)
def mx_args(d, k):
    return max(1, d.get(k))
def joined(d, k):
    return ",".join(["a", d.get(k)])
def joined_ok(ss):
    return ",".join(ss)
def pairs(d, k):
    return dict([("a", 1), d.get(k)])
def fmt(d, k):
    return "%d items" % (d.get(k),)
def fmt_s(d, k):
    return "%s and %r" % (d.get(k), 1)
def fmt_key(d, k):
    return "%(sum)d" % {"sum": d.get(k)}
def fmt_ok(n):
    return "%d" % (n,)
def starts(s, d, k):
    return s.startswith(("a", d.get(k)))
def length(d, k):
    return len([d.get(k)])
tick : 1
