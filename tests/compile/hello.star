def fact(n):
    if n < 2:
        return 1
    return n * fact(n - 1)

def greet(name, greeting = "hello", *rest):
    print(greeting + ", " + name, len(rest))

print("start")
for i in range(5):
    print(i, fact(i))
greet("world")
greet("bob", greeting = "hi")
greet("x", "y", 1, 2, 3)
total = 0
xs = [1, 2, 3]
for x in xs:
    total += x
print(total, xs[1:], xs[::-1])
d = {"a": 1}
d["b"] = 2
for k, v in d.items():
    print(k, v)
print([x * x for x in range(6) if x % 2 == 0])
print({k: v for k, v in [("p", 1), ("q", 2)]})
a, b = 1, 2
a, b = b, a
print(a, b, a if a > b else b, a and b, 0 or "z", not a)
n = 0
while True:
    n += 1
    if n == 3:
        continue
    if n > 5:
        break
    print("n", n)
print(fact(20))
