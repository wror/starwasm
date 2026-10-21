# lexer.star — Starlark source text to tokens.
#
# A token is a dict {"kind", "val", "line", "col"}. Kinds:
#   "name" "int" "string"          val = identifier / int value / string value
#   "bytes"                         val = list of byte values (b"..." literals)
#   "float"                         val = the literal's text ("1.5e3")
#   "newline" "indent" "dedent" "eof"
#   keywords and operators          kind is the text itself: "def", "+=", "("
#
# Plain Starlark: the compiler compiles this file too (stage2 runs it).

KEYWORDS = {
    "and": True,
    "break": True,
    "continue": True,
    "def": True,
    "elif": True,
    "else": True,
    "for": True,
    "if": True,
    "in": True,
    "lambda": True,
    "load": True,
    "not": True,
    "or": True,
    "pass": True,
    "return": True,
    "while": True,
}

# Python keywords that Starlark reserves. Not "assert": starlark-go accepts
# it as a name (its test files load an assert module).
RESERVED = {
    "as": True,
    "async": True,
    "await": True,
    "class": True,
    "del": True,
    "except": True,
    "finally": True,
    "from": True,
    "global": True,
    "import": True,
    "is": True,
    "nonlocal": True,
    "raise": True,
    "try": True,
    "with": True,
    "yield": True,
}

OPS3 = {"//=": True, "<<=": True, ">>=": True}
OPS2 = {
    "==": True,
    "!=": True,
    "<=": True,
    ">=": True,
    "//": True,
    "<<": True,
    ">>": True,
    "+=": True,
    "-=": True,
    "*=": True,
    "/=": True,
    "%=": True,
    "&=": True,
    "|=": True,
    "^=": True,
    "**": True,
    "->": True,
}
OPS1 = "+-*/%&|^~<>()[]{},:.;="
OPEN = "([{"
CLOSE = ")]}"

DIGITS = {
    "0": 0, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9,
    "a": 10, "b": 11, "c": 12, "d": 13, "e": 14, "f": 15,
    "A": 10, "B": 11, "C": 12, "D": 13, "E": 14, "F": 15,
}

SIMPLE_ESCAPES = {
    "n": "\n",
    "t": "\t",
    "r": "\r",
    "\\": "\\",
    "'": "'",
    "\"": "\"",
    "a": "\x07",
    "b": "\x08",
    "f": "\x0c",
    "v": "\x0b",
}

MAX_INT = 9223372036854775807  # 2^63 - 1, written out: 1 << 63 would overflow

def is_letter(c):
    return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"

def is_digit(c):
    return c >= "0" and c <= "9"

def lex_error(st, msg, line, col):
    fail(st["file"] + ":" + str(line) + ":" + str(col) + ": " + msg)

def emit(st, kind, val, line, col):
    st["toks"].append({"kind": kind, "val": val, "line": line, "col": col})

def col_of(st, i):
    return i - st["linestart"] + 1

def digit_value(st, c, base, line, col):
    v = DIGITS.get(c)
    if v == None or v >= base:
        lex_error(st, "invalid digit '" + c + "' in base-" + str(base) + " literal", line, col)
    return v

# The largest decimal value that still rounds to a finite float64: 2**1024
# - 2**970, i.e. 1.797693134862315807937289714053...e308 (as digits).
FLOAT_LIMIT = "17976931348623158079372897140530341507993413277"

def float_too_large(st, digits, exp):
    """Whether the float literal with these significand digits (no dot)
    and decimal exponent (value = 0.d1d2... * 10**exp) overflows."""
    k = 0
    while k < len(digits) and digits[k] == "0":
        k += 1
    digits = digits[k:]
    if digits == "":
        return False
    exp -= k
    if exp != 309:
        return exp > 309
    for j in range(len(FLOAT_LIMIT)):
        d = digits[j] if j < len(digits) else "0"
        if d != FLOAT_LIMIT[j]:
            return d > FLOAT_LIMIT[j]
    return True

def scan_float(st, i, line, col):
    """A decimal float literal at i ("1.5", ".5", "1.", "1e3", "2.5E-3")."""
    src = st["src"]
    n = len(src)
    j = i
    while j < n and is_digit(src[j]):
        j += 1
    intpart = src[i:j]
    frac = ""
    if j < n and src[j] == ".":
        k = j + 1
        while k < n and is_digit(src[k]):
            k += 1
        frac = src[j + 1:k]
        j = k
    exp = 0
    if j < n and (src[j] == "e" or src[j] == "E"):
        k = j + 1
        sign = 1
        if k < n and (src[k] == "+" or src[k] == "-"):
            sign = -1 if src[k] == "-" else 1
            k += 1
        if k >= n or not is_digit(src[k]):
            lex_error(st, "invalid float literal", line, col)
        while k < n and is_digit(src[k]):
            if exp < 100000:
                exp = exp * 10 + DIGITS[src[k]]
            k += 1
        exp *= sign
        j = k
    if j < n and is_letter(src[j]):
        lex_error(st, "invalid float literal", line, col)
    if float_too_large(st, intpart + frac, exp + len(intpart)):
        lex_error(st, "invalid float literal", line, col)
    emit(st, "float", src[i:j], line, col)
    return j

