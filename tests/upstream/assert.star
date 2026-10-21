# The assert module for starlark-go's test files: a copy of
# go.starlark.net/starlarktest/assert.star on the test-only builtins that
# `compiler/main.star --test` and bin/upstreamhost provide (test_error,
# test_catch, test_matches, test_freeze, test_floateq), with struct in place
# of starlarkstruct's module. tests/upstream/run.mjs puts a copy next to each
# chunk it runs, so `load("assert.star", "assert", "freeze")` finds it.

_num = ("float", "int")

def _eq(x, y):
    if x != y:
        if (type(x) == "float" and type(y) in _num or
            type(y) == "float" and type(x) in _num):
            if not test_floateq(float(x), float(y)):
                test_error("floats: %r != %r (delta > 1 ulp)" % (x, y))
        else:
            test_error("%r != %r" % (x, y))

def _ne(x, y):
    if x == y:
        test_error("%r == %r" % (x, y))

def _true(cond, msg = "assertion failed"):
    if not cond:
        test_error(msg)

def _lt(x, y):
    if not (x < y):
        test_error("%s is not less than %s" % (x, y))

def _contains(x, y):
    if y not in x:
        test_error("%s does not contain %s" % (x, y))

def _fails(f, pattern):
    "assert_fails asserts that evaluation of f() fails with the specified error."
    msg = test_catch(f)
    if msg == None:
        test_error("evaluation succeeded unexpectedly (want error matching %r)" % pattern)
    elif not test_matches(pattern, msg):
        test_error("regular expression (%s) did not match error (%s)" % (pattern, msg))

def freeze(x):
    return test_freeze(x)

assert = struct(
    fail = test_error,
    eq = _eq,
    ne = _ne,
    true = _true,
    lt = _lt,
    contains = _contains,
    fails = _fails,
)
