# option:rollback
# With --rollback, an update in which an error was caught is undone, even
# where the definition allows the None it gives (`... ?? None`, which
# otherwise keeps the update): the errors are printed (.err), and every
# reactive variable has its value from before.

def show(label, v):
    print(label, repr(v), ["%s | %s | %s:%d" % e for e in provenance(v)])

def ratio(a, b):
    return a // b

def pick(xs, i):
    x, y = xs[i], xs[i + 1]
    return x + y

def checked(n):
    if n > 100:
        fail("too big:", n)
    return n

table = {"a": 1}
n : 4
key : "a"
items : [1, 2, 3]
half : ratio(100, n) ?? None
entry : table[key] + 1 ?? None
pair : pick(items, n - 4) ?? None
ok : checked(n) ?? None
both : half + entry ?? None
safe : half ?? -1
a row when n > 0:
    n: n
    r: 100 // n
show("half", half)
show("entry", entry)
show("pair", pair)
show("ok", ok)
show("both", both)
show("safe", safe)
print("row", row)
print("observer", items[n - 4])
print("n is", n, "half is", half)
