# precedence.star — intransitive operator precedence (PRECEDENCE.md).
#
# Starlark's parser gives every operator a place in one total order, so
# `a & b == c`, `not a + b` and `x ?? 0 + 1` all parse, each in one way
# that a reader may well not expect. The type checker holds programs to a
# stricter rule, after Jeff Walker, "Operator Precedence: We can do
# better" (blog.adamant-lang.org/2019/operator-precedence/): precedence
# is a relation between groups of operators that is *intransitive* (that
# A binds tighter than B and B tighter than C says nothing about A and
# C), and two operators that it doesn't relate can't be mixed without
# parentheses. The parser is unchanged (a program the checker accepts
# parses as it always did); this pass only reports the places where an
# operand of an operator is, unparenthesized, an expression of an
# operator that the relation doesn't put above it.
#
# The relation is declared below in the article's notation: chains, in
# which each group is below every group after it, and sets of groups.

# Each binary operator's group. The prefix operators - + ~ take part in
# no relation: their operand is always a single term (a name, literal,
# call, index, ... or parenthesized expression), and they bind more
# tightly than any binary operator, in Starlark as in every language
# with C's operators (-x * y, -a and b, ~m & n: there is no other way to
# read them). Prefix `not` is another matter (NOT_GROUP).
GROUP = {
    "??": "coalesce",
    "or": "or",
    "and": "and",
    "==": "compare",
    "!=": "compare",
    "<": "compare",
    ">": "compare",
    "<=": "compare",
    ">=": "compare",
    "in": "compare",
    "not in": "compare",
    "|": "bitor",
    "^": "bitxor",
    "&": "bitand",
    "<<": "shift",
    ">>": "shift",
    "+": "add",
    "-": "add",
    "*": "mul",
    "/": "div",
    "//": "div",
    "%": "mod",
}
NOT_GROUP = "not"

# Whether an operand may be an unparenthesized expression of its own
# group: "left" (a - b - c is (a - b) - c), or "none" (a / b / c is an
# error). Starlark's binary operators all group to the left when they
# group at all, so there is no "right".
ASSOC = {
    "coalesce": "left",
    "or": "left",
    "and": "left",
    "compare": "none",  # (the parser already rejects a < b < c)
    "bitor": "left",
    "bitxor": "left",
    "bitand": "left",
    "shift": "none",
    "add": "left",
    "mul": "left",
    "div": "none",
    "mod": "none",
}

ARITHMETIC = ["add", "mul", "div", "mod"]
BITWISE = ["bitor", "bitxor", "bitand", "shift"]

# The precedence relation. In a chain, each set of groups binds less
# tightly than every set after it (or < and < not: `a or not b` and
# `not a and b` need no parentheses), and that is all: what no chain
# relates, nothing relates.
CHAINS = [
    # logic: and before or, as in mathematics; not before both
    [["or"], ["and"], ["not"]],
    # comparisons give the operands of logic. But `not a == b` is
    # (not a) == b in C, Java, Go, JavaScript, ... (!a == b) and
    # not (a == b) in Python and Starlark: not and comparisons are not
    # related (write a != b, x not in y, or parenthesize).
    [["or", "and"], ["compare"]],
    # arithmetic, below which are comparisons; * / // % are not related
    # to each other (a * b % c, a / b * c need parentheses)
    [["compare"], ["add"], ["mul", "div", "mod"]],
    # bitwise: & and shifts before | and ^, in C, Python, Go, Swift,
    # Rust, ... (a | b << 4 is a | (b << 4)). But ^ and | are on one level
    # in Go and Swift (a | b ^ c is (a | b) ^ c there, a | (b ^ c) in C),
    # and so are & and shifts in Go (a & b << 4 is (a & b) << 4 there):
    # those pairs are unrelated. None is related to arithmetic
    # (1 << n - 1 needs parentheses) or to comparisons: C and Python
    # disagree on a & b == c.
    [["bitor", "bitxor"], ["bitand", "shift"]],
    # ?? (EXTENSIONS.md): below arithmetic and bitwise operators, as in
    # every language that has it (C#, Swift, Kotlin's ?:, JavaScript), so
    # a + b ?? 0 is (a + b) ?? 0 and x ?? 0 + 1 is x ?? (0 + 1). Those
    # languages disagree on ?? and comparisons, and on ?? and logic
    # (JavaScript makes a ?? b || c an error): unrelated.
    [["coalesce"], ARITHMETIC + BITWISE],
]

