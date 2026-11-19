# hello.star — a plain Starlark program, as starlark-go runs it:
#
#     node host/run.mjs examples/hello.star
#     node host/typecheck.mjs examples/hello.star   # writes examples/hello.starit

def greet(name, times = 1):
    return ", ".join(["hello " + name] * times)

def word_lengths(words):
    return {w: len(w) for w in words}

print(greet("world"))
print(greet("wasm", times = 2))
print(word_lengths(["star", "lark", "wasm"]))
print(sorted([5, 3, 9], reverse = True))
