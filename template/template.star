# A small template language, in plain Starlark.
#
# This file is self-contained: it loads nothing, and uses no recursion, no
# while loops and no host builtins, so it runs in any Starlark (starlark-go,
# Bazel, Buck2, ...). Templates are read through a function or dict that the
# caller supplies. See README.md for the language.
#
#     load("template.star", "render")
#     html = render("pages/index.html", {"title": "Hi"}, read_file)
#
# A template is tokenized into a flat list (text, var, for/endfor, if/endif,
# include, alt/endalt), the block tokens are paired up into a jump table, and a
# small loop with an explicit stack of include frames walks the list.

_ALPHA = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
_IDENT_START = _ALPHA + "_"
_IDENT = _IDENT_START + "0123456789"
_WS = " \t\r\n"
_RESERVED = ["for", "endfor", "if", "endif", "include"]
_INCLUDE_TAGS = ["div", "span", "section"]
_STEPS = 1 << 30  # bound of the render loop (Starlark has no while)

# ---------------------------------------------------------------- scanning

def _ident_end(src, i, n):
    """The index after the identifier at src[i:n], or i if there is none."""
    if i >= n or src[i] not in _IDENT_START:
        return i
    for j in range(i + 1, n):
        if src[j] not in _IDENT:
            return j
    return n

def _path_end(src, i, n):
    """The index after the dotted name (a.b.c) at src[i:n], or i."""
    e = _ident_end(src, i, n)
    if e == i:
        return i
    for _ in range(n):
        if e >= n or src[e] != ".":
            break
        e2 = _ident_end(src, e + 1, n)
        if e2 == e + 1:
            break
        e = e2
    return e

def _valid_path(s):
    return len(s) > 0 and _path_end(s, 0, len(s)) == len(s)

def _skip_ws(src, i, n):
    for j in range(i, n):
        if src[j] not in _WS:
            return j
    return n

def _parse_tag(src, i, n):
    """Parses the opening tag at src[i] == "<".

    Returns None if there is none, else a dict: name (lowercase), end (index
    after ">"), selfclose, and attrs, each a dict of name, value (None
    without "="), start (of the whitespace before the attribute) and end.
    """
    if i + 1 >= n or src[i + 1] not in _ALPHA:
        return None
    j = n
    for k in range(i + 1, n):
        if src[k] in _WS or src[k] == "/" or src[k] == ">":
            j = k
            break
    name = src[i + 1:j].lower()
    attrs = []
    for _ in range(n):
        start = j
        j = _skip_ws(src, j, n)
        if j >= n:
            return None
        if src[j] == ">":
            return {"name": name, "attrs": attrs, "end": j + 1, "selfclose": False}
        if src[j] == "/":
            if j + 1 < n and src[j + 1] == ">":
                return {"name": name, "attrs": attrs, "end": j + 2, "selfclose": True}
            j += 1
            continue
        if src[j] == "=":
            j += 1
            continue
        a = j
        j = n
        for k in range(a, n):
            if src[k] in _WS or src[k] == "=" or src[k] == ">" or src[k] == "/":
                j = k
                break
        aname = src[a:j]
        value = None
        v = _skip_ws(src, j, n)
        if v < n and src[v] == "=":
            v = _skip_ws(src, v + 1, n)
            if v < n and (src[v] == '"' or src[v] == "'"):
                q = src.find(src[v], v + 1)
                if q < 0:
                    return None
                value = src[v + 1:q]
                j = q + 1
            else:
                j = n
                for k in range(v, n):
                    if src[k] in _WS or src[k] == ">":
                        j = k
                        break
                if j < n and src[j] == ">" and j > v and src[j - 1] == "/":
                    j -= 1  # a=b/> : self-closing
                value = src[v:j]
        attrs.append({"name": aname, "value": value, "start": start, "end": j})
    return None

def _find_close(src, name, i, n):
    """Finds the </name> matching a <name> whose opening tag ends at i.

    Returns (start, end) of the closing tag, or None.
    """
    depth = 1
    for _ in range(n):
        lt = src.find("<", i)
        if lt < 0:
            return None
        if src[lt + 1:lt + 2] == "/":
            e = lt + 2 + len(name)
            if src[lt + 2:e].lower() == name and (e >= n or src[e] in _WS or src[e] == ">"):
                gt = src.find(">", e)
                if gt < 0:
                    return None
                depth -= 1
                if depth == 0:
                    return (lt, gt + 1)
                i = gt + 1
            else:
                i = lt + 2
        else:
            tag = _parse_tag(src, lt, n)
            if tag == None:
                i = lt + 1
            else:
                if tag["name"] == name and not tag["selfclose"]:
                    depth += 1
                i = tag["end"]
    return None

