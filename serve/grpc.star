# grpc.star — a reactive program's gRPC server and client (EXTENSIONS.md,
# "gRPC"), on top of serve.star.
#
# bin/starserve (host/serve/main.go) does the transport, with grpc-go, and
# converts messages to the program's values and back, from the descriptor
# set; everything about the program is here. For each unary method M of a
# service in the descriptor set:
#
#   served (--grpc=ADDR), if the program defines M_response:
#     a request is a new member of the relation M_request, a struct of the
#     message's fields (sent on the program's standard input); the answer
#     is the member of M_response whose id is the request's (in that update
#     or a later one: an implicit id carries through relations), or, if it
#     is in the request's own update, the member it added; a member of
#     M_responseError for the request (its M_response_id) is an error.
#   called (--grpc_target=...), if the program defines M_call:
#     each new member of M_call (or new value, for a lone variable) is a
#     request (of its fields that the request message has); the answer is
#     a new member of M_reply: the call's other fields (its context, so
#     that what goes on from the reply needs to read nothing but it),
#     then the reply's fields, M_call_id (the call's id) and id (the
#     call's, unless the reply has a field id); a call that fails is a
#     member of M_failure instead: the call's fields too, M_call_id, code
#     and message. Either is only sent if the program reads it.
#
# Go calls, under one lock with serve.star's handle():
#   plan(path, methods, targets)   which methods the program serves and calls
#   setup(server, plan)            after serve.star's start()
#   request(server, m, fields)     a request for served method m
#   reply(server, m, id, fields, failure)   the answer to a call
#   after(server)                  what the updates since the last look did:
#                                  answers to requests, and new calls
# fields: the message as [(name, source)] (host/serve/main.go writes them).

load("../compiler/parser.star", "parse_file")
load("serve.star", "exchange", "source")

def _names(x, out):
    """The names that AST x reads."""
    t = type(x)
    if t == "dict":
        if x.get("kind") == "name":
            out[x["id"]] = True
            return
        for v in x.values():
            _names(v, out)
    elif t == "list" or t == "tuple":
        for v in x:
            _names(v, out)

def plan(path, methods, targets):
    """Which of methods (each {name, path, input, output, streaming}) the
    program at path serves (it defines name_response) and calls (it
    defines name_call; targets: is there an address to call it at).
    Returns {served: [method], called: [method], extra: the implicit
    relations to observe, errors: [text]}."""
    stmts = parse_file(read_file(path), path)
    defined = {s["name"]: True for s in stmts if s["kind"] == "reactive"}
    read = {}
    _names(stmts, read)
    out = {"served": [], "called": [], "extra": [], "errors": []}
    seen = {}
    for m in methods:
        n = m["name"]
        serves = n + "_response" in defined
        calls = n + "_call" in defined
        if not serves and not calls:
            continue
        if n in seen:
            out["errors"].append("two services have a method %s (%s, %s): the program's %s_... names can't tell them apart" % (n, seen[n], m["path"], n))
            continue
        seen[n] = m["path"]
        if m["streaming"]:
            out["errors"].append("%s is a streaming method: only unary methods are served and called" % m["path"])
            continue
        if serves:
            out["served"].append(m)
            if n + "_request" not in defined:
                out["extra"].append(n + "_request")
        if calls:
            if not targets.get(m["service"], targets.get("", "")):
                out["errors"].append("%s_call: no address to call %s at (--grpc_target=ADDR, or %s=ADDR)" % (n, m["service"], m["service"]))
                continue
            out["called"].append(m)
            for x in (n + "_reply", n + "_failure"):
                if x in read and x not in defined:
                    out["extra"].append(x)
    out["reads"] = [x for x in read if x in defined or x in out["extra"]]
    return out

def _members(v):
    """The values of a reactive variable: a relation's members, a lone
    variable's value (if it has one)."""
    if type(v) == "list":
        return v
    return [] if v == None else [v]

def _seen(v):
    return (v.get("id"), repr(v)) if type(v) == "dict" else (None, repr(v))

def setup(server, plan):
    """Remembers the plan in server; the calls already made (the first run,
    a journal's replay) aren't made again."""
    sent = {}
    for m in plan["called"]:
        sent[m["name"]] = {_seen(v): True for v in _members(server["values"].get(m["name"] + "_call"))}
    server["grpc"] = {
        "served": {m["name"]: m for m in plan["served"]},
        "called": {m["name"]: m for m in plan["called"]},
        "reads": {x: True for x in plan["reads"]},
        "sent": sent,
        "waiting": {},  # (method, request id) -> True
        "ready": [],  # answers found: (method, id, value, error)
    }
    server["changed"] = {}

