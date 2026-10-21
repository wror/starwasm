def find(xs, target):
    for i, x in enumerate(xs):
        if x == target:
            return i
    return -1

def classify(n):
    if n < 0:
        return "neg"
    elif n == 0:
        return "zero"
    elif n < 10:
        return "small"
    else:
        return "big"

def collatz(n):
    steps = 0
    while n != 1:
        if n % 2 == 0:
            n = n // 2
        else:
            n = 3 * n + 1
        steps += 1
    return steps

def is_even(n):
    if n == 0:
        return True
    return is_odd(n - 1)

def is_odd(n):
    if n == 0:
        return False
    return is_even(n - 1)

def kw(a, b = 2, *args, c = 3, d = None):
    return [a, b, args, c, d]

counter = {"n": 0}
log = []

def bump(by = 1):
    counter["n"] += by
    log.append(by)

def noreturn():
    pass

print(find([5, 6, 7], 7), find([], 1))
print([classify(n) for n in [-5, 0, 3, 42]])
print([collatz(n) for n in range(1, 12)])
print(is_even(10), is_odd(7), is_even(7))
print(kw(1), kw(1, 5), kw(1, 2, 3, 4), kw(1, c = 9), kw(d = "D", a = "A"))
bump()
bump(5)
bump(by = 10)
print(counter, log, noreturn())
for i in range(3):
    for j in range(3):
        if j == 1:
            continue
        if i == 2:
            break
        print("pair", i, j)
out = []
i = 0
while i < 20:
    i += 1
    if i % 3:
        continue
    out.append(i)
    if len(out) == 4:
        break
print(out, i)
for i in range(10, 0, -4):
    print("down", i)
for i in range(0):
    print("never")
def order(tag):
    log.append(tag)
    return tag
def two(x, y):
    return x + y
print(two(y = order("first"), x = order("second")), log[-2:])
x = 0
if x: print("no")
elif not x: print("yes")
