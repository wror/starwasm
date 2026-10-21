r = range(3000000)
t = 0
for x in r:
    t += x
print(t, len(r), len(range(1 << 40)), len(range(-(1 << 62), 1 << 62, 3)), r[-1], range(1 << 62)[-1], range(5)[-5], range(1 << 62)[12345])
n = 0
for x in range(10, -(1 << 62), -(1 << 59)):
    n += 1
print(n, [x for x in range(3)], [x * y for x in range(2) for y in range(3, 0, -1)])
def first(it):
    for x in it:
        return x
print(first(range(5, 1 << 62)), first(range(9223372036854775807 - 1, 9223372036854775807)))
