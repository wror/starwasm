# starwasm extensions

Features starwasm has that starlark-go doesn't. The rest of starwasm aims
to behave exactly like starlark-go (NOTES.md); everything here is a
deliberate difference, kept apart so the compatible core stays easy to
see and to check.

## Where things go

- **Code:** one file per extension, `compiler/ext/<name>.star`, registered
  in `compiler/extensions.star`. `codegen.star` names no extension: it
  calls the hooks in `extensions.star` at fixed points (a call of a name, a
  call through a value), and an extension either returns the code to emit
  or None to leave the call to the core. A new extension that needs
  another point adds a hook there; helpers it needs from codegen are
  passed in the `cg` dict (`CG` in codegen.star). Runtime support, if
  any, goes in the extension file or in the prelude next to the builtin.
- **Docs:** a section in this file per extension: what it does, how it is
  compiled, what it doesn't cover, how it differs from Python where
  Python is the model.
- **Tests:** `tests/extensions/<name>_*.star`, each with the exact
  expected output in a `.out` file next to it (modules they load go in
  `tests/extensions/modules/<name>_*.star`). There is nothing to compare
  against in starlark-go, so the expected output is written by hand and
  checked against Python where the feature comes from Python.
  `tests/extensions.sh` runs them; test.sh runs it with both the
  interpreted and the self-compiled compiler.
- The starlark-go reference (bin/starhost) and the differential tests in
  tests/compile/ and tests/errors/ stay pure starlark-go: a program there
  must not use an extension.

## dir() with no arguments

starlark-go's dir takes exactly one argument. Here `dir()` returns the sorted names bound at that point in the current scope,
as in Python.

- In a function: parameters, locals already assigned, and captured
  variables (those the function or its inner functions use) that are
  bound. At top level: the module's globals, defs and loaded names bound
  so far (a loaded module's `_private` names included). Inside a
  comprehension, its variables too (after the first iterable, as Python
  >= 3.12); they don't outlive it. Builtins are never listed.
- Code: compiler/ext/dir.star (hooks direct_call and dynamic_call).
- Compiled statically: a direct call `dir()` where `dir` is the builtin
  becomes one boundness test per name the scope can hold, appending its
  string constant. No frames or name tables at run time.
- Through a value too (`f = dir; f()`, `s.fn()`, `fns["dir"]()`): when
  the program mentions `dir`, every call through a value with no
  arguments first checks whether the callee is dir's function value
  (one ref.eq) and if so builds the list for that call site's scope,
  as Python does; otherwise it is an ordinary rt_call. Programs that
  never mention dir pay nothing. Not covered: `dir(*[])`/`dir(**{})`
  (whether arguments arrive is only known at run time; still "dir: got
  0 arguments, want 1"), and the prelude never calls a function with no
  arguments, so a builtin can't call dir on your behalf.
- In the REPL, `_` is a module variable, so it shows up once an
  expression has been entered (Python keeps it in builtins).
- Tests: tests/extensions/dir_scope.star (+ modules/dir_mod.star).
  dir_scope.out agrees with CPython 3.13 except that CPython also lists
  `__builtins__` at top level, and a top-level comprehension there sees
  only its own variables (CPython inlines comprehensions only inside
  functions; starwasm treats both alike).
