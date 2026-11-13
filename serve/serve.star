# serve.star — reactive relations over HTTP (EXTENSIONS.md, "Serving
# relations").
#
# A program of its own, run by bin/starserve (host/serve/main.go), which is
# Go's net/http server and nothing else: it hands every request to handle()
# here, and gives this file the means to run the reactive program and talk
# to it:
#
#   read_file(path), write_file(path, data)
#   spawn(argv)     start the program (once); its standard output and
#                   standard error come back, in order, through recv()
#   send(line)      write a line to the program's standard input
#   recv()          the program's next line of output, or None at its end
#
# The program is run by node host/run.mjs, unchanged but for observers
# added at its end (in a copy, <name>.serve.star next to it), which print
# each relation when it changes, and a counter that marks the end of an
# update's output:
#
#   _serve_sync : ""
#   print("%serve", "order", order)
#   print("%serve", "sync", _serve_sync)
#
# A POST becomes a line of the program's standard input, `x = struct(...)`
# followed by `_serve_sync = "<n>"`; what the program prints up to
# `%serve sync <n>` is that update's output. (<n> names this run of the
# server too: a journal replays the lines of earlier runs.)

load("../compiler/parser.star", "parse_file")
load("../template/template.star", "render")

MARK = "%serve "
SYNC = "_serve_sync"
HTML = {"Content-Type": "text/html; charset=utf-8"}
TEXT = {"Content-Type": "text/plain; charset=utf-8"}

# ------------------------------------------------------------- the program

def _literal(n):
    """The value of expression n if it is a literal, as [value], else None.
    A struct(...) is a dict."""
    k = n["kind"]
    if k == "string" or k == "int":
        return [n["val"]]
    if k == "float":
        return [float(n["val"])]
    if k == "name":
        if n["id"] in ("True", "False", "None"):
            return [{"True": True, "False": False, "None": None}[n["id"]]]
        return None
    if k == "unop" and n["op"] in ("-", "+"):
        x = _literal(n["x"])
        if x == None or type(x[0]) not in ("int", "float"):
            return None
        return [-x[0] if n["op"] == "-" else x[0]]
    if k == "list" or k == "tuple":
        out = []
        for e in n["elems"]:
            x = _literal(e)
            if x == None:
                return None
            out.append(x[0])
        return [tuple(out) if k == "tuple" else out]
    if k == "dict":
        d = {}
        for key, v in n["entries"]:
            kx = _literal(key)
            vx = _literal(v)
            if kx == None or vx == None:
                return None
            d[kx[0]] = vx[0]
        return [d]
    if k == "call" and n["fn"]["kind"] == "name" and n["fn"]["id"] == "struct":
        d = {}
        for a in n["args"]:
            x = _literal(a["value"])
            if a["name"] == None or a["star"] != "" or x == None:
                return None
            d[a["name"]] = x[0]
        return [d]
    return None

def _reads(x, reactive, out):
    """Appends to out the reactive variables that AST x mentions, in order."""
    t = type(x)
    if t == "dict":
        if x.get("kind") == "name":
            if x["id"] in reactive and x["id"] not in out:
                out.append(x["id"])
            return
        for v in x.values():
            _reads(v, reactive, out)
    elif t == "list" or t == "tuple":
        for v in x:
            _reads(v, reactive, out)

def analyze(src, filename):
    """The relations of a program: name -> {"input": the variable a POST
    assigns (or None), "fields": that variable's fields, each (name, type,
    [default] or None)}."""
    defs = {}
    for s in parse_file(src, filename):
        if s["kind"] == "reactive":
            defs[s["name"]] = s
    relations = {}
    for name, s in defs.items():
        if not s.get("relation", False):
            continue
        reads = []
        _reads(s.get("when"), defs, reads)
        _reads(s["value"], defs, reads)
        reads = [r for r in reads if r != name]

        # What a POST assigns: the first struct the relation is computed
        # from, or the relation itself if it is computed from nothing.
        target = None if reads else name
        for r in reads:
            v = defs[r]["value"]
            if not defs[r].get("relation", False) and v["kind"] == "call" and v["fn"]["kind"] == "name" and v["fn"]["id"] == "struct":
                target = r
                break
        fields = []
        if target != None:
            for a in defs[target]["value"]["args"]:
                if a["name"] == None or a["name"] == "id":
                    continue
                default = _literal(a["value"])
                kind = type(default[0]) if default != None else "string"
                fields.append((a["name"], kind if kind in ("int", "float", "bool") else "string", default))
        relations[name] = {"input": target, "fields": fields}
    return relations

