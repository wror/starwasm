# Contagious None is on by default in a program with reactive variables
# (EXTENSIONS.md): a None doesn't stop the program, and says where it is
# from. A definition may be None only where it ends in `?? None`: an update
# in which any other one would be None is undone as a whole, and the
# variable's relation of errors, <name>Error, says why.

def double(n):
    return n * 2

def show(label, v):
    print(label, repr(v), ["%s %s %s:%d" % e for e in provenance(v)])

prices = {"apple": 3}
item : "apple"
qty : 2
price : prices.get(item)
sale : prices.get(item + "-sale") ?? None   # may be None
total : double(price) * qty
running : running + total
big : total > 10
order:
    item: item
    cost: total
    note: order.note + item
    sub:
        price: price
show("total", total)
show("running", running)
show("big", big)
show("order", order.cost)
show("order.sub", order.sub.price)
print(order, type(total) ?? "NoneType")
show("sale", sale)
print("priceError", [(e.trigger, e.field, provenance(e.value)[0][:2]) for e in priceError])
print("totalError", [(e.trigger, e.field, provenance(e.value)[0][:2]) for e in totalError])