def _struct(fields):
    return "struct(" + ", ".join(["%s = %s" % (n, v) for n, v in fields]) + ")"

def _errors(log):
    """The errors the program printed for a line of input it refused."""
    return [l for l in log if l.startswith("<stdin>:")]

def request(server, m, fields):
    """Sends a request for served method m (its fields, from the message).
    Returns the request's id, or (code, message) if the program refuses
    it."""
    g = server["grpc"]
    rel = m + "_request"
    changed, log = exchange(server, ["%s : %s" % (rel, _struct(fields))])
    errors = _errors(log)
    if rel not in changed or errors:
        why = errors[-1] if errors else "the program didn't take the request"
        code = "INVALID_ARGUMENT"
        for x in sorted(changed):
            # (an update that fails gives a member to the relation of
            # errors of the variable that would have been None)
            e = _members(server["values"].get(x)) if x.endswith("Error") else []
            if e and type(e[-1]) == "dict" and not errors:
                f = e[-1].get("field")
                why = "%s would be None" % (x[:-len("Error")] + ("." + f if f else ""))
                if x == m + "_responseError":
                    code = "INTERNAL"  # (the answer, not the request)
        return (code, why)
    members = _members(server["values"][rel])
    id = members[-1].get("id") if members and type(members[-1]) == "dict" else None
    g["waiting"][(m, id)] = True
    resp = m + "_response"
    if resp in changed:
        vals = _members(server["values"][resp])
        if vals and not [v for v in vals if type(v) == "dict" and v.get("id") == id]:
            # (an explicit id: the member this update added)
            g["ready"].append((m, id, vals[-1], None))
            g["waiting"].pop((m, id))
    return id

def forget(server, m, id):
    """The request (m, id) is no longer waited for (its deadline passed)."""
    server["grpc"]["waiting"].pop((m, id), None)

def reply(server, m, id, fields, failure, call):
    """The answer to call id of method m (call: its value): the reply's
    fields, or failure, (code, message), if the call failed. Sent as a
    member of m_reply or m_failure, if the program reads it, with the
    call's fields first (the reply's replace those of the same name)."""
    g = server["grpc"]
    if failure != None:
        name = m + "_failure"
        fields = [("code", repr(failure[0])), ("message", repr(failure[1]))]
    else:
        name = m + "_reply"
    if name not in g["reads"]:
        return
    given = {f: True for f, _ in fields}
    context = [(k, source(v)) for k, v in call.items() if k != "id" and k not in given] if type(call) == "dict" else []
    given.update({k: True for k, _ in context})
    extra = [(m + "_call_id", repr(id))] + ([("id", repr(id))] if "id" not in given and id != None else [])
    exchange(server, ["%s : %s" % (name, _struct(context + list(fields) + extra))])

def after(server):
    """What the updates since the last look did: {"ready": [(method,
    request id, value, error)] the answers to requests (value: the
    response's struct, as serve.star reads values; error: (code, message)
    or None), "calls": [(method, call id, value)] the requests to make}."""
    g = server["grpc"]
    changed = server["changed"]
    server["changed"] = {}
    for m in g["served"]:
        resp = m + "_response"
        if resp in changed:
            for v in _members(server["values"][resp]):
                key = (m, v.get("id") if type(v) == "dict" else None)
                if key in g["waiting"]:
                    g["waiting"].pop(key)
                    g["ready"].append((m, key[1], v, None))
        if resp + "Error" in changed:
            for e in _members(server["values"][resp + "Error"]):
                key = (m, e.get(resp + "_id") if type(e) == "dict" else None)
                if key in g["waiting"]:
                    g["waiting"].pop(key)
                    g["ready"].append((m, key[1], None, ("INTERNAL", "%s.%s would be None" % (resp, e.get("field")) if e.get("field") else "%s couldn't be computed" % resp)))
    calls = []
    for m in g["called"]:
        name = m + "_call"
        if name not in changed:
            continue
        for v in _members(server["values"][name]):
            k = _seen(v)
            if k in g["sent"][m]:
                continue
            g["sent"][m][k] = True
            calls.append((m, k[0], v))
    ready = g["ready"]
    g["ready"] = []
    return {"ready": ready, "calls": calls}