def is_float_start(src, i):
    """Whether the number at i is a float: digits followed by ".", "e" or "E"."""
    n = len(src)
    j = i
    while j < n and is_digit(src[j]):
        j += 1
    return j < n and (src[j] == "." or src[j] == "e" or src[j] == "E")

def scan_number(st, i):
    src = st["src"]
    n = len(src)
    line = st["line"]
    col = col_of(st, i)
    if not (src[i] == "0" and i + 1 < n and src[i + 1] in "xXoObB") and is_float_start(src, i):
        return scan_float(st, i, line, col)
    base = 10
    j = i
    if src[i] == "0" and i + 1 < n and src[i + 1] in "xXoObB":
        p = src[i + 1]
        if p == "x" or p == "X":
            base = 16
        elif p == "o" or p == "O":
            base = 8
        else:
            base = 2
        j = i + 2
    start = j
    val = 0
    while j < n and (is_letter(src[j]) or is_digit(src[j])):
        val = val * base + digit_value(st, src[j], base, line, col)
        j += 1
    # ints are unbounded, but (as in starlark-go) octal and binary literals
    # must fit in 64 bits
    if (base == 8 or base == 2) and val > MAX_INT:
        lex_error(st, "invalid int literal", line, col)
    if j == start:
        lex_error(st, "missing digits in int literal", line, col)
    if base == 10 and src[i] == "0" and j > i + 1:
        lex_error(st, "obsolete form of octal literal; use 0o...", line, col)
    emit(st, "int", val, line, col)
    return j

def scan_hex(st, i, count, line, col):
    """Value of exactly `count` hex digits at i."""
    src = st["src"]
    if i + count > len(src):
        lex_error(st, "truncated escape sequence", line, col)
    v = 0
    for k in range(count):
        v = v * 16 + digit_value(st, src[i + k], 16, line, col)
    return v

def scan_string(st, i, raw, is_bytes = False):
    """A string literal at i (the opening quote); emits a "string" token, or
    for b"..." a "bytes" token whose value is a list of byte values."""
    src = st["src"]
    n = len(src)
    line = st["line"]
    col = col_of(st, i)
    q = src[i]
    triple = i + 2 < n and src[i + 1] == q and src[i + 2] == q
    j = i + 3 if triple else i + 1
    out = []
    while True:
        if j >= n:
            lex_error(st, "unterminated string literal", line, col)
        c = src[j]
        if c == q:
            if not triple:
                j += 1
                break
            if j + 2 < n and src[j + 1] == q and src[j + 2] == q:
                j += 3
                break
            out.append(c)
            j += 1
            continue
        if c == "\n":
            if not triple:
                lex_error(st, "unterminated string literal", line, col)
            st["line"] += 1
            st["linestart"] = j + 1
            out.append(c)
            j += 1
            continue
        if c != "\\":
            out.append(c)
            j += 1
            continue

        # backslash
        if j + 1 >= n:
            lex_error(st, "unterminated string literal", line, col)
        e = src[j + 1]
        if raw:
            out.append("\\")
            out.append(e)
            if e == "\n":
                st["line"] += 1
                st["linestart"] = j + 2
            j += 2
            continue
        if e == "\n":  # line continuation inside a string
            st["line"] += 1
            st["linestart"] = j + 2
            j += 2
            continue
        simple = SIMPLE_ESCAPES.get(e)
        if simple != None:
            out.append(simple)
            j += 2
            continue
        if e == "x":
            v = scan_hex(st, j + 2, 2, line, col)
            if is_bytes:
                out.append(v)
                j += 4
                continue
            if v >= 128:
                lex_error(st, "non-ASCII \\x escapes are not supported", line, col)
            out.append(chr(v))
            j += 4
            continue
        if e == "u" or e == "U":
            count = 4 if e == "u" else 8
            v = scan_hex(st, j + 2, count, line, col)
            if v > 0x10ffff or (v >= 0xd800 and v < 0xe000):
                lex_error(st, "invalid Unicode code point in escape", line, col)
            out.append(chr(v))
            j += 2 + count
            continue
        if e >= "0" and e <= "7":
            v = 0
            k = j + 1
            while k < n and k < j + 4 and src[k] >= "0" and src[k] <= "7":
                v = v * 8 + DIGITS[src[k]]
                k += 1
            if is_bytes and v < 256:
                out.append(v)
                j = k
                continue
            if v >= 128:
                lex_error(st, "non-ASCII octal escapes are not supported", line, col)
            out.append(chr(v))
            j = k
            continue
        lex_error(st, "invalid escape sequence \\" + e, line, col)
    if is_bytes:
        # one value per byte (escapes like \xff already are)
        b = []
        for x in out:
            if type(x) == "int":
                b.append(x)
            else:
                b.extend(x.elem_ords())
        emit(st, "bytes", b, line, col)
    else:
        emit(st, "string", "".join(out), line, col)
    return j

