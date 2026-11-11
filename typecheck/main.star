# main.star — the type checker's command line.
#
#   bin/starhost --recursion typecheck/main.star [--print] [--start=FILE]... prog.star
#   ... --repl [--only=NAME]: for the REPL (host/repl_core.mjs): `_` may be
#       assigned values of different types at top level, source lines are
#       shown without their numbers, and --only prints just NAME's type
#   node host/typecheck.mjs [--print] prog.star...        (the usual way)
#
# Infers the types of prog.star (and of the modules it loads), checking
# them against the annotations in prog.start, if there is one. Type errors
# are printed, each with the source line; the program then fails (exit
# status 1). Without errors, the inferred types are written to
# prog.starit, in the language of prog.start (--print: printed instead).
# EXTENSIONS.md ("Static types") documents the type system and the
# language of the two files.
#
# Starlark can't ask whether a file exists, so which annotation files
# there are is said on the command line: --start=FILE for each one (for
# prog.star and the modules it loads), or --start=* to read the .start
# file of every module, when the host gives an empty one for those that
# don't exist (host/typecheck.mjs does).
#
# The checker is plain Starlark: it runs in starlark-go (bin/starhost) and
# compiled by starwasm (node host/run.mjs --recursion typecheck/main.star -- ...).

load("builtins.star", "load_builtins")
load("infer.star", "check_module", "new_scope")
load("types.star", "collect_generic", "new_namer", "resolve", "show", "show_params", "show_tparams")

MAX_SHOWN = 100  # diagnostics printed for one program

def _excerpt(st, file, pos):
    """The source line at pos with a caret under the column, or []."""
    src = st["sources"].get(file)
    if src == None:
        return []
    lines = st["lines"].get(file)
    if lines == None:
        lines = src.replace("\r\n", "\n").replace("\r", "\n").split("\n")
        st["lines"][file] = lines
    line, col = pos
    if line < 1 or line > len(lines):
        return []
    text = lines[line - 1]
    num = str(line)
    if st["repl"]:
        num = ""  # (line numbers of the session file mean nothing to the user)
    gutter = " " * (5 - len(num)) + num + " | "
    pad = "".join(["\t" if c == "\t" else " " for c in text.codepoints()][:col - 1])
    return [gutter + text, " " * 5 + " | " + pad + "^"]

def format_errors(st, main):
    """The diagnostics, sorted by position (those of the main file first)."""
    out = []
    errors = sorted(st["errors"], key = lambda e: (e["file"] != main, e["file"], e["pos"][0], e["pos"][1]))
    for i, e in enumerate(errors):
        if i == MAX_SHOWN:
            out.append("(" + str(len(errors) - i) + " more errors not shown)")
            break
        out.append(e["file"] + ":" + str(e["pos"][0]) + ":" + str(e["pos"][1]) + ": error: " + e["msg"])
        out += _excerpt(st, e["file"], e["pos"])
        for n in e["notes"]:
            if n["file"].startswith("<"):
                continue
            out.append(n["file"] + ":" + str(n["pos"][0]) + ":" + str(n["pos"][1]) + ": note: " + n["msg"])
            out += _excerpt(st, n["file"], n["pos"])
    return out

def _child_namer(nm):
    c = new_namer(True)
    if nm != None:
        c["names"] = dict(nm["names"])
        c["used"] = dict(nm["used"])
        c["n"] = dict(nm["n"])
    return c

def _render_scope(scope, indent, nm, out, skip_params, only = None):
    for name in scope["order"]:
        b = scope["vars"][name]
        k = b["kind"]
        if b.get("loaded", False) or (skip_params and b.get("param", False)) or (only != None and name != only):
            continue
        if k == "var":
            out.append(indent + name + ": " + show(b["type"], nm))
        elif k == "relation":
            out.append(indent + name + ": list[" + show(b["type"], nm) + "]")
        elif k == "def":
            _render_def(b, indent, nm, out)

def _render_def(b, indent, parent, out):
    nm = _child_namer(parent)
    t = resolve(b["type"])
    start = len(nm["order"])
    collect_generic(t, nm)
    tparams = show_tparams(nm, start)
    line = indent + "def " + b["name"] + tparams + "(" + show_params(t["params"], nm) + ") -> " + show(t["ret"], nm)
    nm["closed"] = True
    inner = []
    if b["locals"] != None:
        _render_scope(b["locals"], indent + "    ", nm, inner, True)
    out.append(line + (":" if inner else ""))
    out.extend(inner)

def render_types(mod):
    """The contents of the .starit file of a checked module."""
    path = mod["path"]
    base = path.split("/")[-1]
    out = [
        "# Types inferred from " + base + " by starwasm's type checker (typecheck/main.star).",
        "# Rewritten by every check: put annotations in " + base + "t instead.",
        "",
    ]
    nm = new_namer(True)
    nm["closed"] = True
    _render_scope(mod["scope"], "", nm, out, False)
    return "\n".join(out) + "\n"

def render_one(mod, name):
    """The declaration of the top-level name alone ("" if there is none)."""
    b = mod["scope"]["vars"].get(name)
    if b != None and b["kind"] == "var" and not b.get("loaded", False):
        # a variable: what is still unknown in its type is shown as type
        # parameters, as for a def ("[T](x: T) -> T" for an identity lambda)
        nm = new_namer(True)
        nm["all"] = True
        collect_generic(b["type"], nm)
        tparams = show_tparams(nm)
        return name + ": " + tparams + show(b["type"], nm)
    nm = new_namer(True)
    nm["closed"] = True
    out = []
    _render_scope(mod["scope"], "", nm, out, False, name)
    return "\n".join(out)

def check(path, starts, all_starts, repl = False):
    """Check the program at path. Returns (st, module record)."""
    st = {
        "repl": repl,
        "next": 0,
        "errors": [],
        "seen": {},
        "pending": [],
        "methods": {},
        "owners": {},
        "modules": {},
        "sources": {},
        "lines": {},
        "stack": [],
        "group": [],
        "read": read_file,
        "has_start": lambda p: all_starts or p in starts,
        "builtins": None,
    }
    builtins = new_scope(None, 0, None)
    for name, (kind, t) in load_builtins(st).items():
        builtins["vars"][name] = {"kind": "builtin" if kind == "def" else "var", "type": t, "name": name, "pos": (0, 0)}
    st["builtins"] = builtins
    return st, check_module(st, path)

def main():
    printing = False
    repl = False
    only = None
    starts = {}
    all_starts = False
    files = []
    for a in argv:
        if a == "--print":
            printing = True
        elif a == "--start=*":
            all_starts = True
        elif a.startswith("--start="):
            starts[a[len("--start="):]] = True
        elif a == "--repl":
            repl = True
        elif a.startswith("--only="):
            only = a[len("--only="):]
        elif a.startswith("--"):
            fail("typecheck: unknown option " + a)
        else:
            files.append(a)
    if len(files) != 1:
        fail("usage: typecheck/main.star [--print] [--start=FILE]... <program.star>")
    path = files[0]
    st, mod = check(path, starts, all_starts, repl)
    if st["errors"]:
        print("\n".join(format_errors(st, path)))
        n = len(st["errors"])
        fail("typecheck: " + str(n) + " type error" + ("" if n == 1 else "s") + " in " + path)
    if only != None:
        print(render_one(mod, only))
        return
    text = render_types(mod)
    if printing:
        print(text[:-1])
    else:
        write_file(path + "it", text)

main()