def _relation():
    below = {}
    for chain in CHAINS:
        for i in range(len(chain)):
            for lo in chain[i]:
                for later in chain[i + 1:]:
                    for hi in later:
                        below[(lo, hi)] = True
    return below

# (lo, hi) -> True: an operand of an operator of group lo may be,
# unparenthesized, an expression of group hi
BELOW = _relation()

def binds_tighter(hi, lo):
    """Does group hi bind more tightly than group lo?"""
    return (lo, hi) in BELOW

def _group(e):
    """The group of expression e as an operand: None for one that takes
    no part (a name, literal, call, ..., a prefix - + ~, and anything in
    parentheses)."""
    if e.get("paren", False):
        return None
    if e["kind"] == "binop":
        return GROUP[e["op"]]
    if e["kind"] == "unop" and e["op"] == "not":
        return NOT_GROUP
    return None

def _readings(e, side, x):
    """The expression as it parses, and the other way to read it."""
    if e["kind"] == "unop":  # not (a X b), or (not a) X b
        return "not (a " + x["op"] + " b)", "(not a) " + x["op"] + " b"
    if x["kind"] == "unop":  # (not a) P b, or not (a P b)
        return "(not a) " + e["op"] + " b", "not (a " + e["op"] + " b)"
    if side == "left":
        return "(a " + x["op"] + " b) " + e["op"] + " c", "a " + x["op"] + " (b " + e["op"] + " c)"
    return "a " + e["op"] + " (b " + x["op"] + " c)", "(a " + e["op"] + " b) " + x["op"] + " c"

def _operand(e, side, x, cx):
    """Is operand x of operator e (on its "left" or "right") allowed
    there? If not, the error goes on cx["out"]."""
    if x.get("paren", False) or x["kind"] not in ("binop", "unop"):
        return
    if x["kind"] == "unop" and (side == "right" or e["kind"] == "unop"):
        # a prefix operator right after another operator: there is only
        # one way to read it (a ?? not b, not not x, a * -b)
        return
    g = _group(x)
    if g == None:  # (a prefix - + ~: as tight as can be, but it is spaced)
        _spacing(e, side, x, cx)
        return
    pg = GROUP[e["op"]] if e["kind"] == "binop" else NOT_GROUP
    if binds_tighter(g, pg) or (g == pg and ASSOC[pg] == side):
        _spacing(e, side, x, cx)
        return
    first, second = (x, e) if side == "left" else (e, x)  # (in source order)
    ops = "`" + first["op"] + "` and `" + second["op"] + "`"
    if g == pg:
        why = ops + " don't group: " + _what(pg)
    else:
        why = ops + " have no precedence relative to each other"
    parsed, other = _readings(e, side, x)
    better = ""
    if e["kind"] == "unop" and x["op"] in NEGATED:
        better = " (or write a " + NEGATED[x["op"]] + " b)"
    cx["out"].append((x["pos"], "operator precedence: " + why + ": add parentheses, as in " +
                                parsed + " (how it parses) or " + other + better))

# not (a == b) is a != b, ...
NEGATED = {"==": "!=", "!=": "==", "in": "not in", "not in": "in"}

def _what(g):
    return {
        "compare": "comparisons don't chain",
        "shift": "shifts don't chain",
        "div": "divisions don't chain",
        "mod": "% doesn't chain",
    }[g]

# ---------------------------------------------------------------- spacing

# Spacing that says otherwise. Where the precedence allows an operand x of
# operator e unparenthesized, x's operator binds more tightly than e's, so
# it must not be spaced more widely: a+b * c reads as (a+b) * c, but is
# a+(b * c). An operator's width is the number of blanks (spaces, tabs) on
# its wider side, a prefix operator's those after it. An operator with a
# line break or a comment on either side has no width: the line breaks
# where it must, and says nothing about grouping.

def _cps(cx, line):
    """The code points of source line `line` (columns count them)."""
    cps = cx["cps"].get(line)
    if cps == None:
        cps = list(cx["lines"][line - 1].codepoints()) if line <= len(cx["lines"]) else []
        cx["cps"][line] = cps
    return cps

def _blanks_before(cps, i):
    """Blanks just before index i, or None if the line starts there."""
    n = 0
    for _ in range(i):
        if i - 1 - n < 0 or cps[i - 1 - n] not in (" ", "\t"):
            break
        n += 1
    return None if i - n <= 0 else n

