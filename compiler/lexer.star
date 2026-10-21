# lexer.star — Starlark source text to tokens: a port of starlark-go's
# scanner (go.starlark.net/syntax/scan.go and quote.go), with the same
# tokens, error messages and positions.
#
# A token is a dict {"kind", "val", "line", "col", "eline", "ecol"}:
# (line, col) is where it starts; (eline, ecol) is just after it, which is
# where starlark-go's scanner stands while the token is the parser's
# lookahead (the position most syntax errors are reported at). Columns
# count Unicode code points from 1 (a tab counts 1). Kinds:
#   "name" "int" "string"          val = identifier / int value / string value
#   "bytes"                         val = list of byte values (b"..." literals)
#   "float"                         val = the literal's text ("1.5e3")
#   "newline" "indent" "dedent" "eof"
#   keywords, reserved words and operators: kind is the text itself
#
# As in starlark-go: blank lines and comments make no tokens; a file not
# ending in a newline has none before "eof" unless a block is open; newlines
# inside brackets are ignored.
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
    # reserved words (from Python): tokens of their own, which no rule of
    # the grammar accepts. Not "assert": starlark-go's tests use the name.
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

# Operators that may be followed by "=" (as starlark-go's scanner).
EQ_OPS = {"=": True, "<": True, ">": True, "!": True, "+": True, "-": True, "%": True, "/": True, "&": True, "|": True, "^": True}

HEX = "0123456789abcdefABCDEF"

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

def is_digit(c):
    return c >= "0" and c <= "9"

def is_ascii_ident(c):
    return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_" or (c >= "0" and c <= "9")

# Non-ASCII bytes (any c > "\x7f") are told apart by their values (a
# Starlark string literal can't hold a lone "\xc0"): byte_at reads them from
# the source's byte values, listed on first use.

def byte_at(st, i):
    bv = st["bv"]
    if bv == None:
        bv = list(bytes(st["src"]).elems())
        st["bv"] = bv
    return bv[i]

def rune_len(st, i):
    """Bytes in the UTF-8 sequence that starts at non-ASCII byte i."""
    v = byte_at(st, i)
    if v < 0xe0:
        return 2
    if v < 0xf0:
        return 3
    return 4

def is_cont(st, i):
    """Byte i is a UTF-8 continuation byte: not a code point of its own."""
    v = byte_at(st, i)
    return v >= 0x80 and v < 0xc0

def lex_error(st, msg, line, col):
    fail(st["file"] + ":" + str(line) + ":" + str(col) + ": " + msg)

def here_error(st, msg):
    lex_error(st, msg, st["line"], st["col"])

def emit(st, kind, val, line, col):
    """A token from (line, col) to where the scanner is now."""
    st["toks"].append({"kind": kind, "val": val, "line": line, "col": col, "eline": st["line"], "ecol": st["col"]})

def skip_to(st, j):
    """Move to byte j on the same line, counting code points."""
    src = st["src"]
    col = st["col"]
    for k in range(st["i"], j):
        if src[k] <= "\x7f" or not is_cont(st, k):
            col += 1
    st["col"] = col
    st["i"] = j

def skip_ascii(st, j):
    """skip_to for a run of ASCII characters."""
    st["col"] += j - st["i"]
    st["i"] = j

def read_newline(st):
    st["i"] += 1
    st["line"] += 1
    st["col"] = 1

def hex_text(n, upper, width):
    s = ("%X" if upper else "%x") % n
    return "0" * (width - len(s)) + s

def is_hex(s):
    for c in s.elems():
        if c not in HEX:
            return False
    return True

def byte_char(c):
    """A byte as the character Go's %c gives it (Latin-1 for >= 0x80)."""
    return chr(list(bytes(c).elems())[0])

# ---------------------------------------------------------------- strings

