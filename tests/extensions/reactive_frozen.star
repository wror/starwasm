# After the first run, the main module is frozen (as a loaded module is
# once it has run): what updates run can't mutate non-reactive variables,
# directly, through a function, a default value or a closure. A failed
# update is rolled back; the program carries on.
log = []
counts = {"n": 0}

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

# all of these mutate freely during the first run
log.append("start")
counts["n"] += 1
print(remember(1), bump())

x : 1
y : x * 10
print("y is", y, "log", log)
z : [x, y]  # a reactive value is not frozen by the module's freezing
log_len : len(log) + x
print(log.append(x) if x == 2 else None)
print(counts.update(n = x) if x == 3 else None)
print(remember(x) if x == 4 else None)
print(bump() if x == 5 else None)
print("z is", z, "fresh", [x] + [y])
