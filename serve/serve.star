# serve.star — a reactive program over HTTP (EXTENSIONS.md, "Serving
# reactive programs").
#
# A program of its own, run by bin/starserve (host/serve/main.go), which is
# Go's net/http server and nothing else: it hands every request to handle()
# here, and gives this file the means to run the reactive program and talk
# to it:
#
#   read_file(path), write_file(path, data), is_file(path)
#   spawn(argv)     start the program (once); its standard output and
#                   standard error come back, in order, through recv()
#   send(line)      write a line to the program's standard input
#   recv()          the program's next line of output, or None at its end
#
# The program is run by node host/run.mjs, unchanged but for observers
# added at its end (in a copy, <name>.serve.star next to it), which print
# each reactive variable when it changes, and a counter that marks the end
# of an update's output:
#
#   _serve_sync : ""
#   print("%serve", "order", order)
#   print("%serve", "sync", _serve_sync)
#
# A POST to /<x> becomes a line of the program's standard input, `x :
# struct(...)` (or `x : value`), followed by `_serve_sync : "<n>"`; what
# the program prints up to `%serve sync <n>` is that update's output.
# (<n> names this run of the server too: a journal replays the lines of
# earlier runs.)

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

def _kind(default):
    """The type a form field's text is converted to, from the value it has
    in the definition (default: [value], or None if it isn't a literal)."""
    kind = type(default[0]) if default != None else "string"
    return kind if kind in ("int", "float", "bool") else "string"

def _is_block(v):
    return v["kind"] == "call" and v["fn"]["kind"] == "name" and v["fn"]["id"] == "struct"

def analyze(src, filename):
    """The reactive variables of a program: name -> {"relation": is it one,
    "source": does its definition read no other reactive variable (then a
    POST can give it a value), "fields": for a source defined by a struct
    block, its fields, each (name, type, [default] or None) (nested blocks
    left out: they keep the block's values); for another source, None
    (the form's field named like the variable is its value, of "type")}.
    A relation x also has its relation of errors, xError."""
    defs = {}
    for s in parse_file(src, filename):
        if s["kind"] == "reactive":
            defs[s["name"]] = s
    out = {}
    for name, s in defs.items():
        reads = []
        _reads(s.get("when"), defs, reads)
        _reads(s["value"], defs, reads)
        reads = [r for r in reads if r != name]
        info = {"relation": s.get("relation", False), "source": not reads and s.get("when") == None,
                "fields": None, "type": _kind(_literal(s["value"]))}
        if _is_block(s["value"]):
            info["fields"] = [(a["name"], _kind(_literal(a["value"])), _literal(a["value"]))
                              for a in s["value"]["args"]
                              if a["name"] != None and a["name"] != "id" and not _is_block(a["value"])]
        out[name] = info
        if info["relation"]:
            out[name + "Error"] = {"relation": True, "source": True, "fields": None, "type": "string"}
    return out

def start(config):
    """Starts the program config["program"] (run by the command
    config["run"]; config["id"] names this run) and returns the server's state, for handle().
    config["extra"] (optional): implicit relations of the program to
    observe as well (serve/grpc.star's), each with its relation of errors."""
    path = config["program"]
    src = read_file(path)
    reactives = analyze(src, path)
    for name in config.get("extra", []):
        if name not in reactives:
            reactives[name] = {"relation": True, "source": True, "fields": None, "type": "string"}
            reactives[name + "Error"] = {"relation": True, "source": True, "fields": None, "type": "string"}
    if not src.endswith("\n"):
        src += "\n"
    src += "%s : \"\"\n" % SYNC
    for name in reactives:
        src += "print(\"%%serve\", \"%s\", %s)\n" % (name, name)
    src += "print(\"%%serve\", \"sync\", %s)\n" % SYNC
    copy = (path[:-len(".star")] if path.endswith(".star") else path) + ".serve.star"
    write_file(copy, src)
    spawn(config["run"] + [copy])
    server = {
        "reactives": reactives,
        "values": {name: [] if r["relation"] else None for name, r in reactives.items()},
        "templates": config["templates"],
        "run": config["id"],
        "seq": 0,
        "changed": {},  # the variables changed since grpc.star last looked
    }
    _exchange(server, [])  # the first run's output (and a journal's replay)
    return server

