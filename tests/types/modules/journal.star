# A module whose functions mutate (for tests/types/mutation.star and
# err_mutation.star).

entries = []

def note(x):
    entries.append(x)
    return len(entries)

def collect(out, x):
    out.append(x)
    return out

def fresh(n):
    return collect([], n)
