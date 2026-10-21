def fact(n):
    r = 1
    for i in range(2, n + 1):
        r *= i
    return r
f100 = fact(100)
print(f100, len(str(f100)), f100 // fact(98), f100 % 1000000007, fact(30) // fact(25))
a, b = 0, 1
for _ in range(300):
    a, b = b, a + b
print(a, a % 997, a // b if b else 0, b - a)
# pseudo-random cross checks of division identities and bit ops
x = 12345678901234567890123456789012345678901234567890
y = 98765432109876543210987654321
vals = [x, -x, y, -y, x * y, -(x * y), 7, -7, 1 << 64, -(1 << 64), (1 << 64) - 1, 1 << 63, -(1 << 63), (1 << 63) - 1, 3, 0xffffffff, -0xffffffff, 1 << 96]
ok = True
for p in vals:
    for q in vals:
        d = p // q
        r = p % q
        if d * q + r != p:
            print("divmod fail", p, q)
            ok = False
        if q > 0 and not (0 <= r and r < q):
            print("range fail", p, q)
        if q < 0 and not (q < r and r <= 0):
            print("range fail", p, q)
print(ok)
for p in vals[:10]:
    print(p, p // 3, p % 3, p >> 5, p << 3, p & 0xff00ff00ff, p | 1, p ^ -1, ~p, -p, abs(p), p & -p, p & (p - 1), p ^ (p >> 1))
for p in vals[:6]:
    for q in vals[:6]:
        print(p // q, p % q, p & q, p | q, p ^ q, p < q, p == q, p - q)
print([float(v) for v in vals], [int(float(v)) for v in vals[:6]])
print(sorted(vals), max(vals), min(vals), {v: i for i, v in enumerate(vals)}[1 << 64], (1 << 64) in set(vals), len(set(vals + [v + 0 for v in vals])))
print("%d|%x|%X|%o|%s|%r" % (-x, x, -y, y, x, -y), str(-(1 << 200)), int(str(x * x)) == x * x, int("-" + str(y)) == -y, int("000123456789012345678901"))
print(1 << 511, (1 << 511) >> 510, -1 >> 600, -(1 << 300) >> 299, 1 >> 2147483647, x >> 1000, -x >> 1000)
print(x / y, y / x, (1 << 100) / (1 << 99), float(1 << 300), float(-(1 << 1000)), 1e300 < (1 << 1000), (1 << 1000) > 1e300, float((1 << 53) + 1), float((1 << 54) + 3), float((1 << 64) - 1))
print(int(1e30), int(-1e30), int(1180591620717411303424.0), 1e30 == 1000000000000000019884624838656, hash(x) == hash(x + 0), {1e20: 1}[100000000000000000000], {1 << 70: 2}[float(1 << 70)])
print(9223372036854775807 + 1 - 1, -9223372036854775808 + 0, (-9223372036854775808) * -1, -9223372036854775808 // -1, -9223372036854775808 % -1, abs(-9223372036854775808), -(-9223372036854775808), 3037000500 * -3037000500)
