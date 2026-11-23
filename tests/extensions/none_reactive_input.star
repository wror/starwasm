# With contagious None (the default in a reactive program), a value from
# standard input must fit the variable: no None inside it where its
# definition doesn't allow one, the type of the value it replaces (for a
# relation, of its members), and, for a member of an implicit relation, the
# fields the program reads from it (but those it reads only before ??).
# Else the update fails, as for a None, and xError gets a member (with
# the reason, in its None). And a definition that reads a variable not set
# yet isn't computed, on the first run or after: what it calls never gets
# that None.

def show_errors(label, errs):
    print(label, [(e.field, [p[1] for p in provenance(e.value) if p[0] == "error"]) for e in errs])

def double(v):
    print("double got", v)
    return v * 2

qs : [1, 2]
print("qs", qs)
show_errors("qs errors", qsError)

q : 3
print("q", q)
show_errors("q errors", qError)

an order:
    qty: req.qty
    note: req.note ?? "-"

first : order.qty
seen : double(first)
print("seen", seen)
print("orders", order)
show_errors("req errors", reqError)