def _exchange(server, lines):
    """Sends lines to the program, and reads what it prints for them: the
    reactive variables that changed (their new values go in server["values"]), and
    the other lines, which are also printed here."""
    server["seq"] += 1
    seq = "%s.%d" % (server["run"], server["seq"])  # unlike any in a journal
    for line in lines:
        send(line)
    send("%s : \"%s\"" % (SYNC, seq))
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
        server["values"][name] = x[0] if x != None else text  # (not data: its repr)
        changed[name] = True
    server["changed"].update(changed)
    return changed, log

def exchange(server, lines):
    """_exchange, for serve/grpc.star."""
    return _exchange(server, lines)

def source(v):
    """_source, for serve/grpc.star."""
    return _source(v)

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

def _shown(v):
    """Value v for a template, which can't substitute None: it is empty."""
    t = type(v)
    if t == "NoneType":
        return ""
    if t == "list" or t == "tuple":
        return [_shown(x) for x in v]
    if t == "dict":
        return {k: _shown(x) for k, x in v.items()}
    return v

# ---------------------------------------------------------------- requests

def _template(server, path):
    """The template file a GET of path renders: /x is x, or x.html if
    there is no x; / is index.html. None if there is none (or path isn't
    one plain file name)."""
    name = path.strip("/")
    if name == "":
        name = "index.html"
    if "/" in name or name.startswith("."):
        return None
    for n in ([name] if name.endswith(".html") else [name, name + ".html"]):
        if is_file(server["templates"] + "/" + n):
            return n
    return None

