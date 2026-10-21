ss = ["hello World", "ǅungla", "straße", "ÉCOLE élève", "ﬃ", "Ǆ", "ǈ", "İstanbul", "σςΣ", "ﬁx", "abc123", "١٢٣", "  \t  ", "Ⅻ", "Kelvin K", "ǅ", "Ǳb", "á", "", "123", "ab cd", "Ab Cd", "AB", "aB"]
for s in ss:
    print(repr(s), s.upper(), s.lower(), s.title(), s.capitalize(), s.isalnum(), s.isalpha(), s.isdigit(), s.isspace(), s.islower(), s.isupper(), s.istitle())
print(repr("a\u0085b​c  \U0001F600\U000E0001﻿­"), repr(b"\xc2\x85\xe2\x80\x8b"), ["͸", "x؜y"])
print(repr("\U0010FFFF�"), repr("ok ✓ 中文 עברית"))