# -------------------------------------------------------------- tokenizing

def _line(st, pos):
    """The 1-based line number of src[pos]."""
    if pos < st["lpos"]:
        return 1 + st["src"].count("\n", 0, pos)
    st["lno"] += st["src"].count("\n", st["lpos"], pos)
    st["lpos"] = pos
    return st["lno"]

def _fail(st, pos, msg):
    fail("%s:%d: %s" % (st["name"], _line(st, pos), msg))

def _text(st, a, b):
    """Appends the tokens of the plain text src[a:b]: text and variables."""
    src = st["src"]
    toks = st["toks"]
    i = a
    for _ in range(b - a + 1):
        d = src.find("$", i, b)
        if d < 0:
            break
        nxt = src[d + 1] if d + 1 < b else ""
        if nxt == "$":
            toks.append({"k": "text", "s": src[i:d + 1]})
            i = d + 2
            continue
        if nxt == "{":
            c = src.find("}", d + 2, b)
            if c < 0 or not _valid_path(src[d + 2:c]):
                _fail(st, d, "${ must be followed by a variable name and } (write $$ for a literal $)")
            e = c + 1
            path = src[d + 2:c].split(".")
        else:
            e = _path_end(src, d + 1, b)
            if e == d + 1:  # a $ that starts no name is just a $
                toks.append({"k": "text", "s": src[i:d + 1]})
                i = d + 1
                continue
            path = src[d + 1:e].split(".")
            if path[0] in _RESERVED:
                _fail(st, d, "$%s must be alone on its line, or an HTML attribute with a value" % path[0])
        if d > i:
            toks.append({"k": "text", "s": src[i:d]})
        toks.append({"k": "var", "path": path, "line": _line(st, d)})
        i = e
    if b > i:
        toks.append({"k": "text", "s": src[i:b]})

def _check_path(st, pos, what, s):
    if not _valid_path(s):
        _fail(st, pos, "%s takes a variable name, not %r" % (what, s))
    return s.split(".")

def _check_file(st, pos, what, s):
    if "/" in s or "\\" in s or s == "." or s == "..":
        _fail(st, pos, "%s takes the name of a file in the template's directory, not %r" % (what, s))
    return s

def _directive(st, pos, kind, words, form, inline, nl):
    """The token of a $for, $if or $include with the given arguments."""
    line = _line(st, pos)
    if kind == "include":
        if len(words) != 1:
            _fail(st, pos, "$include takes one file name")
        return {"k": "include", "file": _check_file(st, pos, "$include", words[0]), "line": line, "inline": inline, "nl": nl}
    if len(words) == 0:
        _fail(st, pos, "$%s takes a variable name" % kind)
    path = _check_path(st, pos, "$" + kind, words[0])
    if kind == "for":
        if len(words) != 1:
            _fail(st, pos, "$for takes only a variable name")
        return {"k": "for", "path": path, "line": line, "form": form}
    if len(words) == 1:
        return {"k": "if", "path": path, "line": line, "form": form}
    files = [_check_file(st, pos, "$if", w) for w in words[1:]]
    return {"k": "alt", "path": path, "files": files, "line": line, "inline": inline, "nl": nl}

def _line_directive(st, pos, words, nl):
    kind = words[0][1:]
    if kind == "endfor" or kind == "endif":
        if len(words) != 1:
            _fail(st, pos, "$%s takes no arguments" % kind)
        return {"k": kind, "line": _line(st, pos), "form": "line"}
    return _directive(st, pos, kind, words[1:], "line", False, nl)