def handle_indent(st, i):
    """At the start of a logical line: measure indentation, skip blank and
    comment-only lines, emit indent/dedent tokens. Returns the index of the
    first significant character, or len(src) at end of input."""
    src = st["src"]
    n = len(src)
    while True:
        j = i
        width = 0
        while j < n and (src[j] == " " or src[j] == "\t" or src[j] == "\r"):
            if src[j] == "\t":
                lex_error(st, "tab characters are not allowed in indentation", st["line"], col_of(st, j))
            if src[j] == " ":
                width += 1
            j += 1
        if j >= n:
            return n
        if src[j] == "#":
            while j < n and src[j] != "\n":
                j += 1
        if j < n and src[j] == "\n":
            st["line"] += 1
            st["linestart"] = j + 1
            i = j + 1
            continue
        if j >= n:
            return n
        indents = st["indents"]
        if width > indents[-1]:
            indents.append(width)
            emit(st, "indent", None, st["line"], col_of(st, j))
        elif width < indents[-1]:
            while width < indents[-1]:
                indents.pop()
                emit(st, "dedent", None, st["line"], col_of(st, j))
            if width != indents[-1]:
                lex_error(st, "unindent does not match any outer indentation level", st["line"], col_of(st, j))
        return j

def lex(src, filename):
    st = {
        "src": src,
        "file": filename,
        "toks": [],
        "line": 1,
        "linestart": 0,
        "indents": [0],
        "depth": 0,  # bracket nesting; newlines inside brackets are ignored
    }
    n = len(src)
    i = 0
    at_line_start = True
    while True:
        if at_line_start and st["depth"] == 0:
            i = handle_indent(st, i)
            at_line_start = False
        if i >= n:
            break
        c = src[i]
        if c == " " or c == "\t" or c == "\r":
            i += 1
        elif c == "#":
            while i < n and src[i] != "\n":
                i += 1
        elif c == "\\" and i + 1 < n and src[i + 1] == "\n":
            i += 2
            st["line"] += 1
            st["linestart"] = i
        elif c == "\n":
            if st["depth"] == 0:
                emit(st, "newline", None, st["line"], col_of(st, i))
                at_line_start = True
            i += 1
            st["line"] += 1
            st["linestart"] = i
        elif is_letter(c):
            col = col_of(st, i)
            j = i
            while j < n and (is_letter(src[j]) or is_digit(src[j])):
                j += 1
            word = src[i:j]
            if j < n and (src[j] == "\"" or src[j] == "'") and (word == "r" or word == "R"):
                i = scan_string(st, j, True)
                continue
            if j < n and (src[j] == "\"" or src[j] == "'") and (word == "b" or word == "B"):
                i = scan_string(st, j, False, True)
                st["toks"][-1]["col"] = col  # the literal starts at the prefix
                continue
            if j < n and (src[j] == "\"" or src[j] == "'") and word == "rb":
                i = scan_string(st, j, True, True)
                st["toks"][-1]["col"] = col
                continue
            if KEYWORDS.get(word):
                emit(st, word, None, st["line"], col)
            elif RESERVED.get(word):
                lex_error(st, "keyword " + word + " is reserved", st["line"], col)
            else:
                emit(st, "name", word, st["line"], col)
            i = j
        elif is_digit(c):
            i = scan_number(st, i)
        elif c == "." and i + 1 < n and is_digit(src[i + 1]):
            i = scan_float(st, i, st["line"], col_of(st, i))
        elif c == "\"" or c == "'":
            i = scan_string(st, i, False)
        else:
            col = col_of(st, i)
            three = src[i:i + 3]
            two = src[i:i + 2]
            if OPS3.get(three):
                emit(st, three, None, st["line"], col)
                i += 3
            elif OPS2.get(two):
                emit(st, two, None, st["line"], col)
                i += 2
            elif c in OPS1:
                if c in OPEN:
                    st["depth"] += 1
                elif c in CLOSE:
                    st["depth"] -= 1
                    if st["depth"] < 0:
                        lex_error(st, "unbalanced '" + c + "'", st["line"], col)
                emit(st, c, None, st["line"], col)
                i += 1
            else:
                lex_error(st, "unexpected character '" + c + "'", st["line"], col)

    if st["depth"] != 0:
        lex_error(st, "unexpected end of file inside brackets", st["line"], col_of(st, i))
    toks = st["toks"]
    if toks and toks[-1]["kind"] != "newline":
        emit(st, "newline", None, st["line"], col_of(st, i))
    while len(st["indents"]) > 1:
        st["indents"].pop()
        emit(st, "dedent", None, st["line"], 1)
    emit(st, "eof", None, st["line"], col_of(st, i))
    return toks