def unquote(st, quoted, raw, is_bytes, triple, line, col):
    """The value of a string literal's text between its quotes (as
    starlark-go's unquote): a string, or for bytes a list of byte values.
    Errors are reported at (line, col), the opening quote."""
    if raw or "\\" not in quoted:
        if is_bytes:
            return list(bytes(quoted).elems())
        return quoted
    out = []  # strings, and byte values (ints) from escapes in bytes literals
    n = len(quoted)
    i = 0
    for _ in range(n + 1):
        if i >= n:
            break
        k = quoted.find("\\", i)
        if k < 0:
            out.append(quoted[i:])
            break
        if k > i:
            out.append(quoted[i:k])
        rest = quoted[k:]
        if k + 1 >= n:
            lex_error(st, "truncated escape sequence \\", line, col)
        e = quoted[k + 1]
        simple = SIMPLE_ESCAPES.get(e)
        if e == "\n":  # line continuation
            i = k + 2
        elif simple != None:
            out.append(simple)
            i = k + 2
        elif e >= "0" and e <= "7":
            v = int(e)
            j = k + 2
            for _ in range(2):
                if j >= n or quoted[j] < "0" or quoted[j] > "7":
                    break
                v = v * 8 + int(quoted[j])
                j += 1
            if not is_bytes and v > 127:
                h = hex_text(v, True, 4)
                lex_error(st, "non-ASCII octal escape \\" + ("%o" % v) + " (use \\u" + h + " for the UTF-8 encoding of U+" + h + ")", line, col)
            if v >= 256:
                o = "%o" % v
                lex_error(st, "invalid escape sequence \\" + "0" * (3 - len(o)) + o, line, col)
            out.append(v if is_bytes else chr(v))
            i = j
        elif e == "x":
            if len(rest) < 4:
                lex_error(st, "truncated escape sequence " + rest, line, col)
            if not is_hex(rest[2:4]):
                lex_error(st, "invalid escape sequence " + rest[:4], line, col)
            v = int(rest[2:4], 16)
            if not is_bytes and v > 127:
                h = hex_text(v, True, 4)
                lex_error(st, "non-ASCII hex escape " + rest[:4] + " (use \\u" + h + " for the UTF-8 encoding of U+" + h + ")", line, col)
            out.append(v if is_bytes else chr(v))
            i = k + 4
        elif e == "u" or e == "U":
            sz = 6 if e == "u" else 10
            if len(rest) < sz:
                lex_error(st, "truncated escape sequence " + rest, line, col)
            if not is_hex(rest[2:sz]):
                lex_error(st, "invalid escape sequence " + rest[:sz], line, col)
            v = int(rest[2:sz], 16)
            if v > 0x10ffff:
                lex_error(st, "code point out of range: " + rest[:sz] + " (max \\U" + hex_text(v, False, 8) + ")", line, col)
            if v >= 0xd800 and v < 0xe000:
                lex_error(st, "invalid Unicode code point U+" + hex_text(v, True, 4), line, col)
            out.append(chr(v))
            i = k + sz
        else:
            lex_error(st, "invalid escape sequence \\" + byte_char(e), line, col)
    if not is_bytes:
        return "".join(out)
    b = []
    for x in out:
        if type(x) == "int":
            b.append(x)
        else:
            b.extend(list(bytes(x).elems()))
    return b

def scan_string(st, start, raw, is_bytes, line, col):
    """A string literal whose opening quote is at the scanner (its prefix,
    if any, began at byte start, line, col)."""
    src = st["src"]
    n = st["n"]
    qline = st["line"]
    qcol = st["col"]
    q = src[st["i"]]
    triple = src[st["i"]:st["i"] + 3] == q + q + q
    skip_ascii(st, st["i"] + (3 if triple else 1))
    body = st["i"]
    i = st["i"]
    ln = st["line"]
    c0 = st["col"]
    quotes = 0
    for _ in range(n + 1):
        if i >= n:
            st["i"] = i
            st["line"] = ln
            st["col"] = c0
            lex_error(st, "unexpected EOF in string", line, col)
        c = src[i]
        i += 1
        if c == "\n":
            ln += 1
            c0 = 1
        elif c <= "\x7f" or not is_cont(st, i - 1):
            c0 += 1
        if c == q:
            if not triple:
                break
            quotes += 1
            if quotes == 3:
                break
            continue
        quotes = 0
        if c == "\n" and not triple:
            lex_error(st, "unexpected newline in string", line, col)
        if c == "\\":
            if i >= n:
                lex_error(st, "unexpected EOF in string", line, col)
            c = src[i]
            i += 1
            if c == "\n":
                ln += 1
                c0 = 1
            elif c <= "\x7f" or not is_cont(st, i - 1):
                c0 += 1
    st["i"] = i
    st["line"] = ln
    st["col"] = c0
    quoted = src[body:i - (3 if triple else 1)]
    val = unquote(st, quoted, raw, is_bytes, triple, qline, qcol)
    emit(st, "bytes" if is_bytes else "string", val, line, col)

