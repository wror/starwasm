PRELUDE = r'''# lib/prelude.star - builtins and methods written in Starlark.
#
# The compiler compiles this into every program (keeping only the functions
# the program can reach). It is ordinary Starlark, kept in a raw string so
# the compiler carries it along; line numbers here match the file's.
#
# - Public top-level functions (min, max, ...) are builtins: user code sees
#   them after its own globals.
# - _m_<name>(receiver, ...) implements method <name> for values whose
#   method isn't generated in lib/builtins.star.
# - It may call primitives that only it can see (see PRELUDE_INTRINSICS in
#   compiler/codegen.star): _error(msg) fails as the builtin being called
#   ("Error in split: ..."), _error_plain(msg) fails plainly, _find and _rfind
#   search a string, _bytes_to_str builds one, _frozen tests the flag,
#   _iterating whether a loop is going over the value,
#   _set_new/_set_dict make a set and expose its element dict, _unhashable
#   names what makes a value unhashable (or None), _to_bytes makes bytes,
#   _struct_new/_struct_dict make a struct and expose its fields, and
#   _bound(x, name) makes the bound method x.name.
# - The compiler compiles an attribute expression x.name (not called) as
#   _attr(x, "name").
# - Its frames are hidden in tracebacks, like builtins in starlark-go, and
#   error messages follow starlark-go's wording.

_WS = " \t\n\r\x0b\x0c"

# " (did you mean .n?)": the spelling hint for x.name (starlark-go's spell.Nearest)
def _attr_hint(names, name):
    n = _nearest(name, sorted(names))
    return "" if n == None else " (did you mean ." + n + "?)"

def _no_attr(x, name):
    _error_plain(type(x) + " has no ." + name + " field or method" + _attr_hint(_ATTRS.get(type(x), []), name))

def _want_str(name, x, what):
    if type(x) != "string":
        _error(name + ": " + what + ": got " + type(x) + ", want string")

def _index_arg(name, which, n, i, default):
    """A start/end argument (which: "start" or "end") of a search method,
    resolved like a slice bound, with starlark-go's errors."""
    if i == None:
        return default
    if type(i) != "int":
        _error(name + ": invalid " + which + " index: got " + type(i) + ", want int")
    if i < -2147483648 or i > 2147483647:
        _error(name + ": invalid " + which + " index: " + str(i) + " out of range")
    return _clamp(n, i, default)

def _clamp(n, i, default):
    """A start/end argument resolved like a slice bound."""
    if i == None:
        return default
    if i < 0:
        i += n
        if i < 0:
            i = 0
    if i > n:
        i = n
    return i

def _is_iterable(x):
    t = type(x)
    return t == "list" or t == "tuple" or t == "dict" or t == "set" or t == "range" or \
           t == "string.elems" or t == "string.codepoints" or t == "bytes.elems"

def _iterable(name, x):
    if not _is_iterable(x):
        _error(name + ": for parameter 1: got " + type(x) + ", want iterable")

# ---------------------------------------------------------------- builtins

def all(x):
    _iterable("all", x)
    for v in x:
        if not v:
            return False
    return True

def any(x):
    _iterable("any", x)
    for v in x:
        if v:
            return True
    return False

def _comparable(a, b):
    ta = type(a)
    if (ta == "int" or ta == "float") and (type(b) == "int" or type(b) == "float"):
        return True
    if ta != type(b):
        return False
    return ta == "int" or ta == "string" or ta == "list" or ta == "tuple" or ta == "bytes"

def _minmax(name, args, key, want_max):
    if not args:
        _error(name + " requires at least one positional argument")
    items = args
    if len(args) == 1:
        items = args[0]
        if not _is_iterable(items):
            _error(name + ": " + type(items) + " value is not iterable")
    # iterate the argument itself: key may not change it meanwhile
    best = None
    bk = None
    first = True
    for x in items:
        k = x if key == None else key(x)
        if first:
            best = x
            bk = k
            first = False
            continue
        if not _comparable(k, bk):
            _error(name + ": " + type(k) + (" > " if want_max else " < ") + type(bk) + " not implemented")
        if (k > bk) if want_max else (k < bk):
            best = x
            bk = k
    if first:
        _error(name + ": argument is an empty sequence")
    return best

def min(*args, key = None):
    return _minmax("min", args, key, False)

def max(*args, key = None):
    return _minmax("max", args, key, True)

def zip(*args, **kwargs):
    if kwargs:
        _error("zip does not accept keyword arguments")
    seqs = []
    for i, a in enumerate(args):
        if not _is_iterable(a):
            _error("zip: argument #" + str(i + 1) + " is not iterable: " + type(a))
        seqs.append(list(a))
    if not seqs:
        return []
    n = len(seqs[0])
    for s in seqs:
        if len(s) < n:
            n = len(s)
    return [tuple([s[i] for s in seqs]) for i in range(n)]

# ---------------------------------------------------------------- int, dict

def _digit(b):
    """The value of ASCII digit/letter byte b (as in base 36), or 99."""
    if b >= 48 and b <= 57:
        return b - 48
    if b >= 97 and b <= 122:
        return b - 87
    if b >= 65 and b <= 90:
        return b - 55
    return 99

def _parse_int(s, base):
    """The int that string s denotes in base (0: by prefix), or None; as
    starlark-go's parseInt."""
    neg = False
    if s and s[0] == "+":
        s = s[1:]
    elif s and s[0] == "-":
        neg = True
        s = s[1:]
    if len(s) > 1 and s[0] == "0":
        prefix = 0
        if len(s) > 2:
            c = s[1]
            if c == "o" or c == "O":
                prefix = 8
            elif c == "x" or c == "X":
                prefix = 16
            elif c == "b" or c == "B":
                prefix = 2
        if prefix != 0:
            if base == 0 or prefix == base:
                base = prefix
                s = s[2:]
        elif base == 0:
            # "0755" is not an int with automatic base
            for c in s[1:].elems():
                if c != "0":
                    return None
            return 0
    if base == 0:
        base = 10
    if s == "":
        return None
    n = 0
    for b in s.elem_ords():
        d = _digit(b)
        if d >= base:
            return None
        n = n * base + d
    return -n if neg else n

def int(x, base = _absent()):
    if type(x) == "string":
        b = 10
        if not _is_absent(base):
            if type(base) != "int":
                _error("int: for base, got " + type(base) + ", want int")
            b = base
            if b != 0 and (b < 2 or b > 36):
                _error("int: base must be an integer >= 2 && <= 36")
        r = _parse_int(x, b)
        if r == None:
            _error("int: invalid literal with base " + str(b) + ": " + x)
        return r
    if not _is_absent(base):
        _error("int: can't convert non-string with explicit base")
    return _int_of(x)

def dict(*args, **kwargs):
    if len(args) > 1:
        _error("dict: got " + str(len(args)) + " arguments, want at most 1")
    d = {}
    if args:
        a = args[0]
        if type(a) == "dict":
            for k in a:
                d[k] = a[k]
        else:
            if not _is_iterable(a):
                _error("dict: got " + type(a) + ", want iterable")
            for i, pair in enumerate(a):
                if not _is_iterable(pair):
                    _error("dict: dictionary update sequence element #" + str(i) + " is not iterable (" + type(pair) + ")")
                if len(pair) != 2:
                    _error("dict: dictionary update sequence element #" + str(i) + " has length " + str(len(pair)) + ", want 2")
                k, v = pair
                d[k] = v
    for k in kwargs:
        d[k] = kwargs[k]
    return d

def reversed(x):
    _iterable("reversed", x)
    return list(x)[::-1]

_ATTRS = {
    "string": [
        "capitalize", "codepoint_ords", "codepoints", "count", "elem_ords", "elems", "endswith",
        "find", "format", "index", "isalnum", "isalpha", "isdigit", "islower", "isspace", "istitle",
        "isupper", "join", "lower", "lstrip", "partition", "removeprefix", "removesuffix", "replace",
        "rfind", "rindex", "rpartition", "rsplit", "rstrip", "split", "splitlines", "startswith",
        "strip", "title", "upper",
    ],
    "list": ["append", "clear", "extend", "index", "insert", "pop", "remove"],
    "dict": ["clear", "get", "items", "keys", "pop", "popitem", "setdefault", "update", "values"],
    "set": [
        "add", "clear", "difference", "discard", "intersection", "issubset", "issuperset", "pop",
        "remove", "symmetric_difference", "union", "update",
    ],
    "bytes": ["elems"],
}

def hasattr(x, name):
    if type(name) != "string":
        _error("hasattr: for parameter 2: got " + type(name) + ", want string")
    if type(x) == "struct":
        return name in _struct_dict(x)
    return name in _ATTRS.get(type(x), [])

def dir(x):
    if type(x) == "struct":
        return list(_struct_dict(x))
    return sorted(_ATTRS.get(type(x), []))

def _attr(x, name):
    """x.name, for an attribute expression that is not a method call."""
    t = type(x)
    if t == "struct":
        d = _struct_dict(x)
        if name in d:
            return d[name]
        _error_plain("struct has no ." + name + " attribute" + _attr_hint(d.keys(), name))
    if name in _ATTRS.get(t, []):
        return _bound(x, name)
    _error_plain(t + " has no ." + name + " field or method" + _attr_hint(_ATTRS.get(t, []), name))

def getattr(x, name, *default):
    if len(default) > 1:
        _error("getattr: got " + str(2 + len(default)) + " arguments, want at most 3")
    if type(name) != "string":
        _error("getattr: for parameter 2: got " + type(name) + ", want string")
    if hasattr(x, name):
        return _attr(x, name)
    if default:
        return default[0]
    if type(x) == "struct":
        _error("getattr: struct has no ." + name + " attribute")
    _error("getattr: " + type(x) + " has no ." + name + " field or method")

# ---------------------------------------------------------------- struct, bytes
#
# The struct and bytes types, their operators, comparisons, hashing and
# printing are generated (lib/runtime.star).

def struct(*args, **kwargs):
    if args:
        _error("struct: unexpected positional arguments")
    return _struct_new(kwargs)

def bytes(x):
    t = type(x)
    if t == "bytes":
        return x
    if t == "string":
        return _to_bytes(x)
    if not _is_iterable(x):
        _error("bytes: got " + t + ", want string, bytes, or iterable of ints")
    for i, v in enumerate(x):
        if type(v) != "int":
            _error("bytes: at index " + str(i) + ", got " + type(v) + ", want int")
        if v < 0 or v > 255:
            _error("bytes: at index " + str(i) + ", " + str(v) + " out of range (want value in unsigned 8-bit range)")
    return _to_bytes(x)

# ---------------------------------------------------------------- string search

def _search(name, s, sub, start, end, last):
    if type(s) != "string":
        _no_attr(s, name)
    _want_str(name, sub, "for parameter 1")
    n = len(s)
    lo = _index_arg(name, "start", n, start, 0)
    hi = _index_arg(name, "end", n, end, n)
    if last:
        return _rfind(s, sub, lo, hi)
    return _find(s, sub, lo, hi)

def _m_find(s, sub, start = None, end = None):
    return _search("find", s, sub, start, end, False)

def _m_rfind(s, sub, start = None, end = None):
    return _search("rfind", s, sub, start, end, True)

def _m_index(x, sub, start = None, end = None):
    if type(x) == "list":
        n = len(x)
        for i in range(_index_arg("index", "start", n, start, 0), _index_arg("index", "end", n, end, n)):
            if x[i] == sub:
                return i
        _error("index: value not in list")
    i = _search("index", x, sub, start, end, False)
    if i < 0:
        _error("index: substring not found")
    return i

def _m_rindex(s, sub, start = None, end = None):
    i = _search("rindex", s, sub, start, end, True)
    if i < 0:
        _error("rindex: substring not found")
    return i

def _m_count(s, sub, start = None, end = None):
    if type(s) != "string":
        _no_attr(s, "count")
    _want_str("count", sub, "for parameter 1")
    n = len(s)
    lo = _index_arg("count", "start", n, start, 0)
    hi = _index_arg("count", "end", n, end, n)
    if sub == "":
        return hi - lo + 1 if hi >= lo else 0
    c = 0
    while True:
        j = _find(s, sub, lo, hi)
        if j < 0:
            return c
        c += 1
        lo = j + len(sub)

def _affix(name, s, p, at_end, start, end):
    if type(s) != "string":
        _no_attr(s, name)
    lo = _index_arg(name, "start", len(s), start, 0)
    hi = _index_arg(name, "end", len(s), end, len(s))
    s = s[lo:hi] if hi > lo else ""
    if type(p) == "tuple":
        for i, q in enumerate(p):
            if type(q) != "string":
                _error(name + ": want string, got " + type(q) + ", for element " + str(i))
            if _has_affix(s, q, at_end):
                return True
        return False
    if type(p) != "string":
        _error(name + ": got " + type(p) + ", want string or tuple of string")
    return _has_affix(s, p, at_end)

def _has_affix(s, p, at_end):
    if len(p) > len(s):
        return False
    if at_end:
        return s[len(s) - len(p):] == p
    return s[:len(p)] == p

def _m_startswith(s, prefix, start = None, end = None):
    return _affix("startswith", s, prefix, False, start, end)

def _m_endswith(s, suffix, start = None, end = None):
    return _affix("endswith", s, suffix, True, start, end)

def _m_removeprefix(s, p):
    if type(s) != "string":
        _no_attr(s, "removeprefix")
    _want_str("removeprefix", p, "for parameter 1")
    return s[len(p):] if _has_affix(s, p, False) else s

def _m_removesuffix(s, p):
    if type(s) != "string":
        _no_attr(s, "removesuffix")
    _want_str("removesuffix", p, "for parameter 1")
    return s[:len(s) - len(p)] if p and _has_affix(s, p, True) else s

def _m_partition(s, sep):
    if type(s) != "string":
        _no_attr(s, "partition")
    _want_str("partition", sep, "for parameter 1")
    if sep == "":
        _error("partition: empty separator")
    j = _find(s, sep, 0, len(s))
    if j < 0:
        return (s, "", "")
    return (s[:j], sep, s[j + len(sep):])

def _m_rpartition(s, sep):
    if type(s) != "string":
        _no_attr(s, "rpartition")
    _want_str("rpartition", sep, "for parameter 1")
    if sep == "":
        _error("rpartition: empty separator")
    j = _rfind(s, sep, 0, len(s))
    if j < 0:
        return ("", "", s)
    return (s[:j], sep, s[j + len(sep):])

# ---------------------------------------------------------------- splitting

def _split_ws(s, maxsplit, right):
    """Split on runs of whitespace, ignoring leading/trailing whitespace."""
    words = []
    n = len(s)
    if not right:
        i = 0
        while True:
            while i < n and s[i] in _WS:
                i += 1
            if i >= n:
                return words
            if maxsplit >= 0 and len(words) == maxsplit:
                words.append(s[i:])
                return words
            j = i
            while j < n and s[j] not in _WS:
                j += 1
            words.append(s[i:j])
            i = j
    j = n
    while True:
        while j > 0 and s[j - 1] in _WS:
            j -= 1
        if j <= 0:
            return words[::-1]
        if maxsplit >= 0 and len(words) == maxsplit:
            words.append(s[:j])
            return words[::-1]
        i = j
        while i > 0 and s[i - 1] not in _WS:
            i -= 1
        words.append(s[i:j])
        j = i

def _split(name, s, sep, maxsplit, right):
    if type(s) != "string":
        _no_attr(s, name)
    if sep == None:
        return _split_ws(s, maxsplit, right)
    if type(sep) != "string":
        _error(name + ": got " + type(sep) + " for separator, want string")
    if sep == "":
        _error(name + ": empty separator")
    out = []
    if not right:
        i = 0
        while maxsplit < 0 or len(out) < maxsplit:
            j = _find(s, sep, i, len(s))
            if j < 0:
                break
            out.append(s[i:j])
            i = j + len(sep)
        out.append(s[i:])
        return out
    j = len(s)
    while maxsplit < 0 or len(out) < maxsplit:
        k = _rfind(s, sep, 0, j)
        if k < 0:
            break
        out.append(s[k + len(sep):j])
        j = k
    out.append(s[:j])
    return out[::-1]

def _m_split(s, sep = None, maxsplit = -1):
    return _split("split", s, sep, maxsplit, False)

def _m_rsplit(s, sep = None, maxsplit = -1):
    return _split("rsplit", s, sep, maxsplit, True)

def _m_splitlines(s, keepends = False):
    if type(s) != "string":
        _no_attr(s, "splitlines")
    if type(keepends) != "bool":
        _error("splitlines: for parameter 1: got " + type(keepends) + ", want bool")
    out = []
    i = 0
    n = len(s)
    while i < n:
        j = _find(s, "\n", i, n)
        if j < 0:
            out.append(s[i:])
            break
        out.append(s[i:j + 1] if keepends else s[i:j])
        i = j + 1
    return out

# Go's unicode.IsSpace (the White_Space property)
def _is_space_rune(r):
    if r < 0x100:
        return r == 0x20 or (r >= 0x09 and r <= 0x0d) or r == 0x85 or r == 0xa0
    return r == 0x1680 or (r >= 0x2000 and r <= 0x200a) or r == 0x2028 or r == 0x2029 or \
           r == 0x202f or r == 0x205f or r == 0x3000

# Byte lengths of the runes of s as Go decodes them (an invalid byte is
# U+FFFD, one byte long), with the rune values.
def _rune_spans(s):
    ords = list(s.codepoint_ords())
    lens = []
    i = 0
    for r in ords:
        if r < 0x80:
            k = 1
        elif r < 0x800:
            k = 2
        elif r < 0x10000:
            k = 3
        else:
            k = 4
        if r == 0xfffd and s[i:i + 3] != "\ufffd":
            k = 1
        lens.append(k)
        i += k
    return ords, lens

# strip/lstrip/rstrip as starlark-go: chars omitted or "" means whitespace
# (unicode.IsSpace); otherwise a set of runes (strings.Trim's cutset).
def _strip(name, s, chars, left, right):
    if type(s) != "string":
        _no_attr(s, name)
    ws = _is_absent(chars) or chars == ""
    if not ws:
        _want_str(name, chars, "for parameter 1")
    n = len(s)
    if n == 0:
        return s
    # fast path: nothing to strip at either end (both ends ASCII)
    a = s[0]
    z = s[n - 1]
    if a <= "\x7f" and z <= "\x7f":
        set_ = _WS if ws else chars
        if (not left or a not in set_) and (not right or z not in set_):
            return s
    ords, lens = _rune_spans(s)
    cut = {}
    if not ws:
        for r in chars.codepoint_ords():
            cut[r] = True
    i = 0
    j = n
    lo = 0
    hi = len(ords)
    if left:
        while lo < hi and (_is_space_rune(ords[lo]) if ws else ords[lo] in cut):
            i += lens[lo]
            lo += 1
    if right:
        while hi > lo and (_is_space_rune(ords[hi - 1]) if ws else ords[hi - 1] in cut):
            j -= lens[hi - 1]
            hi -= 1
    return s[i:j]

def _m_strip(s, chars = _absent()):
    return _strip("strip", s, chars, True, True)

def _m_lstrip(s, chars = _absent()):
    return _strip("lstrip", s, chars, True, False)

def _m_rstrip(s, chars = _absent()):
    return _strip("rstrip", s, chars, False, True)

def _m_replace(s, old, new, count = -1):
    if type(s) != "string":
        _no_attr(s, "replace")
    _want_str("replace", old, "for parameter 1")
    _want_str("replace", new, "for parameter 2")
    out = []
    k = 0
    if old == "":
        # insert `new` before every code point and at the end
        cps = _codepoints(s)
        for i in range(len(cps) + 1):
            if count < 0 or k < count:
                out.append(new)
                k += 1
            if i < len(cps):
                out.append(cps[i])
        return "".join(out)
    i = 0
    while count < 0 or k < count:
        j = _find(s, old, i, len(s))
        if j < 0:
            break
        out.append(s[i:j])
        out.append(new)
        i = j + len(old)
        k += 1
    out.append(s[i:])
    return "".join(out)

# ---------------------------------------------------------------- case and classes
#
# Unicode-aware, as starlark-go (Go's unicode package): _case and _classify
# are generated (lib/runtime.star rt_str_case / rt_str_class).

def _casefn(name, s, mode):
    if type(s) != "string":
        _no_attr(s, name)
    return _case(s, mode)

def _m_upper(s):
    return _casefn("upper", s, 0)

def _m_lower(s):
    return _casefn("lower", s, 1)

def _m_title(s):
    return _casefn("title", s, 2)

def _m_capitalize(s):
    return _casefn("capitalize", s, 3)

def _classfn(name, s, mode):
    if type(s) != "string":
        _no_attr(s, name)
    return _classify(s, mode)

def _m_isalnum(s):
    return _classfn("isalnum", s, 0)

def _m_isalpha(s):
    return _classfn("isalpha", s, 1)

def _m_isdigit(s):
    return _classfn("isdigit", s, 2)

def _m_isspace(s):
    return _classfn("isspace", s, 3)

def _m_islower(s):
    return _classfn("islower", s, 4)

def _m_isupper(s):
    return _classfn("isupper", s, 5)

def _m_istitle(s):
    return _classfn("istitle", s, 6)

# ---------------------------------------------------------------- code points, format

def _codepoints(s):
    """The UTF-8 sequences of s, as a list of strings."""
    out = []
    bs = s.elem_ords()
    i = 0
    n = len(bs)
    while i < n:
        c = bs[i]
        k = 1 if c < 0xc0 else (2 if c < 0xe0 else (3 if c < 0xf0 else 4))
        out.append(s[i:i + k])
        i += k
    return out

def _ascii_digits(s):
    if s == "":
        return False
    for b in s.elem_ords():
        if b < 48 or b > 57:
            return False
    return True

def _m_format(s, *args, **kwargs):
    if type(s) != "string":
        _no_attr(s, "format")
    out = []
    i = 0
    n = len(s)
    auto = 0
    mode = ""  # "", "auto" or "manual"
    while i < n:
        c = s[i]
        if c == "{":
            if i + 1 < n and s[i + 1] == "{":
                out.append("{")
                i += 2
                continue
            j = _find(s, "}", i, n)
            if j < 0:
                _error("format: unmatched '{' in format")
            field = s[i + 1:j]
            i = j + 1
            # as starlark-go: "name", "name:spec", "name!conv" or "name!conv:spec";
            # the name is resolved first, then spec and conv are checked
            conv = "s"
            spec = ""
            bang = _find(field, "!", 0, len(field))
            if bang < 0:
                colon = _find(field, ":", 0, len(field))
                if colon >= 0:
                    spec = field[colon + 1:]
                    field = field[:colon]
            else:
                rest = field[bang + 1:]
                field = field[:bang]
                colon = _find(rest, ":", 0, len(rest))
                if colon < 0:
                    conv = rest
                else:
                    conv = rest[:colon]
                    spec = rest[colon + 1:]
            if field == "":
                if mode == "manual":
                    _error("format: cannot switch from manual field specification to automatic field numbering")
                mode = "auto"
                if auto >= len(args):
                    _error("format: tuple index out of range")
                v = args[auto]
                auto += 1
            elif _ascii_digits(field):
                if mode == "auto":
                    _error("format: cannot switch from automatic field numbering to manual field specification")
                mode = "manual"
                k = int(field)
                if k >= len(args):
                    _error("format: tuple index out of range")
                v = args[k]
            else:
                if field not in kwargs:
                    if "." in field:
                        _error("format: attribute syntax x.y is not supported in replacement fields: " + field)
                    if "[" in field:
                        _error("format: element syntax a[i] is not supported in replacement fields: " + field)
                    if "{" in field:
                        _error("format: nested replacement fields not supported")
                    _error("format: keyword " + field + " not found")
                v = kwargs[field]
            if spec != "":
                _error("format spec features not supported in replacement fields: " + spec)
            if conv != "s" and conv != "r":
                _error("format: unknown conversion " + repr(conv))
            out.append(repr(v) if conv == "r" or type(v) == "bytes" else str(v))
        elif c == "}":
            if i + 1 < n and s[i + 1] == "}":
                out.append("}")
                i += 2
                continue
            _error("format: single '}' in format")
        else:
            j = _find(s, "{", i, n)
            k = _find(s, "}", i, n)
            if j < 0 or (k >= 0 and k < j):
                j = k
            if j < 0:
                j = n
            out.append(s[i:j])
            i = j
    return "".join(out)

# ---------------------------------------------------------------- list and dict methods

def _m_insert(l, i, x):
    if type(l) != "list":
        _no_attr(l, "insert")
    if type(i) != "int":
        _error("insert: for parameter 1: got " + type(i) + ", want int")
    if _frozen(l):
        _error("insert: cannot insert into frozen list")
    if _iterating(l):
        _error("insert: cannot insert into list during iteration")
    n = len(l)
    i = _clamp(n, i, 0)
    l.append(x)
    for j in range(n, i, -1):
        l[j] = l[j - 1]
    l[i] = x

def _m_remove(l, x):
    if type(l) == "set":
        if _frozen(l):
            _error("remove: cannot delete from frozen hash table")
        if _iterating(l):
            _error("remove: cannot delete from hash table during iteration")
        u = _unhashable(x)
        if u != None:
            _error("remove: unhashable type: " + u)
        d = _set_dict(l)
        if x not in d:
            _error("remove: missing key")
        d.pop(x)
        return None
    if type(l) != "list":
        _no_attr(l, "remove")
    if _frozen(l):
        _error("remove: cannot remove from frozen list")
    if _iterating(l):
        _error("remove: cannot remove from list during iteration")
    for i in range(len(l)):
        if l[i] == x:
            for j in range(i, len(l) - 1):
                l[j] = l[j + 1]
            l.pop()
            return None
    _error("remove: element not found")

def _m_clear(x):
    if type(x) == "list":
        if _frozen(x):
            _error("clear: cannot clear frozen list")
        if _iterating(x):
            _error("clear: cannot clear list during iteration")
        for _ in range(len(x)):
            x.pop()
        return None
    if type(x) == "dict":
        if _frozen(x):
            _error("cannot clear frozen hash table")
        if _iterating(x):
            _error("cannot clear hash table during iteration")
        for k in x.keys():
            x.pop(k)
        return None
    if type(x) == "set":
        if len(x) == 0:
            return None  # starlark-go: nothing to clear, even if frozen
        if _frozen(x):
            _error("clear: cannot clear frozen hash table")
        if _iterating(x):
            _error("clear: cannot clear hash table during iteration")
        d = _set_dict(x)
        for k in d.keys():
            d.pop(k)
        return None
    _no_attr(x, "clear")

def _m_update(d, *args, **kwargs):
    if type(d) == "set":
        if kwargs:
            _error("update: does not accept keyword arguments")
        # as starlark-go: mutability is checked for each element inserted
        sd = _set_dict(d)
        for i, a in enumerate(args):
            if not _is_iterable(a):
                _error("update: argument #" + str(i + 1) + " is not iterable: " + type(a))
            for x in a:
                if _frozen(d):
                    _error("update: cannot insert into frozen hash table")
                if _iterating(d):
                    _error("update: cannot insert into hash table during iteration")
                u = _unhashable(x)
                if u != None:
                    _error("update: unhashable type: " + u)
                sd[x] = None
        return None
    if type(d) != "dict":
        _no_attr(d, "update")
    if len(args) > 1:
        _error("update: got " + str(len(args)) + " arguments, want at most 1")
    if _frozen(d):
        _error("update: cannot insert into frozen hash table")
    if _iterating(d):
        _error("update: cannot insert into hash table during iteration")
    if args:
        a = args[0]
        if type(a) == "dict":
            for k in a.keys():
                d[k] = a[k]
        else:
            if type(a) != "list" and type(a) != "tuple":
                _error("update: got " + type(a) + ", want iterable")
            for i, pair in enumerate(a):
                if type(pair) != "list" and type(pair) != "tuple":
                    _error("update: dictionary update sequence element #" + str(i) + " is not iterable (" + type(pair) + ")")
                if len(pair) != 2:
                    _error("update: dictionary update sequence element #" + str(i) + " has length " + str(len(pair)) + ", want 2")
                d[pair[0]] = pair[1]
    for k in kwargs.keys():
        d[k] = kwargs[k]

def _m_popitem(d):
    if type(d) != "dict":
        _no_attr(d, "popitem")
    if _frozen(d):
        _error("popitem: cannot delete from frozen hash table")
    if _iterating(d):
        _error("popitem: cannot delete from hash table during iteration")
    if not d:
        _error("popitem: empty dict")
    k = d.keys()[0]
    return (k, d.pop(k))

# ---------------------------------------------------------------- sets
#
# The set type, its operators (| & ^ -), comparisons (subset), `in`,
# iteration, repr and freezing are generated (lib/runtime.star); a set's
# elements are the keys of a dict (_set_dict), so the methods below are
# dict operations.

def _set_add_all(name, d, items, i):
    """Add the elements of iterable `items` (argument #i+1) to element dict d."""
    if not _is_iterable(items):
        _error(name + ": argument #" + str(i + 1) + " is not iterable: " + type(items))
    for x in items:
        u = _unhashable(x)
        if u != None:
            _error(name + ": unhashable type: " + u)
        d[x] = None

def set(x = None):
    s = _set_new()
    if x != None:
        if not _is_iterable(x):
            _error("set: for parameter 1: got " + type(x) + ", want iterable")
        d = _set_dict(s)
        for e in x:
            u = _unhashable(e)
            if u != None:
                _error("set: unhashable type: " + u)
            d[e] = None
    return s

def _set_arg(name, x):
    """The single iterable argument of a set method, as a set."""
    if not _is_iterable(x):
        _error(name + ": for parameter 1: got " + type(x) + ", want iterable")
    if type(x) == "set":
        return x
    s = _set_new()
    _set_add_all(name, _set_dict(s), x, 0)
    return s

def _m_add(s, x):
    if type(s) != "set":
        _no_attr(s, "add")
    if _frozen(s):
        _error("add: cannot insert into frozen hash table")
    if _iterating(s):
        _error("add: cannot insert into hash table during iteration")
    u = _unhashable(x)
    if u != None:
        _error("add: unhashable type: " + u)
    _set_dict(s)[x] = None

def _m_discard(s, x):
    if type(s) != "set":
        _no_attr(s, "discard")
    if _frozen(s):
        _error("discard: cannot delete from frozen hash table")
    if _iterating(s):
        _error("discard: cannot delete from hash table during iteration")
    u = _unhashable(x)
    if u != None:
        _error("discard: unhashable type: " + u)
    d = _set_dict(s)
    if x in d:
        d.pop(x)

def _m_union(s, *others):
    if type(s) != "set":
        _no_attr(s, "union")
    r = s | _set_new()  # a copy
    for i, o in enumerate(others):
        _set_add_all("union", _set_dict(r), o, i)
    return r

def _m_intersection(s, other):
    if type(s) != "set":
        _no_attr(s, "intersection")
    return s & _set_arg("intersection", other)

def _m_difference(s, other):
    if type(s) != "set":
        _no_attr(s, "difference")
    return s - _set_arg("difference", other)

def _m_symmetric_difference(s, other):
    if type(s) != "set":
        _no_attr(s, "symmetric_difference")
    return s ^ _set_arg("symmetric_difference", other)

def _m_issubset(s, other):
    if type(s) != "set":
        _no_attr(s, "issubset")
    return s <= _set_arg("issubset", other)

def _m_issuperset(s, other):
    if type(s) != "set":
        _no_attr(s, "issuperset")
    return s >= _set_arg("issuperset", other)
'''
