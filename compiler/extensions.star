# extensions.star — language features starwasm has and starlark-go lacks.
#
# Each extension lives in compiler/ext/<name>.star and is documented in
# EXTENSIONS.md, with tests in tests/extensions/<name>_*.star. codegen.star
# knows nothing about any particular extension: it calls the hooks below at
# fixed points, and an extension returns code to use instead of the default,
# or None to pass. Hooks are tried in the order of the lists.
#
# Every hook gets `cg`, a dict of codegen.star helpers (CG there):
#   lookup(mc, fc, name, posn)   resolve a name: (kind, x), as codegen's lookup
#   temp(fc, type)               a fresh Wasm local
#   free_cell(idx)               the $Cell of captured variable idx
#   callat(mc, posn, f, *args)   call f, with a source marker for tracebacks
# plus the codegen contexts mc (module) and fc (function).
#
# Hook points:
#   direct_call(cg, mc, fc, e, kind, w)
#       a call whose callee is a name, before codegen compiles it; (kind, w)
#       is the name's lookup result.
#   dynamic_call(cg, mc, fc, callee, e)
#       a call through a value; callee is the code computing the function.

load("ext/dir.star", dir_direct_call = "direct_call", dir_dynamic_call = "dynamic_call")

DIRECT_CALL = [dir_direct_call]
DYNAMIC_CALL = [dir_dynamic_call]

def ext_direct_call(cg, mc, fc, e, kind, w):
    for hook in DIRECT_CALL:
        code = hook(cg, mc, fc, e, kind, w)
        if code != None:
            return code
    return None

def ext_dynamic_call(cg, mc, fc, callee, e):
    for hook in DYNAMIC_CALL:
        code = hook(cg, mc, fc, callee, e)
        if code != None:
            return code
    return None