def _blanks_after(cps, i):
    """Blanks from index i, or None if the line ends there (or a comment
    or a backslash continuation starts)."""
    n = 0
    for _ in range(len(cps) - i):
        if cps[i + n] not in (" ", "\t"):
            break
        n += 1
    if i + n >= len(cps) or cps[i + n] in ("#", "\\"):
        return None
    return n

def _blanks(cx, e):
    """(before, after) e's operator: numbers of blanks, or None."""
    line, col = e["pos"]
    cps = _cps(cx, line)
    i = col - 1
    if e["kind"] == "unop":
        return 0, _blanks_after(cps, i + len(e["op"]))
    if e["op"] == "not in":  # (at its "in")
        j = i
        for _ in range(i):
            if j < 1 or cps[j - 1] not in (" ", "\t"):
                break
            j -= 1
        return _blanks_before(cps, j - 3), _blanks_after(cps, i + 2)
    return _blanks_before(cps, i), _blanks_after(cps, i + len(e["op"]))

def _shown(e, sp):
    if e["kind"] == "unop":
        return e["op"] + " " * sp[1]
    return " " * sp[0] + e["op"] + " " * sp[1]

def _spacing(e, side, x, cx):
    se = _blanks(cx, e)
    sx = _blanks(cx, x)
    if None in se or None in sx:
        return
    we = se[1] if e["kind"] == "unop" else max(se)
    wx = sx[1] if x["kind"] == "unop" else max(sx)
    if wx <= we:
        return
    if x["kind"] == "binop" and e["kind"] == "binop" and GROUP[x["op"]] == GROUP[e["op"]]:
        # (x is on the left: a group that chains, chains from the left)
        why = "`" + x["op"] + "` and `" + e["op"] + "` group from the left"
        fix = "the first `" + x["op"] + "` no more widely than the `" + e["op"] + "` after it"
    else:
        why = "`" + x["op"] + "` binds more tightly than `" + e["op"] + "`"
        fix = "`" + x["op"] + "` no more widely than `" + e["op"] + "`"
    P = _shown(e, se)
    X = _shown(x, sx)
    if e["kind"] == "unop":  # not (a X b)
        shown, parsed = P + "a" + X + "b", P + "(a" + X + "b)"
    elif x["kind"] == "unop":  # (U a) P b
        shown, parsed = X + "a" + P + "b", "(" + X + "a)" + P + "b"
    elif side == "left":
        shown, parsed = "a" + X + "b" + P + "c", "(a" + X + "b)" + P + "c"
    else:
        shown, parsed = "a" + P + "b" + X + "c", "a" + P + "(b" + X + "c)"
    cx["out"].append((x["pos"], "operator precedence: the spacing says otherwise: `" + shown + "` is `" + parsed +
                                "`, as " + why + ": space " + fix + ", or add parentheses"))

# ---------------------------------------------------------------- the walk

def check_expr(e, cx):
    """Appends to cx["out"] a (pos, message) for each operand in
    expression e (and in what it contains) that the precedence relation
    doesn't allow unparenthesized, or that is spaced as if it grouped
    otherwise."""
    k = e["kind"]
    if k == "binop":
        _operand(e, "left", e["x"], cx)
        _operand(e, "right", e["y"], cx)
    elif k == "unop" and e["op"] == "not":
        _operand(e, "right", e["x"], cx)

    # A conditional expression and a lambda bind less tightly than any
    # operator: their parts may be anything (x + 1 if c else y - 1 is
    # unambiguous, since `if` and `else` delimit them), and they can be an
    # operand only in parentheses, which the parser sees to.
    check_node(e, cx)

def check_node(n, cx):
    """check_expr on every expression in AST node n (statements too)."""
    for key, v in n.items():
        if key == "pos" or key == "kind":
            continue
        _check_value(v, cx)

def _check_value(v, cx):
    t = type(v)
    if t == "dict":
        if "kind" in v and "pos" in v:
            check_expr(v, cx)
        else:
            check_node(v, cx)
    elif t == "list" or t == "tuple":
        for x in v:
            _check_value(x, cx)

def check_stmts(stmts, src):
    """The precedence errors in a module's statements (parsed from source
    text src): a list of (pos, message)."""
    cx = {"out": [], "lines": src.split("\n"), "cps": {}}
    for s in stmts:
        check_node(s, cx)
    return cx["out"]
