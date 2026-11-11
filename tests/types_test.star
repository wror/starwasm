# Unit tests for the type checker's unification (typecheck/unify.star), on
# types written in its type language. Run:
#   bin/starhost --recursion tests/types_test.star
#
# The row cases follow "Infix-Extensible Record Types for Tabular Data"
# (Paszke & Xie, TyDe '23), section 3.4 and Fig. 10.

load("../typecheck/stubs.star", "declare_tparams", "new_scope", "parse_stubs", "to_params")
load("../typecheck/types.star", "lit", "new_namer", "show")
load("../typecheck/unify.star", "describe_failure", "flow", "unify", "unify_label")

failures = []

def check_eq(what, got, want):
    if got != want:
        failures.append(what + ": got " + repr(got) + ", want " + repr(want))

def _setup(tparams, types):
    """The types (written in the type language, over the unification
    variables tparams, e.g. "T, **R, L: str") and their variables by name."""
    st = {"next": 0, "errors": [], "seen": {}, "pending": [], "methods": {}, "owners": {}}
    src = "def f[" + tparams + "](" + ", ".join(["p%d: %s" % (i, t) for i, t in enumerate(types)]) + ")\n"
    d = parse_stubs(src if tparams else src.replace("[]", ""), "<test>")[0]
    cv = new_scope(st, "<test>", {}, 1)
    declare_tparams(cv, d["tparams"], 1)
    params = to_params(cv, d["params"], None)
    return st, cv, [p["type"] for p in params]

CTX = {"file": "<test>", "pos": (1, 1), "role": "test"}

def u(tparams, a, b, flowing = False):
    """Unify the types a and b (flowing: use an a where a b is wanted).
    Returns "a' = b'" (both types afterwards; equal types print once), or
    "error: ..."; "!" follows if errors were reported on the way."""
    st, cv, ts = _setup(tparams, [a, b])
    err = flow(st, ts[0], ts[1], CTX) if flowing else unify(st, ts[0], ts[1], CTX)
    if err != None:
        msg, _ = describe_failure(st, CTX, ts[0], ts[1], err, flowing)
        return "error: " + msg[len("test: "):]
    nm = new_namer(False)
    nm["names"] = {tv["val"]["id"]: name for name, tv in cv["tvars"].items()}
    nm["used"] = {name: True for name in cv["tvars"]}
    sa = show(ts[0], nm)
    sb = show(ts[1], nm)
    return (sa if sa == sb else sa + " = " + sb) + ("!" if st["errors"] else "")

def test_types():
    check_eq("same", u("", "int", "int"), "int")
    check_eq("different", u("", "int", "str"), "error: int vs str")
    check_eq("var", u("T", "list[T]", "list[int]"), "list[int]")
    # no recursive types: where a type would contain itself, it is Any
    check_eq("occurs", u("T", "T", "list[T]"), "Any = list[Any]")
    check_eq("occurs in a row", u("**R", "struct[**R]", "struct[a: int, **R]"), "error: struct[...] vs struct[a: int, ...]: only one has a field 'a'")
    check_eq("fn", u("T, U", "(T, int) -> U", "(str, T) -> T"), "error: (str, int) -> _ vs (str, str) -> str (int vs str)")
    check_eq("fn ok", u("T, U", "(T, int) -> U", "(str, int) -> T"), "(str, int) -> str")
    check_eq("fn arity", u("", "(int) -> int", "(int, int) -> int"), "error: (int) -> int vs (int, int) -> int: functions of 1 and 2 parameters")
    check_eq("optional", u("T", "T | None", "int | None"), "int | None")
    check_eq("optional vs not", u("", "int | None", "int"), "error: int | None vs int: only one of them may be None")
    check_eq("tuple", u("T", "tuple[T, str]", "tuple[int, T]"), "error: tuple[int, str] vs tuple[int, int] (str vs int)")
    check_eq("tuple length", u("", "tuple[int]", "tuple[int, int]"), "error: tuple[int] vs tuple[int, int]: tuples of 1 and 2 elements")
    check_eq("any", u("", "list[Any]", "list[int]"), "list[Any] = list[int]")

    # flow: what unify refuses but a use allows
    check_eq("flow optional", u("", "int", "int | None", True), "int = int | None")
    check_eq("flow optional back", u("", "int | None", "int", True), "error: expected int, got int | None: the value may be None")
    check_eq("flow int to float", u("", "int", "float", True), "int = float")
    check_eq("flow float to int", u("", "float", "int", True), "error: expected int, got float")
    check_eq("flow in a list", u("", "list[int]", "list[float]", True), "error: expected list[float], got list[int] (int vs float)")
    check_eq("flow in a tuple", u("", "tuple[int, None]", "tuple[float, str | None]", True), "tuple[int, None] = tuple[float, str | None]")
    check_eq("flow in a struct", u("", "struct[x: int]", "struct[x: float | None]", True), "struct[x: int] = struct[x: float | None]")