def _directive_attrs(st, tag, pos):
    """The directive attributes of a tag: None, or [the $for, $if or
    $include attribute, the $else attribute or None]."""
    found = None
    els = None
    for a in tag["attrs"]:
        if a["name"] in ("$for", "$if", "$include", "$else"):
            if a["value"] == None:
                _fail(st, pos, "the %s attribute of <%s> needs a value" % (a["name"], tag["name"]))
            if a["name"] == "$else":
                if els != None:
                    _fail(st, pos, "<%s> has two $else attributes" % tag["name"])
                els = a
            elif found != None:
                _fail(st, pos, "<%s> has both %s and %s" % (tag["name"], found["name"], a["name"]))
            else:
                found = a
    if els != None and (found == None or found["name"] != "$if"):
        _fail(st, pos, "the $else attribute of <%s> needs an $if attribute" % tag["name"])
    if found == None:
        return None
    return [found, els]

def _html_directive(st, tag, attrs, p, t0, closes):
    """Handles the tag at p, which has the directive attributes attrs.

    Returns the new (scan position, start of pending text).
    """
    src = st["src"]
    n = len(src)
    attr, els = attrs
    kind = attr["name"][1:]
    words = attr["value"].split()
    name = tag["name"]
    if kind == "include" and name not in _INCLUDE_TAGS:
        _fail(st, p, "$include can be an attribute of <div>, <span> or <section>, not <%s>" % name)
    if kind == "if" and len(words) > 1:
        _fail(st, p, "the $if attribute takes only a variable name: alternatives go in an $else attribute")

    # An $include always replaces its element; so does an $if with $else
    # that has no content to fall back to.
    whole = kind == "include" or (els != None and tag["selfclose"])
    desc = "<%s %s>" % (name, attr["name"])

    # The end of the element.
    cs = tag["end"]
    e = tag["end"]
    if not tag["selfclose"]:
        close = _find_close(src, name, tag["end"], n)
        if close == None:
            _fail(st, p, "%s has no closing </%s>" % (desc, name))
        cs, e = close
        if whole and src[tag["end"]:cs].strip() != "":
            _fail(st, p, "%s is replaced as a whole, so it must be empty" % desc)
    elif not whole:
        _fail(st, p, "%s needs a closing </%s>" % (desc, name))
    if closes and e > closes[-1][2]:
        _fail(st, p, "%s is not closed inside the element that contains it" % desc)

    # An element that has its lines to itself takes them with it, so that
    # one that expands to nothing leaves no blank line.
    ls = src.rfind("\n", 0, p) + 1
    nl = src.find("\n", e)
    eol = nl if nl >= 0 else n
    own = t0 <= ls and src[ls:p].strip() == "" and src[e:eol].strip() == ""
    first = ls if own else p
    last = e
    if own:
        last = eol + 1 if nl >= 0 else n

    _text(st, t0, first)
    if els != None:
        files = [_check_file(st, p, "$else", w) for w in els["value"].split()]
        if not files:
            _fail(st, p, "the $else attribute takes a list of file names")
        tok = {
            "k": "alt",
            "path": _check_path(st, p, "$if", attr["value"].strip()),
            "files": files,
            "line": _line(st, p),
            "inline": not own,
            "nl": own and nl >= 0,
            "block": not whole,
            "form": "html",
        }
    else:
        tok = _directive(st, p, kind, words, "html", not own, own and nl >= 0)
    tok["desc"] = desc
    st["toks"].append(tok)
    if whole:
        return (last, last)

    # The opening tag, without the directive attributes.
    cut = [attr]
    if els != None:
        cut = [attr, els] if attr["start"] < els["start"] else [els, attr]
    a = first
    for c in cut:
        _text(st, a, c["start"])
        a = c["end"]
    closes.append([last, {"k": "end" + tok["k"], "line": _line(st, cs), "form": "html"}, cs])
    return (tag["end"], a)

