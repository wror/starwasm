# What fails whatever the values are, written out: a type error.
a = int("zz")
b = int("12", 2)
c = float("1e")
d = chr(1114112)
e = "{} {}".format(1)
f = "{:d}".format(1)
g = "{a.b}".format(a = 1)
h = "%d" % "x"
i = "%s %s" % ("x",)
j = "%(a)s" % {"b": 1}
k = "%y" % 1
l = "abc".startswith(1)
m = "abc".endswith(("a", 2))
n = hash([1])

tick : 1
