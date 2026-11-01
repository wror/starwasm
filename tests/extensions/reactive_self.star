# A reactive variable may refer to itself: it reads its value from when it
# was last computed, or the first time, the identity element of the context
# (0 for +, 1 for *, "" for strings, [] for lists, ...).
b : "foo"
a : struct(x = (a.x + 1) + (a.x * 10), y = str(a.y + b))
print(a)

n : 5
total : total + n                 # a running sum
history : history + [n]           # every value n had
latest : [v for v in latest if v != n][-2:] + [n]
shout : shout.upper() + str(n)    # methods on the identity give the identity
print("total", total, "history", history, "latest", latest, "shout", shout)
