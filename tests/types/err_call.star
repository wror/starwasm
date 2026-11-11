# Calls that don't fit the function.

def greet(name, punctuation = "!"):
    return "hello " + name + punctuation

def point(x, y, *, label):
    return struct(x = x, y = y, label = label)

greet()
greet("a", "b", "c")
greet("a", punktuation = "?")
greet("a", name = "b")
point(1, 2)
point(1, 2, 3, label = "p")
"text"()
n = 3
n(1)
"abc".uper()
[1].push(2)
{}.get()
print("x", septum = "")
