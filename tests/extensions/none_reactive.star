# Contagious None is on by default in a program with reactive variables
# (EXTENSIONS.md): a None doesn't stop an update, and says where it is from.

def double(n):
    return n * 2

def show(label, v):
    print(label, repr(v), ["%s %s %s:%d" % e for e in provenance(v)])

prices = {"apple": 3}
item : "apple"
qty : 2
price : prices.get(item)
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
print(order, total == None)