def start(config):
    """Starts the program config["program"] (run by the command
    config["run"]; config["id"] names this run) and returns the server's state, for handle()."""
    path = config["program"]
    src = read_file(path)
    relations = analyze(src, path)
    if not src.endswith("\n"):
        src += "\n"
    src += "%s : \"\"\n" % SYNC
    for name in relations:
        src += "print(\"%%serve\", \"%s\", %s)\n" % (name, name)
    src += "print(\"%%serve\", \"sync\", %s)\n" % SYNC
    copy = (path[:-len(".star")] if path.endswith(".star") else path) + ".serve.star"
    write_file(copy, src)
    spawn(config["run"] + [copy])
    server = {
        "relations": relations,
        "values": {name: [] for name in relations},
        "templates": config["templates"],
        "run": config["id"],
        "seq": 0,
    }
    _exchange(server, [])  # the first run's output (and a journal's replay)
    return server

def _exchange(server, lines):
    """Sends lines to the program, and reads what it prints for them: the
    relations that changed (their new values go in server["values"]), and
    the other lines, which are also printed here."""
    server["seq"] += 1
    seq = "%s.%d" % (server["run"], server["seq"])  # unlike any in a journal
    for line in lines:
        send(line)
    send("%s = \"%s\"" % (SYNC, seq))
    changed = {}
    log = []
    for _ in range(1 << 30):
        line = recv()
        if line == None:
            fail("the program has stopped")
        if not line.startswith(MARK):
            log.append(line)
            print(line)
            continue
        name, _, text = line[len(MARK):].partition(" ")
        if name == "sync":
            if text == seq:
                break
            continue
        x = _literal(parse_file(text + "\n", "<" + name + ">")[0]["x"])
        if x == None:
            fail("cannot read the value of %s: %s" % (name, text))
        server["values"][name] = x[0]
        changed[name] = True
    return changed, log

# ------------------------------------------------------------------ values

_DIGITS = "0123456789"

def _digits(s):
    if s == "":
        return False
    for c in s.elems():
        if c not in _DIGITS:
            return False
    return True

def _unsigned(s):
    return s[1:] if s[:1] in ("+", "-") else s

def _convert(kind, s):
    """The value of form text s for a field of type kind: (value, None), or
    (None, what is wrong)."""
    if kind == "string":
        return s, None
    s = s.strip()
    if kind == "bool":
        if s.lower() in ("true", "on", "yes", "1"):
            return True, None
        if s.lower() in ("false", "off", "no", "0", ""):
            return False, None
        return None, "must be true or false"
    if kind == "int":
        if not _digits(_unsigned(s)):
            return None, "must be a whole number"
        return int(s), None
    mantissa, _, exp = s.lower().partition("e")
    whole, dot, frac = _unsigned(mantissa).partition(".")
    ok = (_digits(whole) or (whole == "" and dot != "")) and (_digits(frac) or frac == "") and whole + frac != ""
    if "e" in s.lower():
        ok = ok and _digits(_unsigned(exp)) and len(_unsigned(exp)) <= 3 and int(_unsigned(exp)) <= 300
    if not ok or len(whole) > 300:
        return None, "must be a number"
    return float(s), None

def _is_name(s):
    if s == "" or s[0] in _DIGITS:
        return False
    for c in s.elems():
        if c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789":
            return False
    return True

def _source(v):
    """Value v as an expression of the program's standard input."""
    t = type(v)
    if t == "list":
        return "[" + ", ".join([_source(x) for x in v]) + "]"
    if t == "tuple":
        return "(" + "".join([_source(x) + ", " for x in v]) + ")"
    if t == "dict":
        if len([k for k in v if type(k) != "string" or not _is_name(k)]) == 0:  # a struct
            return "struct(" + ", ".join(["%s = %s" % (k, _source(x)) for k, x in v.items()]) + ")"
        return "{" + ", ".join(["%s: %s" % (_source(k), _source(x)) for k, x in v.items()]) + "}"
    return repr(v)

