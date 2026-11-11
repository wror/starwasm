# Type mismatches: the message says what was expected where, and notes
# point at where the conflicting types come from.

def greet(name):
    return "hello " + name

def double(n):
    return n * 2

def parse(text):
    if text == "":
        return 0
    return "zero"

greeting = greet(42)
count = 0
count = "none"
scores = [1, 2, "three"]
table = {"a": 1, "b": "two"}
total = 1 + "1"
size = len(5)
limit = double("x") + 1
flags = [True] + ["yes"]
item = scores["first"]
for ch in "abc":
    print(ch)
first, second = (1, 2, 3)