# ---------------------------------------------------------------- numbers

# The largest decimal value that still rounds to a finite float64: 2**1024
# - 2**970, i.e. 1.797693134862315807937289714053...e308 (as digits).
FLOAT_LIMIT = "17976931348623158079372897140530341507993413277"

def float_too_large(digits, exp):
    """Whether the float literal with these significand digits (no dot)
    and decimal exponent (value = 0.d1d2... * 10**exp) overflows."""
    k = 0
    for _ in range(len(digits)):
        if k >= len(digits) or digits[k] != "0":
            break
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

def float_overflows(text):
    """Whether a decimal float literal is out of float64 range."""
    s = text.lower()
    e = s.find("e")
    exp = 0
    if e >= 0:
        t = s[e + 1:]
        sign = -1 if t.startswith("-") else 1
        t = t.lstrip("+-")
        t = t.lstrip("0")
        if len(t) > 6:  # an exponent this large: overflow (or underflow, which is fine)
            return sign > 0 and s[:e].replace(".", "").strip("0") != ""
        exp = sign * (int(t) if t else 0)
        s = s[:e]
    dot = s.find(".")
    intpart = s if dot < 0 else s[:dot]
    frac = "" if dot < 0 else s[dot + 1:]
    return float_too_large(intpart + frac, exp + len(intpart))

def digits_end(src, i, n, chars):
    for _ in range(n - i):
        if i >= n or src[i] not in chars:
            break
        i += 1
    return i

def scan_number(st):
    """A number, or a lone "." (as starlark-go's scanNumber)."""
    src = st["src"]
    n = st["n"]
    line = st["line"]
    col = st["col"]
    i0 = st["i"]
    c = src[i0]
    fraction = False
    exponent = False
    base = 10
    if c == ".":
        skip_ascii(st, i0 + 1)
        if st["i"] >= n or not is_digit(src[st["i"]]):
            emit(st, ".", None, line, col)
            return
        fraction = True
    elif c == "0":
        skip_ascii(st, i0 + 1)
        c = src[st["i"]] if st["i"] < n else ""
        if c == ".":
            fraction = True
        elif c == "x" or c == "X":
            base = 16
            skip_ascii(st, st["i"] + 1)
            if st["i"] >= n or src[st["i"]] not in HEX:
                lex_error(st, "invalid hex literal", line, col)
            skip_ascii(st, digits_end(src, st["i"], n, HEX))
        elif c == "o" or c == "O" or c == "b" or c == "B":
            base = 8 if c == "o" or c == "O" else 2
            ds = "01234567" if base == 8 else "01"
            skip_ascii(st, st["i"] + 1)
            if st["i"] >= n or src[st["i"]] not in ds:
                here_error(st, "invalid octal literal" if base == 8 else "invalid binary literal")
            skip_ascii(st, digits_end(src, st["i"], n, ds))
        else:
            j = digits_end(src, st["i"], n, "0123456789")
            ds = src[st["i"]:j]
            skip_ascii(st, j)
            c = src[j] if j < n else ""
            if c == ".":
                fraction = True
            elif c == "e" or c == "E":
                exponent = True
            elif ds.strip("0") != "" and ds.strip("01234567") == "":
                here_error(st, "obsolete form of octal literal; use 0o" + src[i0 + 1:j])
    else:
        j = digits_end(src, i0, n, "0123456789")
        skip_ascii(st, j)
        c = src[j] if j < n else ""
        if c == ".":
            fraction = True
        elif c == "e" or c == "E":
            exponent = True
    if fraction:
        skip_ascii(st, digits_end(src, st["i"] + 1, n, "0123456789"))
        c = src[st["i"]] if st["i"] < n else ""
        if c == "e" or c == "E":
            exponent = True
    if exponent:
        skip_ascii(st, st["i"] + 1)
        c = src[st["i"]] if st["i"] < n else ""
        if c == "+" or c == "-":
            skip_ascii(st, st["i"] + 1)
            if st["i"] >= n or not is_digit(src[st["i"]]):
                here_error(st, "invalid float literal")
        skip_ascii(st, digits_end(src, st["i"], n, "0123456789"))
    text = src[i0:st["i"]]
    if fraction or exponent:
        last = text[-1]
        if last == "e" or last == "E" or float_overflows(text):
            here_error(st, "invalid float literal")
        emit(st, "float", text, line, col)
        return
    if base == 16:
        val = int(text[2:], 16)
    elif base != 10:
        val = int(text[2:], base)
        if val > MAX_INT:  # as starlark-go: octal and binary must fit 64 bits
            lex_error(st, "invalid int literal", line, col)
    elif len(text) > 1 and text[0] == "0":
        if text.strip("0") != "":  # 08, 09: not octal either
            lex_error(st, "invalid int literal", line, col)
        val = 0
    else:
        val = int(text)
    emit(st, "int", val, line, col)