def _tokenize(name, src):
    n = len(src)
    st = {"name": name, "src": src, "toks": [], "lpos": 0, "lno": 1}
    toks = st["toks"]
    closes = []  # open HTML $for/$if elements: [end position, end token, start of closing tag]
    i = 0
    t0 = 0  # start of the text not yet tokenized
    for _ in range(3 * n + 3):
        if closes and closes[-1][0] == i:
            _text(st, t0, i)
            t0 = i
            toks.append(closes.pop()[1])
            continue
        if i >= n:
            break
        if i == 0 or src[i - 1] == "\n":
            nl = src.find("\n", i)
            eol = nl if nl >= 0 else n
            nxt = nl + 1 if nl >= 0 else n
            s = src[i:eol].strip()
            if s.startswith("$"):
                words = s.split()
                if words[0][1:] in _RESERVED:
                    if closes and closes[-1][0] < nxt:
                        _fail(st, i, "%s shares its line with a closing tag" % words[0])
                    _text(st, t0, i)
                    toks.append(_line_directive(st, i, words, nl >= 0))
                    i = nxt
                    t0 = nxt
                    continue
        if src[i] == "<":
            tag = _parse_tag(src, i, n)
            attrs = _directive_attrs(st, tag, i) if tag != None else None
            if attrs != None:
                i, t0 = _html_directive(st, tag, attrs, i, t0, closes)
            else:
                i += 1
            continue
        j = src.find("<", i)
        if j < 0:
            j = n
        nl = src.find("\n", i)
        if nl >= 0 and nl + 1 < j:
            j = nl + 1
        if closes and closes[-1][0] < j:
            j = closes[-1][0]
        i = j
    _text(st, t0, n)
    return toks

def _describe(tok):
    if tok["form"] == "html":
        return tok["desc"] if "desc" in tok else "a closing tag"
    return "$" + tok["k"]

def _compile(name, src):
    """Tokenizes a template and pairs up its block tokens."""
    toks = _tokenize(name, src)
    jump = {}
    stack = []
    for i, tok in enumerate(toks):
        k = tok["k"]
        if k == "for" or k == "if" or (k == "alt" and tok.get("block")):
            stack.append(i)
        elif k == "endfor" or k == "endif" or k == "endalt":
            if not stack:
                fail("%s:%d: $%s without $%s" % (name, tok["line"], k, k[3:]))
            oi = stack.pop()
            o = toks[oi]
            if o["k"] != k[3:] or o["form"] != tok["form"]:
                fail("%s:%d: %s at line %d is closed by %s" % (name, tok["line"], _describe(o), o["line"], _describe(tok)))
            jump[oi] = i
    if stack:
        o = toks[stack[-1]]
        fail("%s:%d: %s has no $end%s" % (name, o["line"], _describe(o), o["k"]))
    return {"toks": toks, "jump": jump}

# --------------------------------------------------------------- rendering

def _lookup(path, bindings, vars):
    """Looks a dotted name up. Returns (found, value)."""
    cur = vars
    rest = path
    for k in range(len(bindings) - 1, -1, -1):
        bp = bindings[k][0]
        if path[:len(bp)] == bp:
            cur = bindings[k][1]
            rest = path[len(bp):]
            break
    for seg in rest:
        if type(cur) == "dict":
            if seg not in cur:
                return (False, None)
            cur = cur[seg]
        elif type(cur) == "struct" and hasattr(cur, seg):
            cur = getattr(cur, seg)
        else:
            return (False, None)
    return (True, cur)

def _choose(where, tok, found, v):
    """The file that an $if with alternatives includes, or None."""
    files = tok["files"]
    t = type(v)
    if not found or v == None or (t == "string" and v == ""):
        return None
    if t == "bool":
        if v:
            return files[0]
        return files[1] if len(files) > 1 else None
    if t == "int":
        if v < 0 or v >= len(files):
            fail("%s: $if %s is %d, but there are %d alternatives" % (where, ".".join(tok["path"]), v, len(files)))
        return files[v]
    if t == "string":
        for f in files:
            if v == f or v == f.rpartition(".")[0]:
                return f
        fail("%s: $if %s is %r, which is none of %s" % (where, ".".join(tok["path"]), v, " ".join(files)))
    fail("%s: $if %s is a %s: alternatives are chosen by a string, an int or a bool" % (where, ".".join(tok["path"]), t))

def _read(read, path, where):
    if type(read) == "dict":
        if path not in read:
            fail("%sno template %r" % (where, path))
        return read[path]
    if read == None:
        fail("%scannot include %r: no read function was given" % (where, path))
    return read(path)

def _load(cache, read, path, where):
    if path not in cache:
        cache[path] = _compile(path, _read(read, path, where))
    return cache[path]

def _enter(frames, cache, read, cur, file, where, out, inline, nl):
    path = cur["dir"] + file
    for f in frames:
        if f["name"] == path:
            fail("%s: %s includes itself" % (where, path))
    prog = _load(cache, read, path, where + ": ")
    frames.append({"name": path, "dir": cur["dir"], "prog": prog, "pc": 0, "loops": [], "mark": len(out), "inline": inline, "nl": nl})