def _escape(v):
    """Value v for an HTML template: strings escaped, None empty."""
    t = type(v)
    if t == "string":
        return v.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&#39;")
    if t == "NoneType":
        return ""
    if t == "list" or t == "tuple":
        return [_escape(x) for x in v]
    if t == "dict":
        return {k: _escape(x) for k, x in v.items()}
    return v

# ---------------------------------------------------------------- requests

def _page(server, name, vars, status = 200):
    return status, HTML, render(server["templates"] + "/" + name, _escape(vars), read_file)

def _status(status, text):
    return status, TEXT, text + "\n"

def _post(server, req, name, member):
    """A form posted to relation name: for a new member (member None), or
    for an existing one."""
    rel = server["relations"][name]
    form = req["form"]
    if rel["input"] == None:
        return _status(405, name + " is not computed from a struct, so it cannot be posted to")
    error = None
    status = 422
    declared = [f[0] for f in rel["fields"]]

    # What the form sends back unchanged must still be so (say, a hidden
    # field with the member's version).
    if member != None:
        for k in sorted(form):
            if k not in declared and k in member and str(member[k]) != form[k] and error == None:
                error = "%s %s was changed by someone else: %s is now %s, not %s" % (name, member["id"], k, member[k], form[k])
                status = 409
    args = []
    for fname, kind, default in rel["fields"]:
        if fname in form:
            v, bad = _convert(kind, form[fname])
            if bad != None:
                if error == None:
                    error = "%s %s" % (fname, bad)
                continue
        elif fname == "time":
            v = req["time"]
        elif member != None and fname in member:
            v = member[fname]
        elif default != None:
            v = default[0]
        else:
            if error == None:
                error = "%s is missing" % fname
            continue
        args.append("%s = %s" % (fname, _source(v)))
    if error == None:
        if member != None:
            id = member["id"]
        else:
            id = 1 + max([0] + [m["id"] for m in server["values"][name] if type(m.get("id")) == "int"])
        changed, log = _exchange(server, ["%s = struct(%s)" % (rel["input"], ", ".join(["id = " + _source(id)] + args))])
        if name in changed:
            return 303, {"Location": "/" + name}, ""
        errors = [l for l in log if l.startswith("Error") or l.startswith("<stdin>:")]
        error = errors[-1] if errors else "%s did not change" % name
    vars = {"error": error}
    if member != None:
        vars[name] = member
    return _page(server, name + ("_update.html" if member != None else "_create.html"), vars, status)

def handle(server, req):
    """Answers the HTTP request req, a dict of method, path, form (the
    posted fields) and time: (status, headers, body). For each relation
    <name> of the program:

      GET  /<name>        <name>s.html, with <name>: the list of members
      GET  /<name>/new    <name>_create.html
      POST /<name>        adds a member, then redirects to /<name>
      GET  /<name>/<id>   <name>_update.html, with <name>: that member
      POST /<name>/<id>   replaces that member, then redirects to /<name>

    A POST that fails gives its form again, with `error`."""
    parts = [p for p in req["path"].split("/") if p != ""]
    method = req["method"]
    if method == "HEAD":
        method = "GET"
    if len(parts) == 0 or len(parts) > 2 or parts[0] not in server["relations"]:
        return _status(404, "not found: the relations are " + ", ".join(["/" + n for n in server["relations"]]))
    name = parts[0]
    if method not in ("GET", "POST") or (parts[1:] == ["new"] and method != "GET"):
        return _status(405, "method not allowed")
    if len(parts) == 1:
        if method == "POST":
            return _post(server, req, name, None)
        return _page(server, name + "s.html", {name: server["values"][name]})
    if parts[1] == "new":
        return _page(server, name + "_create.html", {})
    for m in server["values"][name]:
        if str(m.get("id")) == parts[1]:
            if method == "POST":
                return _post(server, req, name, m)
            return _page(server, name + "_update.html", {name: m})
    return _status(404, "no %s %s" % (name, parts[1]))
