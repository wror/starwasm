b = b"abc\x00\xff"
print(b, type(b), len(b), b[0], b[-1], b[1:3], b + b"!", b == b"abc\x00\xff", b < b"abd", b"" < b"a")
print(repr(b), repr(b[0]), repr(b[::-1]), repr(b[1:]), str(b"hi"), [b], {b"k": b"v"})
print(bytes("héllo"), bytes([104, 105]), bytes(b"x"), list(b"hi".elems()), repr(b"q\"\n\\\t\r"), dir(b""))
print(b"ab" * 2, 2 * b"x", b"x" * 0, 97 in b"cab", 120 in b"cab", b"" in b"x", b"ab" in b"cab", b"ba" in b"cab")
print({b"k": 1}[b"k"], b"\x41é", len(b"é"), b"é", repr(b"\xc3\xa9 \xe9"), repr(b"é\U0001F600\101\a"))
print("%s|%r|%s" % (b"h\xffi", b"hi", "s"), str(b"\xff"), str(b"a\xe2\x82"), str(b"\xed\xa0\x80"))
print(rb"\x41\n", b'single', b"""tri
ple""")
print(bytes([]) == b"", bool(b""), bool(b"x"), sorted([b"b", b"a", b"ab"]), max(b"a", b"b"), b"a" >= b"b", b"b" > b"a")
print(set([b"x", b"x", b"y"]), hasattr(b"", "elems"), list(getattr(b"xy", "elems")()), "{}".format(b"q"))
print(bytes(set([7])), bytes((1, 2)), b"abc"[5:], b"abc"[-2:], b"abcdef"[::2])
s = "naïve"
print(len(bytes(s)), str(bytes(s)) == s, bytes(s)[2:4])
