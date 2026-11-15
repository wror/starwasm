# After the first run, a reactive program (contagious None: its default)
# turns every error into a None that carries the error: an update never
# fails. The errors are printed on stderr as they happen (.err).

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

def size(xs):
    k = 0
    for _ in xs:
        k += 1
    return k

table = {"a": 1}
lists = {"a": [1, 2]}
n : 4
key : "a"
items : [1, 2, 3]
half : ratio(100, n)
entry : table[key] + 1
pair : pick(items, n - 4)
ok : checked(n)
both : half + entry
count : size(lists.get(key))
safe : half ?? -1
a row when n > 0:
    n: n
    r: 100 // n
show("half", half)
show("entry", entry)
show("pair", pair)
show("ok", ok)
show("both", both)
show("count", count)
show("safe", safe)
print("row", row)
print("observer", items[n - 4])
