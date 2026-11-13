# option:rollback
# With --rollback, an update in which an error was caught is undone: the
# errors are printed (.err) and their Nones are seen by what runs in that
# update, but then every reactive variable has its value from before.

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
half : ratio(100, n)
entry : table[key] + 1
pair : pick(items, n - 4)
ok : checked(n)
both : half + entry
safe : half if half != None else -1
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
