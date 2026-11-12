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
#   gen(mc, fc, e)               code for expression e (a value)
#   gen_cond(mc, fc, e)          code for e as an i32 truth value
#   gen_assign(mc, fc, t, value, posn)   code assigning code `value` to target t
#   aug_fn(op)                   the runtime function of `x op= y`
# plus the codegen contexts mc (module) and fc (function).
#
# Hook points:
#   direct_call(cg, mc, fc, e, kind, w)
#       a call whose callee is a name, before codegen compiles it; (kind, w)
#       is the name's lookup result.
#   dynamic_call(cg, mc, fc, callee, e)
#       a call through a value; callee is the code computing the function.
#   expr(cg, mc, fc, e)
#       any expression e, before codegen compiles it (gen).
#   cond(cg, mc, fc, e)
#       an expression compiled as a condition (gen_cond): i32 code.
#   assign(cg, mc, fc, t, value, posn)
#       an assignment of code `value` to target t (gen_assign).
#   stmt(cg, mc, fc, s)
#       any statement s (gen_stmt).
# A hook that wants codegen's own code for a node it changed (say, with its
# operands evaluated beforehand) calls cg["gen"] and so on with a copy of
# the node, marked so that it passes it the second time; an operand already
# evaluated is a node {"kind": "%code", "code": ..., "pos": ..., "orig": the
# node it stands for}. A node with "hooked": True is one a hook means to
# compile: codegen takes no shortcut past gen for it (a for loop over a
# range(...) call doesn't become a counted loop).
#
# Whole-program hook points, in the order compile_program calls them (every
# extension's hook is called; mc["ext"] is a dict for their state):
#   transform(cg, mc)
#       after parsing (mc["mods"]: every module's statements), before
#       anything is declared: may check and rewrite the ASTs.
#   imports(mc, m)
#       the new Wasm module m, before the runtime: declare host imports.
#   runtime(mc, m)
#       after the runtime and builtins: add Wasm functions.
#   prelude(mc) -> (statements, roots)
#       parsed Starlark to add to the prelude module, and the names of
#       prelude functions to keep even if no program text mentions them.
#
# Generated code may call any prelude function, private ones included, by
# the name "%prelude.<name>" (codegen's lookup; "%" can't be written).
#
# EXT_INTRINSICS: primitives the prelude may call (names start with "_"),
# as name -> (Wasm runtime function, min args, max args). An extension adds
# the runtime function in its runtime hook, so it must only keep prelude
# code calling one in programs that use the extension.

load("ext/dir.star", dir_direct_call = "direct_call", dir_dynamic_call = "dynamic_call")
load(
    "ext/reactive.star",
    REACTIVE_INTRINSICS = "INTRINSICS",
    reactive_direct_call = "direct_call",
    reactive_imports = "imports",
    reactive_prelude = "prelude",
    reactive_runtime = "runtime",
    reactive_transform = "transform",
)

load(
    "ext/none.star",
    NONE_INTRINSICS = "INTRINSICS",
    none_assign = "assign",
    none_cond = "cond",
    none_expr = "expr",
    none_prelude = "prelude",
    none_runtime = "runtime",
    none_stmt = "stmt",
    none_transform = "transform",
)

DIRECT_CALL = [dir_direct_call, reactive_direct_call]
DYNAMIC_CALL = [dir_dynamic_call]
EXPR = [none_expr]
COND = [none_cond]
ASSIGN = [none_assign]
STMT = [none_stmt]
TRANSFORM = [reactive_transform, none_transform]  # none: on by default if reactive is in use
IMPORTS = [reactive_imports]
RUNTIME = [reactive_runtime, none_runtime]
PRELUDE = [reactive_prelude, none_prelude]

EXT_INTRINSICS = dict(REACTIVE_INTRINSICS)
EXT_INTRINSICS.update(NONE_INTRINSICS)

def ext_transform(cg, mc):
    for hook in TRANSFORM:
        hook(cg, mc)

def ext_imports(mc, m):
    for hook in IMPORTS:
        hook(mc, m)

def ext_runtime(mc, m):
    for hook in RUNTIME:
        hook(mc, m)

def ext_prelude(mc):
    stmts = []
    roots = []
    for hook in PRELUDE:
        s, r = hook(mc)
        stmts += s
        roots += r
    return stmts, roots

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

def ext_expr(cg, mc, fc, e):
    for hook in EXPR:
        code = hook(cg, mc, fc, e)
        if code != None:
            return code
    return None

def ext_cond(cg, mc, fc, e):
    for hook in COND:
        code = hook(cg, mc, fc, e)
        if code != None:
            return code
    return None

def ext_assign(cg, mc, fc, t, value, posn):
    for hook in ASSIGN:
        code = hook(cg, mc, fc, t, value, posn)
        if code != None:
            return code
    return None

def ext_stmt(cg, mc, fc, s):
    for hook in STMT:
        code = hook(cg, mc, fc, s)
        if code != None:
            return code
    return None
