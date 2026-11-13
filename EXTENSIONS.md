# starwasm extensions

Features starwasm has that starlark-go doesn't. The rest of starwasm aims
to behave exactly like starlark-go (NOTES.md); everything here is a
deliberate difference, kept apart so the compatible core stays easy to
see and to check.

## Where things go

- **Code:** one file per extension, `compiler/ext/<name>.star`, registered
  in `compiler/extensions.star` (the type checker, which is a program of
  its own rather than part of the compiler, is in `typecheck/`). `codegen.star` names no extension: it
  calls the hooks in `extensions.star` at fixed points (a call of a name, a
  call through a value; every expression, condition, assignment and
  statement), and an extension either returns the code to emit
  or None to leave it to the core. Whole-program hooks run once per
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
- Freezing: once the first run reaches the end of the top level, the main
  module is frozen, as a loaded module is once it has run: every
  non-reactive top-level variable and function is deep-frozen (lists,
  dicts, sets, structs, function defaults, closures' captured variables).
  So what updates run (definitions, observers, the functions they call,
  input expressions) can't mutate non-reactive state: `log.append(x)` in
  an observer fails with "append: cannot append to frozen list", like any
  update error (reported, rolled back). The first run itself mutates
  freely, and so may updates applied at sync points before the end (the
  REPL's replay: an update that succeeded live, frozen, also succeeds
  there). Reactive values aren't frozen unless they are (or hold)
  non-reactive values, and new values made in an update are mutable.
  Code: transform adds `%prelude._r_freeze()` before the final
  `_reactive_input(..., 0)`; reactive.star's `direct_call` hook compiles
  it to `rt_freeze` of each of the main module's globals and function
  values, except the runtime's `%` variables. Test:
  tests/extensions/reactive_frozen.star.
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
- Errors during an update: by default (contagious None, below, is on in a
  program with reactive variables) an error doesn't fail the update: it
  is printed with its traceback on stderr, and what failed gives a None
  that carries the error; see "Errors in a reactive program" below. With
  `--nocontagiousnone` an error ends the update instead: it is reported
  with a traceback on stderr (the frame of the definition or statement
  shows as `<toplevel>`), every reactive variable gets back its value
  from before the line, and the program carries on with the next line;
  output already printed by observers during that update stays printed.
- Journal: `node host/run.mjs --journal=FILE prog.star` (or `prog.wasm`)
  appends every line of standard input to FILE (each with `\n`, synced
  to disk before the line is applied, so nothing applied is missing from
  it), and at the start replays FILE's lines before reading standard
  input, so a restarted program gets back the state it had (and prints
  again what those updates printed; `<stdin>` line numbers continue). Only
  lines ending in `\n` are replayed: anything after the last one may be a
  line cut short (a crash mid-write) and is removed from FILE before
  anything is appended. If a line can't be journaled, it's cut back off
  and the program stops (an internal error, exit status 3) without
  applying it. Programs without reactive variables never open FILE. Code:
  `journaled` in host/run.mjs; test: tests/journal.sh.
- In the REPL (host/repl.mjs), an input assigning to reactive variables
  (`x = 5`, `x = f(2)`) is sent to the program as a line of standard input.
  Replay keeps it in the session as an update and delivers it right after
  the inputs it followed (see sync points below), so later inputs see the
  new value. A failing update is not kept (with
  contagious None, the default here, an update doesn't fail on an error:
  the REPL shows the traceback, and the variables that couldn't be
  computed are echoed as None). Updates don't recompile
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

## Contagious None

    x = None
    x + 1          # None
    x.foo          # None
    x > None       # None
    x == x         # None
    abs(x)         # None
    x == None      # True
    x != None      # False
    provenance(x)  # [("literal", "None", "prog.star", 1)]

Three things about None: an operation on it gives None instead of an
error; a None knows where it comes from; and in a reactive program, once
it is running, every error becomes such a None.

### Errors in a reactive program

**A reactive program doesn't stop on an error once its first run is
done.** (This is the default: contagious None is on in every program with
reactive variables, unless it is compiled with `--nocontagiousnone`.)

    def ratio(a, b):
        return a // b            # line 2

    n : 4
    half : ratio(100, n)         # line 5
    print("half is", half)

Sending `n = 0` on standard input prints, on stderr,

    Traceback (most recent call last):
      prog.star:5:13: in <toplevel>
      prog.star:2:14: in ratio
    Error: floored division by zero

and on stdout `half is None`; the program then waits for the next line,
and `n = 5` prints `half is 20`.

- When: during updates, i.e. whenever a line of standard input (or, in
  the REPL, an assignment to a reactive variable) is being applied: the
  expressions on the line, the definitions that are recomputed, the
  observers that are re-run, and every function they call. The first run
  of the top level is as in any program: an error there is an error, the
  program exits with it, since a program that can't start has nothing to
  keep running. (In a program without reactive variables that turns
  contagious None on, only errors caused by a None are caught: see "None
  further in" below.)
- What: every Starlark error: a division by zero, an index out of range,
  a key not in a dict, a wrong type, a missing field or method, a wrong
  number of arguments, a failed unpacking, a frozen value, `fail(...)`,
  too deep a recursion.
- What it becomes: the smallest thing around the error that can be
  given a value gets None, and the computation goes on from there, with
  the None contagious as ever:
  - an operator, an index, a slice, a field, a builtin call: that
    expression is None (`100 // n` above);
  - anything else in a function (a statement: an unpacking, an
    assignment to a frozen list, `fail`): the call of that function is
    None;
  - anything else in a definition: the variable is None; in an observer
    (a top-level expression statement): the statement stops there, and
    the update goes on with the next one; in a relation's struct block
    or condition: no member is added or replaced;
  - an expression on standard input: the variable is assigned None.

  So nothing is rolled back (unless `--rollback` says so, below): the variables that could be computed have
  their new values, and the ones that couldn't are None until an update
  makes them computable again.
- Rollback, if asked for: with the compiler option `--rollback`
  (compiler/main.star, host/run.mjs, host/repl.mjs; a test's
  `# option:rollback`), an update in which any error was caught is undone
  once it has run: every reactive variable gets back the value it had
  before the input line, so the program's state is that of the last
  update without errors. The update still runs to its end first: every
  error is printed, and the observers that ran saw the Nones (what they
  printed stays printed); only the values are put back. Without the
  option (the default) nothing is undone. `--rollback` does nothing
  without contagious None (`--nocontagiousnone` always undoes a failed
  update, at its first error). Code: the runtime counts the errors
  caught during updates (`catch_count`), and `_reactive_input` restores
  its saved values if the count moved (`_n_failed`). Test:
  tests/extensions/none_reactive_rollback.star.
- The original error, for the programmer, in two places:
  - on stderr, when it happens: the same traceback and message as if it
    had ended the program (above);
  - in the None: its trace starts with the entry
    `("error", message, file, line)`: the error's message, and the file
    and line of the innermost frame of that traceback, i.e. where it
    happened. So `provenance(half)` above is
    `[("error", "floored division by zero", "prog.star", 2),
    ("function", "ratio", "prog.star", 2), ("reactive", "half",
    "prog.star", 5)]`: what went wrong and where, then how the None got
    here. A program can act on it:

        cause : [e for e in provenance(half) if e[0] == "error"]
        print("half failed:", cause[0][1]) if cause else None

    For an expression on standard input the place is `<stdin>` and the
    input's line number. An error in a condition (`if xs[9] > 1:`) or in
    an observer has no value to live in: it is only on stderr.
- What can still stop it: an error in the first run; an internal error
  (a Wasm trap, such as the engine's own stack overflowing: exit status
  3); the end of standard input, which is how it ends normally. A line
  of input that isn't valid (syntax, an unknown variable) is reported and
  ignored, as before.
- Left as it was by an error: output already printed; changes already
  made to mutable reactive values (a list appended to before the error);
  and a `for` loop cut short by an error leaves the list or dict it was
  over marked as being iterated, so later changes to that value fail
  (and give None).

### The rest

- Activation: on by default in a program with reactive variables (above),
  off in any other. The compiler options `--contagiousnone` and
  `--nocontagiousnone` (compiler/main.star, host/run.mjs, host/repl.mjs; a
  checkbox in the browser REPL) turn it on or off whatever the program
  has. It applies to the whole program: the main file and the modules it
  loads. Off, None is starlark-go's and `provenance` is undefined.
- Contagion: the result of an operation with a None operand is that None
  (the first one, left to right; the operands are all evaluated, and the
  operation itself isn't done). No operation on None stops the program.
  - Operations: the binary operators (arithmetic, `%`, bitwise,
    comparisons, `in`, `not in`), the unary ones (`-`, `+`, `~`, `not`),
    `x.name`, `x[i]`, `x[i:j:k]` (x or a bound that is written), a call
    `x(...)` or `x.method(...)` of None, `f(*x)` and `f(**x)`, and a call
    of a builtin function or method with a None argument: `abs(x)`,
    `len(x)`, `str(x)`, `type(x)`, `bool(x)`, `"a,b".split(x)`,
    `",".join(x)` are all None, and the builtin isn't called.
  - The one exception: `==` and `!=` when an operand is `None` written
    out. `x == None` is True and `x != None` False if x is None; they are
    how a program tells. Any other comparison is an operation: `x == x`,
    `x == y` and `x != 1` are None when x is.
  - Not operations: `x and y`, `x or y` and `a if x else b` choose an
    operand, with None false as ever (so `x or default` replaces a None);
    `if x:`, `while x:` and a comprehension's `if x` just don't run. As an
    operation on None is None, hence false, `if x > 1:`, `if x != 1:` and
    `if not x:` don't run either when x is None: only `x == None` is true
    of it.
  - Storing, printing or passing a None is no operation: `[x]`, `{k: x}`,
    `y = x`, and calling a def (or lambda) with it: the function runs,
    and what its body does with the None follows these rules. The same
    for the arguments a builtin only stores, prints or gives back:
    `print(x)` prints None, `l.append(x)`, `l.insert(i, x)`, `s.add(x)`,
    `d.get(k, x)`, `d.setdefault(k, x)`, `d.pop(k, x)`,
    `getattr(o, name, x)`, `struct(a = x)`, `dict(a = x)`,
    `d.update(a = x)`, `fail(x)` (which fails, as asked) and
    `provenance(x)` (`TOLERANT` in none.star). Through a value
    (`f = abs; f(x)`, `m = l.append; m(x)`) it is the same, decided when
    the call happens: a builtin isn't called, a def is.
  - Statements: `for v in x` (and a comprehension's `for`) runs no
    iteration; `a, b = x` gives each target that None; `x[i] = v` and
    `x.name = v` do nothing when x is None, nor does `l[x] = v` (but
    `d[x] = v` stores under the key None, in a dict); `y += x` makes y
    None.
- None further in: a None inside a container handed to a builtin or an
  operator doesn't stop the program either, in any program with
  contagious None, first run included. `sorted([1, None])`,
  `max(l)`, `",".join(["a", None])`, `"%d" % (None,)`, `[None] < [1]`,
  `abs(*[None])`, also through a value (`f = sorted; f(l)`): what would
  fail because of the None gives None instead (false, in a condition),
  silently; the None carries the error it replaced (`"error"`, below).
  The builtin does run, up to the failure: a callback (`key = f`) may
  have been called, and a list it was changing may be half changed.
- Provenance: `provenance(v)` returns what a None passed through, oldest
  first, as a list of tuples `(kind, id, file, line)`; `[]` for anything
  that isn't None. The kinds:
  - `"literal"`, id `"None"`: where it was written (`<stdin>` and the
    input line, on a reactive program's standard input);
  - `"function"`, id the function's name (`"lambda"` for a lambda): the
    line of the `return` it left by; for a function that returns nothing,
    which is where a None starts, the line of the bare `return`, or of the
    `def` if it ran off the end;
  - `"builtin"`, id the builtin function's or method's name: the line of
    the call that returned it (`d.get(k)` with no such key, `l.append(1)`,
    or a None that was stored and is given back);
  - `"error"`, id the error's message: an error that was turned into
    this None, with the file and line where it happened (the innermost
    frame of its traceback). It is the first entry of the trace: the
    None starts there. See "Errors in a reactive program" above, and
    "None further in";
  - `"reactive"`, id the reactive variable: the line of its definition,
    each time it is computed to None; for a field of a struct block,
    `"order.cost"` and the field's line; and file `<stdin>` with the input
    line, when it is assigned there.

  For example, with `price : prices.get(item)` on line 13 and
  `total : double(price) * qty` on line 14, `provenance(total)` is
  `[("builtin", "get", "prog.star", 13), ("reactive", "price",
  "prog.star", 13), ("function", "double", "prog.star", 5), ("reactive",
  "total", "prog.star", 14)]`. An operation adds nothing: `x + 1` is x,
  trace and all. Each entry is listed once, where the None first passed:
  a None going round a loop, or a reactive variable recomputed from
  itself, doesn't grow. A None from elsewhere (inside the prelude, say a
  missing optional result) has an empty trace until it passes through
  something.
- With reactive variables: a None doesn't fail an update, and nor does
  an error (above); the None flows
  through the definitions and observers that read it. Expressions on
  standard input are contagious too (`qty = None + 1` assigns None).
  A variable recomputed to a None that came another way than the one it
  held counts as changed, so what reads it is recomputed and holds the
  current trace. In a self-referencing definition (`total : total + n`)
  None wins over the identity.
- Code: compiler/ext/none.star.
  - transform decides whether it is on, then marks the ASTs of the
    user's modules: return values and lambda bodies (they pass through
    the function), an added `return` at the end of each def, the values
    reactive.star notes as a variable's (`defines`), loops' iterables.
  - The hooks expr, cond, assign and stmt (new hook points, called for
    every expression, condition, assignment and statement) put the test
    in front of each operation: the operands are evaluated into Wasm
    locals and tested with `ref.test`, and codegen compiles the operation
    itself from a copy of the node whose operands read those locals. So
    the core's code, errors and positions are unchanged, and a program
    whose values are never None prints exactly what it does without the
    extension. The prelude is compiled as ever, so builtins written in
    Starlark keep their meaning; the tests are in the callers.
  - A None is a `$NoneType {via, prev}` struct: `via` the entry it last
    passed through, `prev` the None it was before. The plain None, the
    only one when the extension is off, has neither; so the core's "is
    None" is a type test now rather than `ref.eq` with the global, and
    all Nones are equal to each other in the prelude and inside
    containers. `rt_none_via(v, entry)` makes the new None; entries and
    the Nones that start at a place are created once, in globals.
  - Catching: each operation (operators, index, slice, field), builtin
    call, call of a def and call through a value in the user's modules
    runs in a Wasm `try` (`_protect`), with the global `catch_depth`
    raised. While it is, `rt_fail_ex`, where every runtime error ends
    up, doesn't end the program if the message mentions `NoneType` (as
    every error about a None does) or if the global `catch_all` is set:
    it asks the host for the place (host import `caught`, which maps the
    stack to source positions as for a traceback, and prints the
    traceback if `catch_all`), and throws `("error", message, file,
    line)` (exception tag `$caught`). The `catch` makes the None from
    it, and puts back the call depth and the iteration counts of the
    arguments (a builtin cut out of a loop over a list would leave it
    unchangeable). `catch_all` is set by `rt_none_try` (the prelude's
    `_n_try`), which the reactive runtime uses to evaluate each input
    expression, definition and observer of an update, and which is the
    outermost `try`: what no inner one caught makes that whole
    evaluation None. Outside a `try`, and for other messages when
    `catch_all` isn't set, errors and their tracebacks are as ever. The
    encoder (lib/wasm.star) gained tags and `try`/`catch`/`throw` (the
    legacy exception-handling opcodes, which Node 22 and current
    browsers run).
  - Calls through values ask `rt_none_skip` whether the callee is a
    builtin given a None it doesn't just store. The reactive runtime's
    runtime calls the prelude's `_n_none`, `_n_skip`, `_n_tag`,
    `_n_changed`, `_n_try` and `_n_try_at`, which do nothing when the
    extension is off.
- Not covered:
  - Inside containers all Nones are equal: `[x] == [None]` is True (its
    operands are lists), and a dict display with two keys that are both
    None fails as a repeated key.
  - Outside updates, errors that aren't None's doing are errors still,
    also when a None is around: `sorted([1, "a", None])` may fail on
    `int < string`, and `[1, 2].index(x)` with x None is "value not in
    list".
  - Arguments for which starlark-go reads None as "not given"
    (`s.split(None)`, `s.find(t, None)`, a slice bound) are operations
    here: the result is None.
  - A builtin's result gets a `"builtin"` entry only when it is called by
    name (`d.get(k)`, `len(x)`), not through a value.
  - The type checker (below) knows nothing of it.
  - Programs compiled without it pay one thing: None is tested by type.
    With it, each operation tests its operands, and a function's None
    result allocates a small struct the first time it leaves by a given
    `return`.
- Tests: tests/extensions/none_basic.star (contagion),
  none_provenance.star (+ modules/none_mod.star), none_reactive.star
  (the default, with reactive variables and standard input),
  none_nested.star (None inside containers), none_reactive_errors.star
  (errors during updates, with their tracebacks in the .err file),
  none_reactive_off.star (`--nocontagiousnone`), none_err_provenance.star;
  tests take the options from `# option:contagiousnone` /
  `# option:nocontagiousnone` lines.

## Static types

    node host/typecheck.mjs prog.star          # check; writes prog.starit
    node host/typecheck.mjs --print prog.star  # ... or prints the types

A type checker for Starlark programs: it infers the type of every
variable and function of `prog.star` without any annotation, reports the
places where the types don't fit, and writes what it inferred to
`prog.starit`. The programmer may state types in a third file,
`prog.start`: the program is then checked against them. The program
itself is never touched (it stays plain Starlark that starlark-go runs),
and the compiler doesn't use the types: checking is a separate, optional
step.

    # inventory.star
    def restock(item, n):
        return item + struct(qty = item.qty + n)

    def value(items):
        total = 0.0
        for it in items:
            total += it.qty * it.price
        return total

    def column(table, field):
        return [getattr(row, field) for row in table]

    stock = [
        struct(name = "bolt", qty = 100, price = 0.25),
        struct(name = "nut", qty = 250, price = 0.1),
    ]
    worth = value(stock)
    names = column(stock, "name")
    more = restock(stock[0], 50)

    # inventory.starit, as inferred
    def restock[T: Add[U, V], U, V, **R](item: struct[qty: T, **R], n: U) -> struct[qty: V, **R]
    def value[T: Iterable[struct[qty: U, price: V, **R]], U: Mul[V, float], V, **R](items: T) -> float:
        total: float
        it: struct[qty: U, price: V, **R]
    def column[T: Iterable[struct[L: U, **R]], L: str, U, **R](table: T, field: L) -> list[U]
    stock: list[struct[name: str, qty: int, price: float]]
    worth: float
    names: list[str]
    more: struct[qty: int, name: str, price: float]

    # inventory.start, optional: what the programmer wants them to be
    type Item = struct[name: str, qty: int, price: float]
    def value(items: list[Item]) -> float
    stock: list[Item]

With that `.start` file, `value` is `(items: list[struct[name: str, qty:
int, price: float]]) -> float` in the `.starit` file, and its body and
every call are checked against that. A mistake such as `column(stock,
"prise")` is reported as

    inventory.star:20:24: error: argument 'field' of column(): expected struct[prise: _, ...], got struct[name: str, qty: int, price: float]: no field 'prise' (did you mean 'price'?)
       20 | prices = column(stock, "prise")
          |                        ^
    inventory.star:11:44: note: required here (comprehension over it)
       11 |     return [getattr(row, field) for row in table]
          |                                            ^
    inventory.star:11:26: note: field 'prise' comes from here (field name of getattr())
       11 |     return [getattr(row, field) for row in table]
          |                          ^

### The type system

Hindley-Milner inference (unification, let-polymorphism for `def`s), with
the record calculus of Adam Paszke and Ningning Xie, "Infix-Extensible
Record Types for Tabular Data" (TyDe '23), for structs; Max Bernstein's
"Adding row polymorphism to Damas-Hindley-Milner" is a gentler
introduction to rows. Subtyping is not part of it: there are no union
types (but see None below) and no classes; types are structural.

- **Basic types**: `int float str bytes bool None`, `list[T]`, `dict[K,
  V]`, `set[T]`, `range`, tuples `tuple[A, B]` (`tuple[()]`, and `tuple[T,
  ...]` for any length) and functions `(A, name: B = ..., *args: C) -> R`.
  A variable has one type in its scope, a list one element type, and so
  on: `[1, "a"]`, or `x = 1` followed by `x = "s"`, are errors.
- **Structs are records over rows**: `struct(x = 1, y = "a")` is a
  `struct[x: int, y: str]`, and the order of fields with different names
  doesn't matter. A function that reads `p.x` takes any struct with a field
  `x`: its parameter is `struct[x: T, **R]`, where the *row variable* `R`
  stands for the other fields, whatever they are, and comes back in the
  result if the struct does (`restock` above): row polymorphism.
  - *Concatenation, anywhere*: `a + b` is the struct of the fields of both
    (starlark-go's struct `+`), and its type is the rows of both, `b`'s
    first: `r + struct(tag = "t")` is `struct[tag: str, **R]`, and
    `struct(id = 0) + r` is `struct[**R, id: int]`, a row variable
    *before* a field (the paper's infix extension). Fields move past
    fields of other names, never past a row variable.
  - *Scoped labels*: where two fields have the same name, the first is the
    one the struct has: in `a + b`, `b`'s. So `(point + struct(x =
    "one")).x` is a `str`. And `(struct(id = 0) + r).id` is an error: `r`
    may have an `id` of its own, of another type (the paper rejects it
    likewise; the message says so). Unlike the paper, a shadowed field is
    dropped from the type: Starlark has no way to remove a field, so it
    can never be seen again. `struct[x: str, x: int]` is `struct[x: str]`.
  - *Field names are values* (first-class labels): a string literal has
    type `Literal["name"]` where a field name is wanted, and `getattr(r,
    field)` with a `field` that is a variable gives `field` the type `L`,
    a field name parameter, and `r` the type `struct[L: T, **R]`
    (`column` above). `getattr(r, "name")` is `r.name`; with a string
    that is not known (or a default: `getattr(r, name, d)`), the result
    is `Any`. `hasattr` tells the checker nothing.
  - The paper's first-class rows (records of labels, to project or
    remove several fields at once) have no counterpart in Starlark.
- **None**: a value that may be None has type `T | None`, and a `T` is
  accepted where a `T | None` is wanted, but not the other way round: it
  must be tested first. A variable assigned `None` somewhere, a parameter
  with default `None`, a function that returns a value on some paths and
  nothing on others, `d.get(k)`, and anything compared with `None` are
  optional. Tests narrow: after `if x != None:`, `if x:`, `x != None and
  ...`, `x if x else ...`, an early `if x == None: return` (or `fail`,
  `break`, `continue`), or an assignment of a non-None value, `x` is a
  `T`. Only variables are narrowed (not `p.x`), and only by these forms.
- **Numbers**: an `int` is accepted where a `float` is wanted. An int
  literal is an `int` unless it is put where a float is kept: after `total
  = 0`, `total += 1.5` makes `total` a float; `[1, 2.5]` is a
  `list[float]`.
- **Polymorphism**: a `def`'s type is generalized over what its body
  doesn't fix, and each use gets its own copy (`identity`, `first`).
  Defs may be used before they are defined and may be recursive; defs
  that call each other in a cycle are generalized together. Only defs are
  polymorphic: a lambda or a variable has one type.
- **Bounds**: operators and builtins work on several types (`+` on
  numbers, strings, lists, tuples, structs; `len`; `for`; `x[i]`; `in`).
  Where a def uses one on a value whose type is otherwise free, that
  becomes a *bound* of the type parameter, checked at each call: `def
  size(x): return len(x)` is `def size[X: Sized](x: X) -> int`. The
  bounds: `Iterable[E]`, `GetItem[K, V]`, `SetItem[K, V]`, `Container[E]`
  (`in`), `Sized`, `Sliceable[S]`, `Ordered` (`<`), `HasAttr["name", T]`
  (a method that several builtin types have, such as `pop`), `(int,
  float)` (one of these types), and the operators `Add[B, R]` (`x + B`
  is an `R`; likewise `Sub Mul Div FloorDiv Mod Or And Xor LShift
  RShift`, and `RAdd[A, R]` etc. for the right operand). One exception
  keeps common code simple: an operand of unknown type next to a number
  is taken to be a number of that type (`def inc(x): return x + 1` is `(x:
  int) -> int`; `x / 2` makes `x` a float), so write `x + 1.0`, start a
  float sum at `0.0`, or annotate, to have floats.
- **Methods**: `x.append(1)` with an `x` of unknown type makes `x` a list
  (`append` is only a list method); a name that no builtin type has makes
  `x` a struct with that field.
- **`Any`** fits everything, and nothing is learned from it. The checker
  infers it only where it must: for values it can't type (`getattr` with
  an unknown name, `proto`), for the arguments of an untyped `*args`
  (which may differ in type, as `print`'s), for `a and b`/`a or b` of
  different types, and where a type would have to contain itself (there
  are no recursive types: a tree whose nodes are structs has `kids:
  list[Any]` at the point where it would recur). Annotate with `Any` (e.g.
  `dict[str, Any]`) to opt a value out of checking.
- **Reactive variables** (above) have the type of their definition; a
  struct block is a struct with the `id` it gets, and a relation is a
  table, `list[struct[...]]` (its member type where a definition reads
  it).
- `load()`ed modules are inferred too, each with its own `.start` file if
  it has one; a loaded def is as polymorphic as where it is defined.

### The language of `.start` and `.starit` files

One language for both, modelled on Python's type hints (PEP 484, and PEP
695 for type parameters), as they are written in a stub file: the
checker's output can be pasted into (or used as) a `.start` file.
Comments, strings and indentation are Starlark's.

    name: type                                  # a variable
    def name[params](a: type, b: type = ..., *args: type, **kw: type) -> type
    def name(a, b: type):                       # locals and nested defs,
        local: type                             # in the def's block
        def inner(x: type) -> type
    type Name = type                            # an alias (top level only)
    type Pair[T] = tuple[T, T]

- Types: `int float str bytes bool None Any range`, `list[T]`, `dict[K,
  V]`, `set[T]`, `tuple[A, B]`, `tuple[()]`, `tuple[T, ...]`, `T | None`,
  `struct[name: type, ..., **R]` (`struct[]`: no fields), function types
  `(A, B) -> R` with parameters as in a def or just types
  (parenthesized in a union: `((int) -> int) | None`), `Literal["name"]`
  (a field name), type parameters, and aliases. PEP 484's `List`, `Dict`,
  `Set`, `Tuple`, `Optional[T]` and `Callable[[A, B], R]` are understood
  too.
- A def's type parameters go in brackets after its name, as in PEP 695:
  `T` (any type; with bounds: `T: Iterable[E] & Sized`, `T: (int,
  float)`), `**R` (a row: the rest of a struct's fields, as `**kwargs` is
  the rest of the arguments), and `L: str` (a field name; in `struct[L:
  T]`, a name that is such a parameter is the parameter, and `"L": T` is
  the field called L). Nested defs see the enclosing def's parameters.
- `= ...` marks a parameter that has a default; `: ...` or `: pass` may
  end a def line, as in a stub.
- In a `.start` file everything is optional: declare only some names,
  leave out some parameters' types or the result (they are inferred, as
  without the file), but the parameters must be the def's own, in order.
  A def whose parameters and result are all declared is checked against
  exactly that type: its type parameters are rigid in the body (`def
  first[T](xs: list[T]) -> T` can't return an `int`), and uses rely on
  the declared type alone.
- What differs from PEP 484, since the files are separate from the code
  and types are structural: no classes, protocols or `TypeVar`
  declarations; unannotated things are inferred, not `Any`; unions only
  with `None`; struct types (rows) and field name types are new; function
  types are written with `->`.
- A row parameter must end some struct type of the signature, and a field
  name parameter must be the type of a parameter or the last field of a
  struct type (the paper's *tail check*): otherwise how it is instantiated
  wouldn't decide the fields after it, and the annotation is rejected.

### Diagnostics

`file:line:col: error: message`, then the source line with a caret; notes
(`file:line:col: note: ...`) follow with the other places involved: where
the expected type and the offending value come from (the literal, the
assignment, the annotation, the operation in a called def that needs it).
Positions in `.start` files are reported the same way: unknown names
(with spelling hints), wrong parameter lists, unknown types and bounds. At
most 100 are printed per program. The exit status is 1 if there are any;
`prog.starit` is then not written. A syntax error (in the program or the
`.start` file) is reported alone, as the compiler does.

### In the REPL

The REPL (`node host/repl.mjs`, and the one in the browser) has the
checker too. It checks the session as typed, in which `_` may hold values
of different types from one input to the next.

    >>> def area(shape):
    ...     return shape.width * shape.height
    ...
    >>> box = struct(width = 2, height = 3, name = "box")
    >>> :type area
    def area[T: Mul[U, V], U, V, **R](shape: struct[width: T, height: U, **R]) -> V
    >>> :type area(box) / 2
    float
    >>> :type lambda r: r + struct(id = 1)
    [**R](r: struct[**R]) -> struct[id: int, **R]
    >>> :check on
    type checking of inputs is on
    >>> area("box")
    <input 3>:1:6: error: argument 'shape' of area(): expected struct[width: _, height: _, ...], got str
          | area("box")
          |      ^
    <input 1>:2:17: note: struct[width: _, height: _, ...] is expected because of this (.width is used here)
          |     return shape.width * shape.height
          |                 ^

- `:type expr` prints the type of an expression without evaluating it
  (what is still unknown in it is shown as type parameters, as for a
  def); `:type name` prints the declaration of a name of the session.
- `:types` prints the types of everything defined so far, as a `.starit`
  file would have them.
- `:check on` checks each input before it runs: one with type errors is
  reported and not run (so not kept). `:check off` (the default) runs
  everything, as before. Updates of reactive variables (`x = 5`) are not
  checked.
- Modules that the session `load()`s are checked with their `.start`
  files, if they have any; the session itself has none.
- Tab completion, in the browser REPL (the Tab key, or the Tab button on
  a touch screen): after a `.`, the fields of a struct or the methods of
  a builtin type, found from the *type* of the expression before the dot
  (`box.`, `boxes[0].name.up`, `d.get("k").`), which is inferred, not
  evaluated; anywhere else, the names of the session, builtins and
  keywords (and the names in the lines of a block being typed), and at
  the start of a line the commands. One candidate is inserted; of
  several, what they have in common, and if that adds nothing they are
  listed, with their types if they are few (`width: int`, `append: (x:
  int) -> None`). Where an argument of a call starts (after its `(` or a
  `,`), the parameters the call can name come first, as `name = `, from
  the type of what is called: `greet("a", pu` becomes `greet("a",
  punctuation = `, and `greet(` lists them all with their types; those
  already given, by name or by position, are left out. For a builtin
  only its keyword-only parameters are offered (`sorted(xs, ` gives `key
  = ` and `reverse = `), since the others are positional in starlark-go;
  a call may go on over several lines. At the start of a line Tab indents. Inside a block that
  is still being typed, the expression is typed where it stands, from
  the block's lines so far: loop variables and locals have their types
  (`for b in boxes:` then `b.`), and a parameter of the def being typed
  has only the fields it was used with above (its callers don't exist
  yet). Variables bound on the line being completed itself (an unfinished
  comprehension's) are not known. Code: `Session.complete`
  (host/repl_core.mjs; in a block, the line is replaced by a call
  `_complete_probe_(expr)`, whose argument's type the checker notes), the
  checker's `--attrs`, `--params` (and `--attrs-probe`, `--params-probe`)
  and `--names`, and web/repl.js;
  test: tests/repl/complete.mjs. (The terminal REPL has no
  Tab completion.)
- Code: `Session.typecheck` in host/repl_core.mjs runs the compiled
  checker with `--repl` on the inputs as typed (expressions as `_ =
  (...)`), and maps positions back to `<input N>:line:col`. The checker
  is compiled when first needed (the terminal REPL; cached), or fetched
  as `typecheck.wasm` (the browser; web/build.mjs puts it in the site).
  Test: tests/repl/types.in, with both REPLs.

### How it is made

All of it is Starlark, in `typecheck/`, run by starlark-go or compiled by
starwasm (`node host/typecheck.mjs` runs it compiled and cached, like any
program; it adds only what Starlark can't do: a missing `.start` file
reads as empty, and the exit status).

- `types.star`: types, rows and labels as dicts with mutable unification
  variables (levels for generalization); printing.
- `unify.star`: unification. Rows follow the paper's Fig. 10: a field with
  a literal label at the head of one row is looked up in the other
  (`_lookup`: the lookup judgment, with LUtail extending a row variable at
  the tail), with the side condition that stops `(a: int | R) ~ (b: int |
  R)` from looping. Beyond the figure: equal items at either end of both
  rows are unified directly; lookup also works from the end of the rows
  (the mirror image, for rows like `(R | id: int)`); a row variable also
  provides a field when everything after it is fields of other names; and
  where the paper's unification is stuck (a field whose name is a
  variable: `(L: int | R) ~ (x: int, y: int)` has two unifiers) the
  equation waits on the variable and is solved once it is known, e.g. by
  the next argument of the call. `flow` is unification at a use: `T` into
  `T | None`, `int` into `float`, tuples and structs (immutable) field by
  field. Constraints that wait on a variable (bounds) are solved when it
  is; a def generalizes the ones left on its type parameters.
- `stubs.star`: the parser of the type language (on the compiler's
  lexer), and its conversion to types; the tail check.
- `builtins.star`: the types of the builtins and methods, in that
  language.
- `infer.star`: inference over the compiler's AST: scopes, defs on demand
  (cycles of defs by Tarjan's algorithm), narrowing, calls.
- `main.star`: the command line, diagnostics, the `.starit` writer.
  `bin/starhost --recursion typecheck/main.star [--print] [--start=FILE]...
  prog.star` runs it interpreted (`--start=` names each `.start` file that
  exists, since Starlark can't ask).

### Not covered

- Union types other than `T | None`, recursive types, and dicts as
  records: a dict has one key type and one value type, so `{"name": "x",
  "qty": 1}` is an error unless annotated `dict[str, Any]` (use a struct).
  Programs written that way (this compiler is one) need annotations with
  `Any` to check.
- Flow typing other than for None: `x = int(x)` for a string `x` is an
  error, and `type(x) == "int"` narrows nothing.
- An accumulator that starts as an int literal and is added floats that
  only a caller supplies (`total = 0` in a def summing its argument) is an
  int: start it at `0.0`.
- `struct(**d)` has an unknown row; a struct passed as `**kwargs` and the
  count of `*args` are not checked.
- A field that follows a row variable is taken to be visible: `struct[**R,
  id: int]` doesn't unify with `struct[id: str]`, though `R = (id: str)`
  would shadow the `id: int`.
- Type errors don't stop the compiler: checking and compiling are
  separate commands.

Tests: `tests/types/` (`tests/types.sh`): programs with their expected
`.starit`, or their expected diagnostics (`err_*.star`, `.err`), checked
by the interpreted and by the self-compiled checker, and round trip (each
`.starit` used as the `.start` must reproduce itself);
`tests/types_test.star`: unification, case by case.
