s = "hello, world"
print(s[0], s[-1], s[1:5], s[:5], s[7:], s[::2], s[::-1], s[100:], s[-3:])
print(len(s), "lo" in s, "xyz" in s, "" in s, "x" not in s)
print(s.startswith("hell"), s.startswith("world"), s.endswith("world"), s.endswith("x"))
print("-".join(["a", "b", "c"]), "".join([]), ", ".join(("x",)))
print("ab" * 3, 2 * "cd", "x" * 0)
print(repr("q\"uote\\ \t\n"), str("plain"), repr(42), str([1, "a"]))
print(ord("A"), ord("é"), ord("€"), chr(97), chr(233), chr(8364), chr(128512))
print("a" < "b", "abc" < "abd", "b" < "abc", "" < "a", "Z" < "a")
print("héllo"[1:3] == "é", len("héllo"))
print(list("abc".elems()), type("x"))
words = []
for w in ["apple", "banana", "cherry"]:
    if w.startswith("b"):
        continue
    words.append(w.endswith("y") and w + "!" or w)
print(words)