def _leave(f, out):
    """Fixes the last newline of what an include wrote."""
    if len(out) <= f["mark"]:
        return
    last = out[-1]
    if f["inline"]:  # inside a line: drop the file's final newline
        if last.endswith("\r\n"):
            last = last[:-2]
        elif last.endswith("\n"):
            last = last[:-1]
        if last == "":
            out.pop()
        else:
            out[-1] = last
    elif f["nl"] and not last.endswith("\n"):  # in place of a line: end it
        out.append("\n")

def _run(name, vars, read, cache):
    out = []
    bindings = []  # innermost last: [path of a $for, its current item]
    root = _load(cache, read, name, "")
    frames = [{"name": name, "dir": name[:name.rfind("/") + 1], "prog": root, "pc": 0, "loops": []}]
    for _ in range(_STEPS):
        if not frames:
            break
        f = frames[-1]
        toks = f["prog"]["toks"]
        pc = f["pc"]
        if pc >= len(toks):
            frames.pop()
            if frames:
                _leave(f, out)
            continue
        tok = toks[pc]
        k = tok["k"]
        f["pc"] = pc + 1
        if k == "text":
            out.append(tok["s"])
            continue
        where = "%s:%d" % (f["name"], tok["line"])
        if k == "var":
            found, v = _lookup(tok["path"], bindings, vars)
            if not found:
                fail("%s: $%s is not defined" % (where, ".".join(tok["path"])))
            t = type(v)
            if t != "string":
                if t not in ("int", "float", "bool"):
                    fail("%s: $%s is a %s: only strings and numbers can be substituted" % (where, ".".join(tok["path"]), t))
                v = str(v)
            if v != "":
                out.append(v)
        elif k == "if":
            found, v = _lookup(tok["path"], bindings, vars)
            if not (found and v):
                f["pc"] = f["prog"]["jump"][pc] + 1
        elif k == "for":
            found, v = _lookup(tok["path"], bindings, vars)
            if not found:
                fail("%s: $for %s: not defined" % (where, ".".join(tok["path"])))
            if type(v) not in ("list", "tuple"):
                fail("%s: $for %s: it is a %s, not a list" % (where, ".".join(tok["path"]), type(v)))
            if len(v) == 0:
                f["pc"] = f["prog"]["jump"][pc] + 1
            else:
                items = list(v)
                f["loops"].append([pc, items, 0])
                bindings.append([tok["path"], items[0]])
        elif k == "endfor":
            loop = f["loops"][-1]
            loop[2] += 1
            if loop[2] < len(loop[1]):
                bindings[-1][1] = loop[1][loop[2]]
                f["pc"] = loop[0] + 1
            else:
                f["loops"].pop()
                bindings.pop()
        elif k == "include":
            _enter(frames, cache, read, f, tok["file"], where, out, tok["inline"], tok["nl"])
        elif k == "alt":
            found, v = _lookup(tok["path"], bindings, vars)
            file = _choose(where, tok, found, v)
            if file != None:
                if tok.get("block"):  # skip the content: it is the fallback
                    f["pc"] = f["prog"]["jump"][pc] + 1
                _enter(frames, cache, read, f, file, where, out, tok["inline"], tok["nl"])
    if frames:
        fail("%s: the template is too big to render" % name)
    return "".join(out)

def render(name, vars, read):
    """Renders the template file `name`.

    Args:
      name: the template's path, as `read` understands it.
      vars: a dict (or struct) of the template's variables. Values may be
        strings, numbers, bools, lists/tuples (for $for) and nested
        dicts/structs (reached as $a.b).
      read: how templates are read: a function from a path to the file's
        contents, or a dict from paths to contents. An included file is
        read by the including template's directory + "/" + its name.

    Returns:
      The expanded text. Errors fail() with "file:line: message".
    """
    return _run(name, vars, read, {})

def render_string(src, vars, read = None, name = "<string>"):
    """Renders the template text `src`.

    `name` is used in error messages, and its directory part (none by
    default) is where included files are read from; `read` (see render) is
    only needed if the template includes files.
    """
    return _run(name, vars, read, {name: _compile(name, src)})
