def check(x):
    if x > 2:
        fail("too big:", x)
    return x
for i in range(5):
    print(check(i))
