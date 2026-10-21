# Spelling hints for compile-time errors, as starlark-go's internal/spell:
# nearest(x, candidates) is the candidate closest to x, ignoring case and
# underscores, with at most 50% typos; "" if none. (rt_nearest in
# lib/runtime.star is the same in Wasm, for run-time errors.)

def _fold(s):
    return s.replace("_", "").lower()

def _levenshtein(x, y, max):
    if len(x) > len(y):
        x, y = y, x
    # drop the common prefix (only up to the first difference, as Go)
    for i in range(len(x)):
        if x[i] != y[i]:
            x = x[i:]
            y = y[i:]
            break
    if x == "":
        return len(y)
    d = len(y) - len(x)
    if d > max:
        return d
    row = list(range(len(y) + 1))
    for i in range(1, len(x) + 1):
        row[0] = i
        best = i
        prev = i - 1
        for j in range(1, len(y) + 1):
            a = prev + (1 if x[i - 1] != y[j - 1] else 0)
            b = 1 + row[j - 1]
            c = 1 + row[j]
            k = min(a, b, c)
            prev = row[j]
            row[j] = k
            best = min(best, k)
        if best > max:
            return best
    return row[len(y)]

def nearest(x, candidates):
    x = _fold(x)
    best = ""
    bestd = (len(x) + 1) // 2
    for c in candidates:
        d = _levenshtein(x, _fold(c), bestd)
        if d < bestd:
            bestd = d
            best = c
    return best
