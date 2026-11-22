# Operator precedence (PRECEDENCE.md): what may be written without
# parentheses. Each line mixes operators that the precedence relation
# relates, so it reads one way only.

def checks(a, b, c, x, y, z, n, m, flags, mask, xs):
    return (
        x + y * z,                 # x + (y * z)
        x * y + z,
        x - y - z,                 # (x - y) - z
        x * y * z,
        x + y < z,                 # comparisons take arithmetic operands
        x in xs + [1],
        a or b and c,              # a or (b and c)
        a and b or c,              # (a and b) or c
        not a and b,               # (not a) and b
        a or not b,
        not not a,
        x < y and y < z,
        x == y or a,
        -x * y,                    # prefix - + ~ bind tightest
        -x < y and a,
        x + y if a else x - y,     # if/else delimit the branches
        x if a else y if b else z,
        flags | mask & 1,          # flags | (mask & 1)
        flags & mask | 1,
        flags | mask | 1,
        flags ^ mask ^ 1,
        (flags & mask) == 0,
        ~mask & flags,
        (n << 2) | 1,
        n ?? m ?? 0,               # ?? is below arithmetic
        n + 1 ?? 0,                # (n + 1) ?? 0
        n ?? m * 2,                # n ?? (m * 2)
        (n ?? 0) == 1,
        "%d items" % x + "!",
        (x * y) % z,
        x / (y * z),
    )
