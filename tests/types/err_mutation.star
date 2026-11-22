# Reactive definitions may not mutate a collection that existed before
# they were computed, directly or through the functions they call
# (EXTENSIONS.md, "Reactive variables", "Mutation").
load("modules/journal.star", "collect", "note")

log = []
counts = {"n": 0}

def record(x):
    log.append(x)
    return x

def via(x):
    return record(x) + 1

def fill(out, n):
    for i in range(n):
        out.append(i)
    return out

def remember(x, seen = []):
    seen.append(x)
    return len(seen)

def make_counter():
    box = [0]
    def bump():
        box[0] += 1
        return box[0]
    return bump

bump = make_counter()

n : 1
pair : [n, 2]
a : via(n)                     # transitively, a global
b : fill(log, n)               # a global, passed to a function that mutates it
c : remember(n)                # a default value, kept between calls
d : bump()                     # a closure's captured variable
e : pair.append(n)             # another reactive variable's value
f : counts.update(n = n)       # directly
g : [h(n) for h in [record]]   # a mutating function, as a value
i : note(n)                    # a loaded module's global
j : collect(log, n)            # ... and a loaded function's parameter
