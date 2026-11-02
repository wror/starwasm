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
standard input, where each line assigns new values to reactive
variables (`width = 10`, `width = area(2, 3) + 1`, or `width = 6; height = 2`
to change several at once), and then recomputes every reactive variable that depends on them,
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

  is `a : struct(b = 123, c = 456, id = <previous a.id + 1>)` (the
  implicit `id` is described below). One field per line (newlines
  separate fields, not commas; a value can still span lines inside
  brackets), the dedent ends it, blank lines and comments are ignored. A
  field whose `:` ends its line opens a nested block, giving a nested
  struct. The parser builds the `struct(...)` call, so everything
  above applies unchanged: the same rules on where it may appear, field
  values may read reactive variables or the variable itself
  (self-reference), and errors are those of the call (a repeated field is
  `keyword argument "b" is repeated`). `struct` is looked up by name like
  any other, so a module that rebinds `struct` gets its own. A struct
  block only defines a reactive variable: there's no `a = ` form.
  Implicit `id`: a struct block with no field `id` gets one, the previous
  value's `id` + 1, read as in a self-reference (so 1 the first time); it
  counts how many times the struct has been computed (and, as it differs
  each time, a recomputed struct always counts as changed). Only that
  field is compiled as a self-reference: the block's own fields are
  compiled exactly as without it. With an explicit field `id` (constant or
  not, e.g. `id: a.id + 10`) nothing is added and the struct is exactly
  as written. Nested blocks get no `id`, nor does a plain
  `a : struct(...)`.
  Code: parser.star (`parse_struct_block`; it sets `implicit_id`) and
  reactive.star (`_next_id` adds the field). Tests:
  tests/extensions/reactive_struct.star, reactive_struct_id.star,
  reactive_struct_err_*.star.
