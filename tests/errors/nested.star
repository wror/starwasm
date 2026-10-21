def outer():
    def middle(x):
        return [inner(i) for i in range(x)]
    def inner(i):
        return {"a": 1}[str(i)]
    return middle(2)
h = lambda: outer()
print(h())
