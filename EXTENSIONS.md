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
  or None to leave the call to the core. Whole-program hooks run once per
  compilation (after parsing, when declaring host imports and runtime
  functions, when building the prelude), `EXT_INTRINSICS` adds primitives
  that only the prelude can call, and generated code may call any prelude
  function, private ones too, as `%prelude.<name>`. A new
  extension that needs another point adds a hook there; helpers it needs
  from codegen are passed in the `cg` dict (`CG` in codegen.star).
  Runtime support, if any, goes in the extension file or in the prelude
  next to the builtin.
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

## Reactive variables

    load("shapes.star", "area")

    width : 3                 # reactive variables: `name : expr`
    height : 4
    size : area(width, height)
    print("size is", size)

A variable defined at top level with `:` instead of `=` is *reactive*. A
program that has any doesn't exit at the end of its top level: it reads
standard input, where each line assigns literal values to reactive
variables (`width = 10`, or `width = 6; height = 2` to change several at
once), and then recomputes every reactive variable that depends on them,
transitively, and re-runs every top-level expression statement that reads
one of them (`print("size is", size)` above). It stops at the end of
standard input.

- Rules, checked at compile time:
  - Reactive variables are defined only at the top level of the main file,
    once each, and nothing else (assignment, `for`, `def`, `load`) may bind
    the name.
  - Functions (defs and lambdas, at any depth) may not refer to a reactive
    variable: they get reactive values as arguments, so what a computation
    depends on is visible at top level. A parameter or local of the same
    name is fine.
  - At top level, a reactive variable may be read only in a reactive
    definition or in an expression statement (not in `w = x + 1`, a
    default value, an `if` or a loop: those would run once and silently go
    stale), and only after its definition (or in it: see self-reference
    below). So there are no cycles, and source order is a valid order for
    recomputing.
- Self-reference: a definition may read the variable it defines, e.g.
  `total : total + n` or, with `b : "foo"`,
  `a : struct(x = (a.x + 1) + (a.x * 10), y = str(a.y + b))`. It reads the
  value from when the variable was last computed (it is not a dependency
  of itself). The first time there is none, and it reads as the
  *identity*: a value that becomes the identity element of whatever it is
  combined with: 0 for `+ - | ^ << >>` and comparisons with numbers (`""`,
  `b""`, `[]`, `()`, `{}`, `set()` with strings, bytes, lists, tuples,
  dicts, sets), 1 for `* / // %`, -1 for `&` (or the set itself); its
  attributes, elements, slices and method results are the identity too;
  it is false (`not`, `if`, conditional expressions); iterating over it
  gives nothing; `str`, `repr`, `int`, `float`, `bool`, `len`, `list`,
  `tuple`, `dict` of it give that type's empty value; two identities
  combine to the identity. So the example's `a` starts as
  `struct(x = 11, y = "foo")`, and becomes `struct(x = 122, y = "foobar")`
  after `b = "bar"`. A value can still end up holding the identity itself
  (`a : [a]`); it prints as `<built-in function _identity>`.
  - Compiled with no change to the core: in a self-referencing definition
    (only), every operation becomes a call of a prelude function
    (`_r_binop`, `_r_attr`, `_r_index`, `_r_truth`, ...: Starlark, in
    RUNTIME) that handles the identity and otherwise does the operation;
    a method call `x.m(...)` becomes
    `[_identity if _is_id(%m) else %m.m(...) for %m in [x]][0]`. Reads of
    the variable become `_r_self(%reactive, "a")`. Error messages are the
    usual ones (the host doesn't name private prelude functions, `_...`,
    as builtins in tracebacks).
- Struct blocks: a definition whose `:` ends the line, followed by an
  indented block of `field : value` lines, is sugar for a struct:

      a:
        b: 123
        c: 456

  is `a : struct(b = 123, c = 456)`. One field per line (newlines
  separate fields, not commas; a value can still span lines inside
  brackets), the dedent ends it, blank lines and comments are ignored. A
  field whose `:` ends its line opens a nested block, giving a nested
  struct. The parser builds exactly the `struct(...)` call, so everything
  above applies unchanged: the same rules on where it may appear, field
  values may read reactive variables or the variable itself
  (self-reference), and errors are those of the call (a repeated field is
  `keyword argument "b" is repeated`). `struct` is looked up by name like
  any other, so a module that rebinds `struct` gets its own. A struct
  block only defines a reactive variable: there's no `a = ` form.
  Code: parser.star (`parse_struct_block`). Tests:
  tests/extensions/reactive_struct.star, reactive_struct_err_*.star.
- First run: the program runs top to bottom as written; `x : e` just sets
  x there. Errors and tracebacks are those of the same program with `=`.
- Input lines: `name = literal` (`:` also works), several separated by
  `;`; blank lines and `#` comments are ignored. Literals: None, True,
  False, ints (decimal, 0x, 0o, 0b; a sign is allowed), floats, strings
  and bytes (quotes, triple quotes, r/b prefixes, Starlark's escapes), and
  lists, tuples and dicts of literals. Any reactive variable can be set,
  derived ones too; a derived one keeps that value until something it
  depends on changes. A line that isn't valid (unknown name, not a
  literal, syntax) is reported on stderr as `<stdin>:line:col: message`
  and ignored.
