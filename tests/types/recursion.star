# option:recursion
# Recursive and mutually recursive defs, nested defs and closures, defs
# used before their definition.

def fact(n):
    if n <= 1:
        return 1
    return n * fact(n - 1)

def is_even(n):
    return True if n == 0 else is_odd(n - 1)

def is_odd(n):
    return False if n == 0 else is_even(n - 1)

def depth(tree):
    if not tree.children:
        return 1
    return 1 + max([depth(c) for c in tree.children])

def flatten(xs, out):
    for x in xs:
        out.append(x)
    return out

def uses_later():
    return later(2)

def later(n):
    return [n] * n

def counter(start):
    state = [start]
    def bump(by):
        state[0] += by
        return state[0]
    return bump

def pairs(xs):
    def pair(x):
        return (x, x)
    return [pair(x) for x in xs]

def outer(k):
    def middle(v):
        def inner(w):
            return [k, v, w]
        return inner
    return middle(k)(k)

def ping(x, n):
    return x if n == 0 else pong(x, n - 1)

def pong(x, n):
    return ping(x, n)

def tree_sum(t):
    def go(n):
        s = n.value
        for c in n.kids:
            s += go(c)
        return s
    return go(t)

def choose(flag):
    if flag:
        def pick(a, b):
            return a
    else:
        def pick(a, b):
            return b
    return pick(1, 2)

# a tree's nodes hold nodes: there are no recursive types, so the type
# is Any where it would contain itself
leaf = struct(value = 1, kids = [])
tree = struct(value = 2, kids = [leaf, leaf])
sum_ = tree_sum(tree)
levels = depth(struct(children = [struct(children = [])]))

# defs in a cycle are generalized together
ping_int = ping(1, 2)
ping_str = ping("s", 2)
six = fact(3)
even = is_even(10)
c = counter(10)
eleven = c(1)
twins = pairs(["a", "b"])
numbers = pairs([1])
triple = outer("x")
later_list = uses_later()
