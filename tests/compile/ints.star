# Integer semantics, including the small/boxed boundary.
big = 1 << 40
print(big, big + 1, big - big, (big * 3) // 7, -big % 1000)
print(1073741823 + 1, -1073741824 - 1, 1073741824 - 1 == 1073741823)
for a in [7, -7]:
    for b in [2, -2, 3]:
        print(a, b, a // b, a % b)
print(0xff & 0x0f | 0x100 ^ 1, ~5, -(-3), +4)
print(1 << 62, (1 << 62) >> 61, -1 >> 10)
print(int("123"), int("-45"), int(True), int(False), abs(-9), abs(9))
print(9223372036854775807, -9223372036854775807 - 1)
print(3 < 5, 5 <= 5, 6 > 7, 7 >= 7, 3 == 3, 3 != 3)
x = 10
x -= 3
x *= 4
x //= 3
x %= 5
x <<= 4
x >>= 1
x |= 1
x &= 0xff
x ^= 2
print(x)
def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)
print([fib(i) for i in range(15)])
print(fib(25))
