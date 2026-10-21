# Compiler driver.
#
#   bin/starhost compiler/main.star [--test] input.star output.wasm
#   node host/run.mjs output.wasm        # runs the module's top level
#
# --test makes the test-only builtins visible (see TEST_BUILTINS in
# codegen.star); tests/upstream/ uses it to run starlark-go's test files.

load("codegen.star", "compile")

test = len(argv) > 0 and argv[0] == "--test"
args = argv[1:] if test else argv
if len(args) != 2:
    fail("usage: starhost compiler/main.star [--test] <input.star> <output.wasm>")
write_file(args[1], compile(read_file(args[0]), args[0], test))