# ---------------------------------------------------------------- tokens

def next_token(st):
    """Scan the next token(s) (as starlark-go's nextToken; indentation may
    give several). Returns True at the end of the input."""
    src = st["src"]
    n = st["n"]
    for _ in range(n + 3):  # starlark-go's "goto start"
        blank = False
        saved_line_start = st["line_start"]
        if st["line_start"]:
            st["line_start"] = False
            width = 0
            i = st["i"]
            for _ in range(n - i + 1):
                c = src[i] if i < n else ""
                if c == " ":
                    width += 1
                elif c == "\t":
                    width += 8 - (st["col"] + (i - st["i"]) - 1) % 8
                else:
                    break
                i += 1
            skip_ascii(st, i)
            c = src[i] if i < n else ""
            if c == "#" or c == "\n" or c == "":
                blank = True
            if not blank and st["depth"] == 0:
                ind = st["indents"]
                if width > ind[-1]:
                    ind.append(width)
                    emit(st, "indent", None, st["line"], st["col"])
                    return False
                if width < ind[-1]:
                    k = 0
                    for _ in range(len(ind)):
                        if width >= ind[-1]:
                            break
                        ind.pop()
                        k += 1
                    if width != ind[-1]:
                        here_error(st, "unindent does not match any outer indentation level")
                    for _ in range(k):
                        emit(st, "dedent", None, st["line"], st["col"])
                    return False

        i = st["i"]
        for _ in range(n - i + 1):
            if i >= n or (src[i] != " " and src[i] != "\t"):
                break
            i += 1
        skip_ascii(st, i)
        c = src[i] if i < n else ""
        if c == "#":
            j = src.find("\n", i)
            skip_to(st, n if j < 0 else j)
            i = st["i"]
            c = src[i] if i < n else ""

        if c == "\n":
            st["line_start"] = True
            if st["depth"] > 0 or blank:
                read_newline(st)
                continue
            line = st["line"]
            col = st["col"]
            read_newline(st)
            emit(st, "newline", None, line, col)
            return False

        if c == "":
            if len(st["indents"]) > 1:
                if saved_line_start:
                    k = len(st["indents"]) - 1
                    st["indents"] = st["indents"][:1]
                    for _ in range(k):
                        emit(st, "dedent", None, st["line"], st["col"])
                    return False
                st["line_start"] = True
                emit(st, "newline", None, st["line"], st["col"])
                return False
            emit(st, "eof", None, st["line"], st["col"])
            return True

        if c == "\\":
            skip_ascii(st, i + 1)
            if st["i"] >= n or src[st["i"]] != "\n":
                here_error(st, "stray backslash in program")
            read_newline(st)
            continue

        line = st["line"]
        col = st["col"]
        if c == ",":
            skip_ascii(st, i + 1)
            emit(st, ",", None, line, col)
            return False
        if c == "\"" or c == "'":
            scan_string(st, i, False, False, line, col)
            return False
        if is_ascii_ident(c) and not is_digit(c) or c > "\x7f" and src[i:i + rune_len(st, i)].isalpha():
            nxt = src[i + 1] if i + 1 < n else ""
            if (c == "r" or c == "b") and (nxt == "\"" or nxt == "'"):
                skip_ascii(st, i + 1)
                scan_string(st, i, c == "r", c == "b", line, col)
                return False
            if c == "r" and nxt == "b" and i + 2 < n and (src[i + 2] == "\"" or src[i + 2] == "'"):
                skip_ascii(st, i + 2)
                scan_string(st, i, True, True, line, col)
                return False
            j = i
            ascii = True
            for _ in range(n - i + 1):
                if j >= n:
                    break
                d = src[j]
                if is_ascii_ident(d):
                    j += 1
                elif d > "\x7f" and src[j:j + rune_len(st, j)].isalpha():
                    j += rune_len(st, j)
                    ascii = False
                else:
                    break
            if ascii:
                skip_ascii(st, j)
            else:
                skip_to(st, j)
            word = src[i:j]
            if KEYWORDS.get(word, False):
                emit(st, word, None, line, col)
            else:
                emit(st, "name", word, line, col)
            return False
        if c == "(" or c == "[" or c == "{":
            st["depth"] += 1
            if st["depth"] > 1000:
                here_error(st, "excessive nesting")
            skip_ascii(st, i + 1)
            emit(st, c, None, line, col)
            return False
        if c == ")" or c == "]" or c == "}":
            if st["depth"] == 0:
                here_error(st, "unexpected '" + c + "'")
            st["depth"] -= 1
            skip_ascii(st, i + 1)
            emit(st, c, None, line, col)
            return False
        if is_digit(c) or c == ".":
            scan_number(st)
            return False
        nxt = src[i + 1] if i + 1 < n else ""
        if EQ_OPS.get(c, False):
            if nxt == "=":
                skip_ascii(st, i + 2)
                emit(st, c + "=", None, line, col)
                return False
            if c == "!":
                here_error(st, "unexpected input character '!'")
            if (c == "<" or c == ">" or c == "/") and nxt == c:
                if i + 2 < n and src[i + 2] == "=":
                    skip_ascii(st, i + 3)
                    emit(st, c + c + "=", None, line, col)
                else:
                    skip_ascii(st, i + 2)
                    emit(st, c + c, None, line, col)
                return False
            skip_ascii(st, i + 1)
            emit(st, c, None, line, col)
            return False
        if c == ":" or c == ";" or c == "~":
            skip_ascii(st, i + 1)
            emit(st, c, None, line, col)
            return False
        if c == "*":
            if nxt == "*" or nxt == "=":
                skip_ascii(st, i + 2)
                emit(st, "*" + nxt, None, line, col)
            else:
                skip_ascii(st, i + 1)
                emit(st, "*", None, line, col)
            return False
        ch = src[i:i + rune_len(st, i)] if c > "\x7f" else c
        here_error(st, "unexpected input character '" + ch + "'")
    fail("lexer: no progress")

def lex(src, filename):
    # "\r\n" and "\r" read as "\n" (starlark-go's readRune)
    src = src.replace("\r\n", "\n").replace("\r", "\n")
    st = {
        "src": src,
        "n": len(src),
        "bv": None,  # byte values (byte_at)
        "file": filename,
        "toks": [],
        "i": 0,
        "line": 1,
        "col": 1,
        "line_start": True,
        "indents": [0],
        "depth": 0,  # bracket nesting; newlines inside brackets are ignored
    }
    for _ in range(len(src) + 2):
        if next_token(st):
            break
    return st["toks"]