# Files served as they are (not templates), by extension.
STATIC = {".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".txt": TEXT["Content-Type"]}

def _static(server, path):
    """A GET of a file in the templates' directory with an extension in
    STATIC: the file as it is; else None."""
    name = path.strip("/")
    if "/" in name or name.startswith("."):
        return None
    for ext, ctype in STATIC.items():
        if name.endswith(ext) and is_file(server["templates"] + "/" + name):
            return 200, {"Content-Type": ctype}, read_file(server["templates"] + "/" + name)
    return None

def _vars(server, query):
    """A page's variables: every reactive variable (a relation is its list
    of members), except that a query parameter named like a relation
    (?order=3) makes it the member with that id. Returns (vars, None), or
    (None, what is missing)."""
    vars = dict(server["values"])
    for k, v in query.items():
        r = server["reactives"].get(k)
        if r == None or not r["relation"]:
            continue
        found = [m for m in server["values"][k] if type(m) == "dict" and str(m.get("id")) == v]
        if not found:
            return None, "no %s %s" % (k, v)
        vars[k] = found[-1]
    return vars, None

def _page(server, name, vars, status = 200):
    return status, HTML, render(server["templates"] + "/" + name, _shown(vars), read_file)

def _status(status, text, headers = {}):
    return status, dict(TEXT, **headers), text + "\n"

def _back(req):
    """Where a POST's answer goes: the page it came from (the Referer's
    path, if it is of this server), else /."""
    ref = req.get("referer", "")
    host = req.get("host", "")
    for prefix in ("http://" + host, "https://" + host):
        if host != "" and ref.startswith(prefix + "/"):
            return ref[len(prefix):]
    return "/"

def _post(server, req, name):
    """A form posted to reactive variable name, one whose definition reads
    no other (a source). For a struct block, the form's fields named like
    the block's are converted to their types; `id`, if given, picks the
    member of a relation it replaces (whose other fields are kept), and a
    field `time` the form doesn't have is the time of the request. Any other
    source takes the form field named like it. A field `<relation>.<field>`
    is a precondition: the relation's member with the posted id must still
    have that value (else 409). Then redirects back (_back), or, if it
    fails, renders the page it came from with `error` (422, or 409)."""
    rel = server["reactives"][name]
    form = req["form"]
    error = None
    status = 422
    id = form.get("id")
    if id != None:
        v, bad = _convert("int", id)
        id = v if bad == None else id
    member = None
    if rel["relation"] and id != None:
        for m in server["values"][name]:
            if type(m) == "dict" and m.get("id") == id:
                member = m
    for k in sorted(form):
        r, dot, f = k.partition(".")
        if dot == "" or error != None:
            continue
        if r not in server["reactives"] or not server["reactives"][r]["relation"]:
            error = "%s is not a relation" % r
            continue
        cur = [m for m in server["values"][r] if type(m) == "dict" and m.get("id") == id]
        if not cur or f not in cur[-1] or str(cur[-1][f]) != form[k]:
            error = "%s %s was changed by someone else: %s is now %s, not %s" % (
                r, id, f, cur[-1][f] if cur and f in cur[-1] else "gone", form[k])
            status = 409
    if rel["fields"] == None:
        if name not in form and error == None:
            error = "%s is missing" % name
        elif error == None:
            v, bad = _convert(rel["type"], form[name])
            if bad != None:
                error = "%s %s" % (name, bad)
            line = "%s : %s" % (name, _source(v))
    else:
        args = ["id = " + _source(id)] if id != None else []
        for fname, kind, _ in rel["fields"]:
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
            else:
                continue  # (the block's value)
            args.append("%s = %s" % (fname, _source(v)))
        line = "%s : struct(%s)" % (name, ", ".join(args))
    if error == None:
        _, log = _exchange(server, [line])
        errors = [l for l in log if l.startswith("<stdin>:")]
        if not errors:
            return 303, {"Location": _back(req)}, ""
        error = errors[-1]
    back = _back(req)
    page = _template(server, back.partition("?")[0])
    if page == None:
        return _status(status, error)
    vars, _ = _vars(server, _query(back.partition("?")[2]))
    vars = vars if vars != None else dict(server["values"])
    vars["error"] = error
    return _page(server, page, vars, status)

def _query(text):
    """The parameters of a query string (already decoded by the host for
    the request's own; the Referer's are taken as they are)."""
    out = {}
    for part in text.split("&"):
        k, eq, v = part.partition("=")
        if k != "":
            out[k] = v
    return out

def handle(server, req):
    """Answers the HTTP request req, a dict of method, path, query, form
    (the posted fields), referer, host and time: (status, headers, body).

      GET  /<page>     the template <page> (or <page>.html; / is
                       index.html), with every reactive variable (_vars)
      POST /<name>     a new value for reactive variable <name>, if its
                       definition reads no other one (_post); else 405

    Anything else is 404, or 405 for another method."""
    path = req["path"]
    method = req["method"]
    if method == "HEAD":
        method = "GET"
    if method == "POST":
        name = path.strip("/")
        r = server["reactives"].get(name)
        if r == None:
            return _status(404, "not found: POST to a reactive variable: " +
                           ", ".join(["/" + n for n, x in sorted(server["reactives"].items()) if x["source"]]))
        if not r["source"]:
            allow = "GET, HEAD" if _template(server, path) != None else ""
            return _status(405, "%s is computed from other reactive variables: it can't be posted to" % name, {"Allow": allow})
        return _post(server, req, name)
    if method != "GET":
        return _status(405, "method not allowed", {"Allow": "GET, HEAD, POST"})
    static = _static(server, path)
    if static != None:
        return static
    page = _template(server, path)
    if page == None:
        return _status(404, "not found: no template " + path.strip("/"))
    vars, missing = _vars(server, req.get("query", {}))
    if vars == None:
        return _status(404, missing)
    return _page(server, page, vars)
