# Operator precedence (PRECEDENCE.md): operators that the precedence
# relation doesn't relate can't be mixed without parentheses, nor can
# operators that don't group be chained.

def mixes(a, b, c, x, y, z, n, flags, mask, k, j):
    return (
        flags & mask == 0,         # C reads flags & (mask == 0)
        1 << n - 1,
        flags | mask ^ 1,
        flags & n << 2,            # Go reads (flags & n) << 2
        k ?? 0 + 1 == 1,
        j ?? a or b,
        not a ?? b,
        a and x + y,
        not x + y,
        not x == y,
        not x in [1],
        x / y * z,
        x * y % z,
        x * y // z,
        x / y / z,
        x // y // z,
        x << 1 >> 2,
        x % y % z,
    )

def spacing(a, b, x, y, z):
    return (
        x+y * z,                   # spacing that says otherwise
        x * y+z,
        x - y-z,
        x + 1==y,
        not  a or b,
        a or b  and  a,
        - x+y,
    )