- Relations: a struct block preceded by `a` or `an` (and whitespace)
  defines a *relation*, a reactive list of structs; the other reactive
  variables are *lone* ones.

      request:
        name: "foo"
        qty: 1
      an order:
        product: request.name
        size: request.qty
      a product_request:
        product: order.product
      response:
        name: order.product
        qty: order.size

  After `request = struct(id = 1, name = "foo", qty = 2)`, then the same
  with `id = 2, name = "bar", qty = 3` and with `id = 1, name = "foo",
  qty = 4`, `order` is `[struct(id = 2, product = "bar", size = 3),
  struct(id = 1, product = "foo", size = 4)]`, `product_request` is
  `[struct(id = 2, product = "bar"), struct(id = 1, product = "foo")]`
  and `response` is `struct(id = 1, name = "foo", qty = 4)`.
  - A relation starts empty, and its definition isn't evaluated on the
    first run: only an update (a change of what it reads) evaluates it.
    Each evaluation gives a member: if a member already has its `id`, that
    member is removed and the new one is added (at the end of the list),
    else the new one is just added. Either way the relation counts as
    changed (even if the member is the same as before), so what reads it is
    recomputed.
  - The member's implicit `id` is the triggering change's: the `id` of the
    first variable it reads that changed in this update and has a field
    `id`, else of the first one it reads that has one; lone variables and
    relations alike, so this carries through chains of relations. With no
    such variable (e.g. it reads only ints), it is the largest `id` in the
    relation + 1, i.e. a new member. With an explicit field `id`, the
    member is exactly as written.
  - References: when x is defined from y and y has a field named x +
    `_id` (for any names x and y), that field is y's id here instead of
    `id`, both for the implicit `id` and for which member is replaced
    and read as the self-reference. E.g. with `an account:` reading
    `deposit` (`struct(id = 3, account_id = 7, amount = 4)`), the deposit
    updates account 7 (tests/extensions/reactive_relation_ref.star).
  - Conditions: `a name when cond:` (or `an name when cond:`) + a struct
    block defines a relation that is updated by a condition instead of by
    matching ids:

        dingbat:
            b: "foo"
            c: "bar"
        a wally when dingbat.b == wally.e and not dingbat.b.startswith("a"):
            e: "foo"
            f: dingbat.c

    On an update (a change of what the condition or the block reads),
    cond is evaluated once per member, reading that member as the
    self-reference (`wally` above), and each member for which it is true
    is replaced by the block evaluated with the same self-reference; the
    new member's implicit `id` is the replaced one's. If it is true for no
    member, cond is evaluated once more with the self-reference reading
    the identity (as for a new member), and if that is true the block is
    added as a new member (implicit `id`: the largest + 1). So a condition
    that never holds of the identity (`dingbat.b == wally.e`, as `"foo" ==
    ""` is false) only updates existing members (e.g. members assigned on
    standard input), and one like `stock.name == item.name or stock.name ==
    ""` adds a member for a new name and updates it afterwards. The
    replaced and added members go at the end, in order; the relation
    counts as changed only if some member was replaced or added. The
    `_id` references above don't apply (the condition picks the members),
    and an explicit field `id` is used as written, even if another member
    has it. The condition is an ordinary expression. Standard input assigns such a relation
    as any other (by `id`). The original form (`a name:`, no `when`) is
    unchanged.
    Code: parser.star (`parse_struct_def` sets `when`), reactive.star
    (`transform` compiles cond and the block to two functions,
    `%r.<n>.when` and `%r.<n>.value`, called by `_r_when`). Tests:
    tests/extensions/reactive_relation_when.star,
    reactive_relation_err_when_block.star, the end of tests/repl/session.in.
  - Read in a definition, a relation is its *current member*, the one
    last added. Read in an observer (a top-level expression statement, or
    an expression typed in the REPL), it is the list of members.
  - A lone struct block that reads a relation is always "updated" by the
    relation's member: its implicit `id` is the current member's id of the
    first relation it reads that changed (else of the first one it reads),
    whatever its id was before.
  - Unset: while a relation has no member, a definition that reads it
    isn't evaluated, so a lone variable computed from it (directly or
    through other variables) is unset, and so is everything computed from
    that. Definitions and observers that read an unset variable are
    skipped (on the first run and in updates) until it is set. (Observers
    reading only the relation itself run: its list is always set.)
  - Self-reference in a relation reads the member being replaced: the one
    with the triggering change's `id`, or the identity if there is none
    (the member is new). So `balance: account.balance + deposit.amount`
    keeps a balance per id.
  - Standard input can assign a relation (`order = struct(id = 3, ...)`):
    the value is added as a member like an evaluated one, and must have a
    field `id`.
  - Only struct blocks can be relations: `an x : expr` is an error, "a
    relation (an x) must be defined by a struct block".
  - In the REPL, the echo of a relation computed from others prints the
    member just added (`order = struct(id = 1, ...)`), on every update that
    adds one. Typing a variable that is unset prints nothing.
  - Code: parser.star (`starts_relation`, `parse_struct_def`; it sets
    `relation`), reactive.star (`transform`; at run time `_r_relation`,
    `_r_upsert`, `_r_tid`, `_r_rel_id`, `_r_lone_id`, `_r_rel_self`,
    `_r_ready`). Values: `%reactive["x"]` is the current member (the
    prelude's `_unset` while there is none, as for unset lone variables),
    `%reactive["x[]"]` the list; each update builds a new list, so a failed
    update restores the old one. Each node in `%nodes` also lists the
    variables it reads that may be unset, and runs only when they are set.
    Tests: tests/extensions/reactive_relation*.star, the end of
    tests/repl/session.in.
- First run: the program runs top to bottom as written; `x : e` just sets
  x there. Errors and tracebacks are those of the same program with `=`.
- Input lines: `name = expression` (`:` also works), several separated
  by `;`; blank lines and `#` comments are ignored. The expression may be
  any Starlark expression except a lambda (literals of every kind,
  operators, `x if c else y`, calls with keyword and `*`/`**` arguments,
  indexing, slices, attributes and methods, list/tuple/dict displays and
  comprehensions) that doesn't refer to a reactive variable. It can use
  the program's other top-level names (defs, variables, loaded names; their
  values at the time) and the builtins abs, all, any, bool, bytes, chr,
  dict, enumerate, fail, float, getattr, hasattr, hash, int, len, list,
  max, min, ord, print, range, repr, reversed, set, sorted, str, tuple,
  type, zip (and struct, if the program mentions it). Any reactive
  variable can be set, derived ones too; a derived one keeps that value
  until something it depends on changes. A line that isn't valid (not a
  reactive variable, syntax, an undefined name, a reactive variable in
  the expression) is reported on stderr as `<stdin>:line:col: message`
  and ignored. An error while evaluating the expressions is reported like
  an error while recomputing (below); nothing is assigned.
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
- In the REPL (host/repl.mjs), an input assigning to reactive variables
  (`x = 5`, `x = f(2)`) is sent to the program as a line of standard input.
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
    string, added to the prelude) reads lines, parses the expressions (a
    small recursive-descent parser in Starlark), evaluates them (a tree
    walker, `_r_eval`) and propagates changes over `%nodes`. Expressions
    see top-level names through `%rnames`, a dict of `name: lambda: name`
    built at the start of the top level; since it mentions getattr, every
    method is kept as a value in such programs (as `getattr(x, name)`
    would), so `_attr` can call any method.
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
