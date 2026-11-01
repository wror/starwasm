# Compiler driver.
#
#   bin/starhost compiler/main.star [--test] [--descriptor_set=FILE] input.star output.wasm
#   node host/run.mjs output.wasm        # runs the module's top level
#
# --test makes the test-only builtins visible (see TEST_BUILTINS in
# codegen.star); tests/upstream/ uses it to run starlark-go's test files.
# --descriptor_set=FILE: the binary FileDescriptorSet (as written by
# `protoc --include_imports --descriptor_set_out`) whose files the proto
# module finds; it is compiled into programs that use proto.

load("codegen.star", "compile")

test = False
fds = None
args = []
for a in argv:
    if a == "--test":
        test = True
    elif a.startswith("--descriptor_set="):
        fds = read_file(a[len("--descriptor_set="):])
    else:
        args.append(a)
if len(args) != 2:
    fail("usage: starhost compiler/main.star [--test] [--descriptor_set=FILE] <input.star> <output.wasm>")
write_file(args[1], compile(read_file(args[0]), args[0], test, fds))
