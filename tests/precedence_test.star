# Unit tests for the type checker's operator precedence
# (typecheck/precedence.star, PRECEDENCE.md). Run:
#   bin/starhost --recursion tests/precedence_test.star

load("../compiler/parser.star", "PREC", "parse_file")
load("../typecheck/precedence.star", "ASSOC", "BELOW", "GROUP", "NOT_GROUP", "check_stmts")

failures = []

def check_eq(what, got, want):
    if got != want:
        failures.append(what + ": got " + repr(got) + ", want " + repr(want))

# The checker only rejects; it never reparses. So each relation it declares
# must agree with the parser's ranking (PREC; `not` is level 3), or it
# would endorse a reading the parser doesn't give.
def _level(g):
    if g == NOT_GROUP:
        return 3
    return [PREC[op] for op in GROUP if GROUP[op] == g][0]

def test_consistent():
    for lo, hi in BELOW:
        if not _level(lo) < _level(hi):
            failures.append("relation " + lo + " < " + hi + " disagrees with the parser's ranking")
    for op, g in GROUP.items():
        check_eq("ASSOC has " + g, g in ASSOC, True)
        check_eq("one level for " + g, len({PREC[o]: True for o in GROUP if GROUP[o] == g}), 1)
        check_eq("an operator for " + op, op in PREC, True)

    # intransitive: and < == and == < + do not make and < +
    check_eq("and < ==", ("and", "compare") in BELOW, True)
    check_eq("== < +", ("compare", "add") in BELOW, True)
    check_eq("and, + unrelated", ("and", "add") in BELOW or ("add", "and") in BELOW, False)

def _errors(src):
    return len(check_stmts(parse_file("x = " + src + "\n", "<test>")))

def test_check():
    for src in [
        "a + b * c", "a - b - c", "a or b and c", "not a and b", "a or not b",
        "a ?? not b", "not not a", "-a and b", "~a == b", "a and -b", "a ?? b ?? c",
        "a + b ?? c", "a ?? b * c", "a | b & c", "(a & b) == c", "x + 1 if a & b else y",
        "f((a & b) == c)",
    ]:
        check_eq("accepted: " + src, _errors(src), 0)
    for src in [
        "a & b == c", "not a == b", "a and b + c", "a / b * c", "a / b / c", "a << b >> c",
        "a ?? b or c", "a ?? b == c", "not a ?? b", "a | b ^ c", "1 << n - 1",
        "[a & b == c]", "f(x = a & b == c)", "lambda: a and b + c",
    ]:
        check_eq("rejected: " + src, _errors(src), 1)

test_consistent()
test_check()
fail(str(len(failures)) + " failure(s):\n  " + "\n  ".join(failures)) if failures else None
print("precedence_test: ok")
