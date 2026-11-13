# Compiler driver.
#
#   bin/starhost compiler/main.star [--test] [--globalreassign] [--recursion] [--repl] [--contagiousnone | --nocontagiousnone] [--rollback]
#                                   [--descriptor_set=FILE] input.star output.wasm
#   node host/run.mjs output.wasm        # runs the module's top level
#   node host/run.mjs [options] input.star   # both: compiles only when needed (host/wasmcache.mjs)
#
# --test makes the test-only builtins visible (see TEST_BUILTINS in
# codegen.star); tests/upstream/ uses it to run starlark-go's test files.
# --globalreassign: starlark-go's AllowGlobalReassign, off by default as in
# starlark-go: allow a top-level name to be bound more than once (and
# resolve top-level uses in source order; see compiler/resolve.star), while
# loops, and if/for/while at top level.
# --recursion: starlark-go's Recursion option, off by default as in
# starlark-go: allow functions to call themselves, directly or not (without
# it, a cycle of statically known calls is a compile error; see
# compiler/recursion.star). The compiler itself is recursive, so it is
# built with --recursion.
# --repl: compiling a REPL session (host/repl.mjs): `_`, the last value, may
# be rebound at top level even without --globalreassign.
# --contagiousnone, --nocontagiousnone: turn the "contagious None" extension
# on or off (EXTENSIONS.md: operations on None give None, and a None knows
# where it comes from). With neither, it is on in programs with reactive
# variables and off in others.
# --rollback: in a reactive program with contagious None, undo an update
# in which an error was caught (the errors are still printed, and what
# observers printed stays): every reactive variable gets back its value
# from before the line. Without it, the errors' Nones stay.
# --descriptor_set=FILE: the binary FileDescriptorSet (as written by
# `protoc --include_imports --descriptor_set_out`) whose files the proto
# module finds; it is compiled into programs that use proto.

load("codegen.star", "compile")

def main():
    test = False
    reassign = False
    repl = False
    recursion = False
    contagious_none = None
    rollback = False
    fds = None
    args = []
    for a in argv:
        if a == "--test":
            test = True
        elif a == "--globalreassign":
            reassign = True
        elif a == "--repl":
            repl = True
        elif a == "--recursion":
            recursion = True
        elif a == "--contagiousnone":
            contagious_none = True
        elif a == "--nocontagiousnone":
            contagious_none = False
        elif a == "--rollback":
            rollback = True
        elif a.startswith("--descriptor_set="):
            fds = read_file(a[len("--descriptor_set="):])
        else:
            args.append(a)
    if len(args) != 2:
        fail("usage: starhost compiler/main.star [--test] [--globalreassign] [--recursion] [--repl] [--contagiousnone | --nocontagiousnone] [--rollback] [--descriptor_set=FILE] <input.star> <output.wasm>")
    write_file(args[1], compile(read_file(args[0]), args[0], test, fds, reassign, repl, recursion, contagious_none, rollback))

main()