def test_rows():
    # rows are equal up to the order of fields with different names
    check_eq("order", u("", "struct[a: int, b: str]", "struct[b: str, a: int]"), "struct[a: int, b: str] = struct[b: str, a: int]")
    check_eq("field type", u("", "struct[a: int]", "struct[a: str]"), "error: struct[a: int] vs struct[a: str] (int vs str)")
    check_eq("missing", u("", "struct[a: int]", "struct[a: int, b: str]"), "error: struct[a: int] vs struct[a: int, b: str]: only one has a field 'b'")
    check_eq("hint", u("", "struct[width: int]", "struct[widht: int]"), "error: struct[width: int] vs struct[widht: int]: only one has a field 'widht' (did you mean 'width'?)")

    # Rfield + LUtail: a row variable at the end takes the fields it lacks
    check_eq("tail", u("**R", "struct[a: int, **R]", "struct[b: str, a: int]"), "struct[a: int, b: str] = struct[b: str, a: int]")
    check_eq("tail empty", u("**R", "struct[a: int, **R]", "struct[a: int]"), "struct[a: int]")
    check_eq("two tails", u("**R, **S", "struct[a: int, **R]", "struct[b: str, **S]"), "struct[a: int, b: str, ...] = struct[b: str, a: int, ...]")
    check_eq("tail missing", u("**R", "struct[a: int, **R]", "struct[b: str]"), "error: struct[a: int, ...] vs struct[b: str]: only one has a field 'a'")

    # Rsolve: a row variable against a whole row
    check_eq("whole", u("**R", "struct[**R]", "struct[a: int, b: str]"), "struct[a: int, b: str]")
    check_eq("whole, both", u("**R, **S", "struct[**R]", "struct[**S]"), "struct[**S]")

    # infix: a row variable before other fields
    check_eq("infix", u("**R", "struct[**R, id: int]", "struct[x: str, id: int]"), "struct[x: str, id: int]")
    check_eq("infix reordered", u("**R", "struct[**R, id: int]", "struct[id: int, x: str]"), "struct[x: str, id: int] = struct[id: int, x: str]")
    check_eq("infix middle", u("**R, **S", "struct[**R, a: int, **S]", "struct[**R, a: int, y: str]"), "struct[**R, a: int, y: str]")
    check_eq("infix both", u("**R, **S", "struct[**R, x: int]", "struct[**S, y: str]"), "struct[..., y: str, x: int] = struct[..., x: int, y: str]")
    check_eq("same variable", u("**R", "struct[**R, a: int]", "struct[**R, a: int]"), "struct[**R, a: int]")

    # the side condition of Rfield: (l1: int | a) ~ (l2: int | a) must not loop
    check_eq("loop", u("**R", "struct[a: int, **R]", "struct[b: int, **R]"), "error: struct[a: int, ...] vs struct[b: int, ...]: only one has a field 'a'")
    check_eq("contains itself", u("**R", "struct[**R, a: int]", "struct[b: int, **R]"), "error: struct[..., a: int] vs struct[b: int, ...]: a struct type would contain itself")

    # scoped labels: the first field of a name is the one that counts, and
    # (with no way to remove a field) the only one that is kept
    st, cv, ts = _setup("**R, **S", ["struct[**R, a: int]", "struct[**S]", "struct[a: str, b: int]", "struct[**S, a: int]"])
    check_eq("fields of R", unify(st, ts[1], ts[2], CTX), None)
    check_eq("shadow", show(ts[3]), "struct[a: str, b: int]")
    # ... but a field that follows a row variable is taken to be seen: R
    # is not solved to something that shadows it (as the paper, where
    # (R | a: int) and (a: str) differ; here R = (a: str) would do)
    check_eq("not shadowed", u("**R", "struct[**R, a: int]", "struct[a: str]"), "error: struct[..., a: int] vs struct[a: str] (int vs str)")
    check_eq("repeated field", u("", "struct[a: str, a: int]", "struct[a: str]"), "struct[a: str]!")

    # a field whose name is a variable: unification waits until the name
    # is known (the paper's (a: Int, b) ~ (l1: Int, l2: Int), which has two
    # unifiers), then goes on
    st, cv, ts = _setup("L: str, **R", ["struct[L: int, **R]", "struct[x: int, y: int]", "L"])
    check_eq("label waits", unify(st, ts[0], ts[1], CTX), None)
    check_eq("label waiting", show(ts[0]), "struct[_: int, ...]")
    check_eq("label solved", unify_label(st, cv["tvars"]["L"]["val"], lit("y"), ts[2], ts[2], CTX), None)
    check_eq("label after", show(ts[0]) + " " + str(len(st["errors"])), "struct[y: int, x: int] 0")
    st, cv, ts = _setup("L: str, **R", ["struct[L: int, **R]", "struct[x: int, y: str]", "L"])
    unify(st, ts[0], ts[1], CTX)
    unify_label(st, cv["tvars"]["L"]["val"], lit("y"), ts[2], ts[2], CTX)
    check_eq("label wrong type", [e["msg"] for e in st["errors"]], ["test: struct[y: int, ...] vs struct[x: int, y: str] (int vs str)"])
    check_eq("label is the name's type", u("L: str", "L", "Literal[\"x\"]"), "Literal[\"x\"]")
    check_eq("label vs str", u("", "Literal[\"x\"]", "str"), "Literal[\"x\"] = str")
    check_eq("labels differ", u("", "Literal[\"x\"]", "Literal[\"y\"]"), "error: Literal[\"x\"] vs Literal[\"y\"]: field names 'x' and 'y'")

test_types()
test_rows()
fail(str(len(failures)) + " failure(s):\n  " + "\n  ".join(failures)) if failures else None
print("types_test: ok")