- Updates: the assigned variables count as changed. Then each reactive
  definition and observing expression statement is visited in source
  order; one that reads a changed variable is recomputed (re-run). A
  recomputed variable counts as changed only if its new value differs
  (`!=`) from the old, so `big : size > 20` stops propagation when it
  stays the same.
- Errors during an update are reported with a traceback on stderr (the
  frame of the definition or statement shows as `<toplevel>`), every
  reactive variable gets back its value from before the line, and the
  program carries on with the next line. Output already printed by
  observers during that update stays printed.
- In the REPL (host/repl.mjs), an input assigning literals to reactive
  variables (`x = 5`) is sent to the program as a line of standard input.
  Replay keeps it in the session as an update and delivers it right after
  the inputs it followed (see sync points below), so later inputs see the
  new value. A failing update is not kept. Updates don't recompile
  anything: a session with reactive variables runs in a worker
  (host/repl_worker.mjs) that stays alive at the end of its top level,
  waiting for input, and the REPL just sends it the line. (After a failed
  update that program is dropped, and the next input replays the session
  to get a new one.) Whenever a reactive variable
  computed from others is recomputed to a new value, the REPL prints it
  as `name = value` (e.g. `b = 12` after `a = 2`, with `b : a + 10`), via a
  hidden observer it adds after the definition; variables defined by
  literals change only when assigned, which isn't echoed. An expression
  typed at the prompt is evaluated once, like any other, even if it reads
  reactive variables (it can't be saved in `_`, though).
- Code: compiler/ext/reactive.star (hooks transform, imports, runtime,
  prelude; parser.star parses `name : expr` as a "reactive" statement). Nearly all of it is Starlark:
  - At compile time, on the AST: the checks above, then a rewrite of the
    main module. The values live in a dict (module variable `%reactive`;
    `%` names can't be written in source); reads of x become
    `%reactive["x"]`; `x : e` becomes `%reactive["x"] = e` in place; each
    definition or observing statement that reads reactive variables also
    gets a function `%r.<n>` evaluating a copy of its expression, appended
    right after it to `%nodes` as (name or None, function, names read), so
    `%nodes` lists what has run so far, in source order. The last
    statement calls `%prelude._reactive_input(..., 0)`.
  - Sync points: each top-level statement after the first reactive
    definition is preceded by `_reactive_input(..., L)` (L: its line),
    which applies the input lines the host says are due before line L.
    host/run.mjs has none due (all input comes after the top level); the
    REPL uses them to deliver each update after the code entered before
    it.
  - At run time: `_reactive_input` (Starlark, in the extension's RUNTIME
    string, added to the prelude) reads lines, parses the literals (a
    small recursive-descent parser in Starlark), and propagates changes
    over `%nodes`.
  - Wasm and host: three primitives only the prelude sees:
    `_read_line(before)` (host import read_line, from the host's
    `readLine(before)`: host/run.mjs reads stdin synchronously in its
    worker, the REPL serves the session's updates), `_eprint(s)` (stderr),
    and `_try(f)` (host import try_call, which calls f through the
    `reactive_call0` export inside a JS try/catch and prints the Starlark
    error's traceback, cut to the frames inside f).
  - Programs without reactive variables pay nothing: the imports,
    primitives and runtime are only added when the main file has one.
- Dialect: reactive variables work the same in starlark-go's default
  dialect (no rebinding top-level names, no while, no top-level if/for, no
  recursion) and with `--globalreassign` and/or `--recursion`. A reactive
  variable is never a module variable (its definitions become
  `%reactive["x"] = ...`), so defining one is not a top-level binding; the
  rewrite binds each of its own top-level names once and adds no
  top-level control flow, and the runtime (`_reactive_input` and the `_r_`
  helpers) is in the prelude, which is always compiled with every option
  on. The rule that nothing else binds the name holds in every mode; with a
  plain binding first (`x = 1` then `x : 2`, or a struct block) the error
  is "cannot define reactive variable x: x is already bound", at the
  definition. test.sh runs tests/extensions.sh in the default dialect and
  with `--globalreassign`.
- Not covered: dependency cycles (impossible as written, since a variable
  must be defined before it is read); reactive variables in loaded
  modules; dir() at top level doesn't list reactive variables; a loop or
  comprehension cut short by an error in an update leaves its list or
  dict marked as being iterated (as test_catch does), so later mutations
  of it fail.
- Tests: tests/extensions/reactive_basic.star (with .in input and .err
  expected stderr; modules/reactive_mod.star), reactive_self.star
  (self-reference), reactive_eof.star, and
  reactive_err_*.star (compile errors). tests/extensions.sh now feeds
  `<name>.in` as standard input, compares stderr with `<name>.err`, and
  treats a test starting with `# error: <text>` as a compile-error test.
  REPL updates: the end of tests/repl/session.in.
