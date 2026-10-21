# starwasm — self-hosting Starlark → WasmGC compiler

Goal: a compiler written in a subset of Starlark that compiles that same
subset to WebAssembly (WasmGC), runtime included, with no language
additions. The runtime is *generated* by Starlark code through the
instruction-builder API (the Hoot / V8 CSA approach), not hand-written WAT.

## Layout

    host/main.go          stage-0 host: starlark-go + recursion/while + file I/O
    host/wasmhost.mjs     runs compiled modules: host imports, files, argv,
                          tracebacks (used by run.mjs and repl.mjs)
    host/run.mjs          command line: run a .wasm export
    host/repl.mjs         interactive REPL on the self-compiled compiler
    lib/wasm.star         Wasm + WasmGC binary encoder (instructions as data)
    lib/dsl.star          expression-style builders: call, op, if_, while_, field...
    lib/runtime.star      add_runtime(m): value types + core rt_* functions
    lib/builtins.star     add_builtins(m): builtins, methods, slicing, unpacking,
                          files/argv for compiled programs, prelude primitives
    lib/prelude.star      builtins and methods written in Starlark (min, max,
                          zip, string methods, format, list/dict extras...)
    lib/unicode_tables.star  Unicode properties (generated from Go)
    tools/gen_unicode.go  generates lib/unicode_tables.star
    compiler/lexer.star   source -> tokens (indent/dedent, escapes, literals)
    compiler/parser.star  tokens -> dict-based AST (format documented at top)
    compiler/resolve.star scope analysis: which variables closures capture (cells)
    compiler/codegen.star AST -> Wasm module (scopes, calls, loops, closures)
    compiler/main.star    driver: starhost compiler/main.star in.star out.wasm
    examples/demo.star    milestone 1 demo (i64 factorial)
    tests/*_test.star     Starlark unit tests (encoder bytes vs. spec)
    tests/runtime/        differential test: expect.star (starlark-go) vs
                          build.star (same program as Wasm on the runtime)
    tests/golden/         expected outputs / error messages
    tests/compile/        programs compiled AND run by starlark-go; outputs
                          must match (err_* programs must fail in both, with
                          identical tracebacks)
    tests/errors/         programs that fail: stderr must equal starlark-go's
    tests/compile_one.sh  one differential test (compile.sh runs them in parallel)
    tests/repl/           scripted REPL session and its expected transcript
    tests/compile_errors/ "# error: <text>" first line; compile must fail so
    tests/selfhost/       compiled front end vs interpreted, on every .star file
    tests/upstream/       starlark-go's own test files (testdata/*.star) run
                          against starwasm; see tests/upstream/README.md
    host/upstream/        bin/upstreamhost: starlark-go with the test-only
                          builtins, the reference for tests/upstream/
    test.sh               runs everything; uses wasm-tools validate if present

Setup: `cd host && go get go.starlark.net@latest && go mod tidy`, then
`./test.sh`. Requires Go and Node ≥ 22 (WasmGC on by default).

## Encoder conventions (lib/wasm.star)

- Instructions are tuples `("op", imm...)`; bare `"op"` is shorthand; bodies
  nest freely; `None` in a body is ignored.
- Everything is by name: locals, funcs, globals, types, struct fields, data
  segments, labels (`("block", None, "exit")` ... `("br", "exit")`; ints work
  too). Labels shadow like WAT: innermost match wins.
- Value types: `I32 I64`, packed `I8 I16` (fields only),
  `ref(T, null=False)` where T is a type name or abstract heap type
  (`"any" "eq" "i31" "struct" "array" "none" "func" "extern"`...).
  `EQREF = ref("eq", True)`.
- All named types go in ONE rec group (so they can be mutually recursive);
  each is `sub final` unless `final=False`.
- `ref.test`/`ref.cast` take a reftype; nullability picks the opcode.
- Encoder checks: unknown op/name, immediate counts, int ranges, branch
  depth, balanced blocks. Stack typing is left to the engine/wasm-tools.
- `encode(m)` adds a `name` section (function, local, type, global and
  field names), so V8 errors and `wasm-tools print` show real names.

## Value representation (lib/runtime.star header has details)

Every Starlark value is an `eqref`:

| Starlark | Wasm |
|---|---|
| int | `i31ref` if −2^30 ≤ n < 2^30, else `$Int {i64}`, else `$Big {neg, mag: $I32A}`; always normalized |
| None / True / False | singleton structs in immutable globals |
| string | `$Str {mut hash i32, b: $U8}`, UTF-8, byte-indexed like starlark-go |
| tuple | `$Tuple {items: $Vals}` |
| list | `$List {mut len, mut items: $Vals}`, doubling growth |
| dict | `$Dict`: insertion-ordered compact dict, open addressing, index size S (pow2), entry cap S/2 |
| set | `$Set {d: $Dict}`: elements are the dict's keys (values None); shares its order, hashing, frozen flag |
| float | `$Float {v: f64}` |
| bytes | `$Bytes {mut hash, b: $U8}`: same layout as `$Str` but a distinct type; ops wrap the array in a `$Str` to reuse string code |
| struct | `$Struct {d: $Dict}`: field → value, keys sorted |
| function | `$Func` (see below); builtins as values too (`Sig.kind` ≠ 0) |
| bound method | `$Bound {recv, fn: $Func, name}` |
| null | not a value: "unbound" / "missing" sentinel |

- Strings constants: one passive data segment; per-constant lazy global +
  getter function; use `S(m, "text")` to emit one.
- `vi(n)` emits an int constant already normalized.
- Errors: `rt_fail(str)` prints `Error: msg` to stderr, calls host.exit(1).
- Output: bytes copied into a 64 KiB linear memory, then host.write(fd, ptr, n).
- Hashes: FNV-1a for strings (cached), murmur3 finalizer for ints,
  multiplicative combine for tuples. Lists/dicts are unhashable.
- Truthiness, `==` (deep), `<` (ints, strings bytewise, lists/tuples
  lexicographic), `in`, indexing (negative ok), `len`, `+ - * // % & | ^ << >>`,
  unary `-`, `not`, `str`, `repr`, `type`, `print`, for-loop snapshot (`rt_iter`).

## Self-hosting (milestones 4-5)

The compiler compiles itself; the bootstrap reaches a byte-identical
fixpoint on the first generation:

    bin/starhost compiler/main.star compiler/main.star out/stage1.wasm   # ~2.2s
    node host/run.mjs out/stage1.wasm -- compiler/main.star out/stage2.wasm  # ~0.6s
    node host/run.mjs out/stage2.wasm -- compiler/main.star out/stage3.wasm
    # stage1 == stage2 == stage3 (849 KB with debug sections)

So the self-compiled compiler can replace starhost entirely:

    node host/run.mjs out/stage2.wasm -- prog.star prog.wasm
    node host/run.mjs prog.wasm [-- args...]

test.sh checks the fixpoint, reruns tests/compile.sh and
tests/compile_errors.sh with COMPILER="node host/run.mjs out/stage2.wasm --",
and checks that the interpreted and self-compiled compilers emit identical
bytes for every test program. starhost is still needed once, to bootstrap
(or keep a checked-in stage wasm, like OCaml's boot/).

What it took beyond milestone 3.5:
- `%` formatting (rt_format: %s %r %d %i %x %X %o %c %%, tuple/single/dict
  args), `sorted(key=, reverse=)` (stable merge sort), all/any,
  str.elem_ords(), fixed-arity builtins as values (`key = len`).
- load(): all reachable modules compiled into one Wasm module; per-module
  names ("m<id>.name", main unqualified); loaded names resolved statically
  (calls stay direct); init<id> functions run once; cycles, missing and
  `_private` names are compile errors.
- Freezing: a loaded module's globals and function values are deep-frozen
  (lists/dicts/functions carry a `frozen` flag) when its init finishes;
  mutations fail like starlark-go ("cannot insert into frozen hash table").
- 64-bit safety in the compiler's own source: no `1 << 63`/`1 << 64`
  (_check_range, MIN_I64), lexer range-checks literals before multiplying.

## Compiler

    bin/starhost compiler/main.star prog.star out/prog.wasm
    node host/run.mjs out/prog.wasm [-- args...]     # runs top level

- Written in plain Starlark. It started out in a subset (no %, lambdas,
  closures or comprehensions) so the front end could compile itself early
  on; now that the compiler supports all of those, its sources use them
  where convenient (comprehensions and nested defs in codegen.star, %
  formatting in lib/). The one rule left: the compiler's own code must not
  depend on starlark-go-only behavior, since stage2 runs it compiled.
- Each top-level `def f` -> Wasm func `f_f`, all eqref params/result. Calls
  are static (callee must be a def'd name): keyword args, defaults, `*args`
  packing resolved at compile time. Defaults are evaluated when the def
  executes, stored in globals `d_<f>_<param>`. With keyword args, arguments
  go through temps to keep source evaluation order.
- Module variables: globals `g_<name>`; locals: Wasm locals; both null until
  assigned; reads check with br_on_non_null and fail with
  "local/global variable x referenced before assignment".
- Comprehension variables get fresh locals `%cN.name` (own scope).
- `for x in range(...)` compiles to an i64 counted loop (no list); other
  loops iterate a tuple snapshot from rt_iter.
- Loops: block "brk" { loop "top" { ...; block "cont" { body }; advance } };
  labels shadow, so break/continue always hit the innermost loop.
- Conditions compile to i32 directly (comparisons, and/or/not) instead of
  boxing a bool and testing it.
- Builtins: print fail len str repr type bool int list tuple dict range
  enumerate ord chr abs sorted read_file write_file argv (generated), plus
  the prelude's (all any min max zip reversed hasattr getattr dir set bytes
  struct). Methods: METHODS in lib/builtins.star, plus the prelude's _m_*.
- Compiled code is ~4-5x faster than starhost on call-heavy code, unoptimized
  (note starhost here uses starlark-go's generic int path).

## REPL

    node host/repl.mjs [compiler.wasm]       # default out/stage2.wasm

Replay design: the session is the list of accepted inputs; each new input
is appended, the whole session recompiled by the self-compiled compiler (in
the same Node process, module cached) and run, and only output past what
was already printed is shown. Sound because Starlark is deterministic and
hermetic (read_file/write_file are replayed too). ~50 ms per input once V8
has warmed up the compiler.

- Bare expressions print their repr (unless None) and set `_`.
- A failing input (compile or runtime error) is dropped, so state stays as
  before it; errors and tracebacks are mapped to `<input N>:line:col`.
- Blocks (first line ends with ":") end with an empty line; open brackets,
  triple-quoted strings and trailing backslashes continue on "..." lines.
- load() paths are relative to the current directory (the session file is
  `.starwasm-repl-<pid>.star` there, removed on exit).
- Cost of replay: slow computations entered earlier rerun on every input.
  The incremental alternative (one small module per input, importing the
  runtime and earlier globals) would need separate compilation support.
- Commands: :help :history :reset :quit.

## The prelude: builtins written in Starlark

lib/prelude.star holds ~45 builtins/methods as plain Starlark, compiled into
every program; generated Wasm (lib/runtime.star, lib/builtins.star) is kept
for value representation, hot operations, internals, and fast primitives.

- The source is a raw string (PRELUDE) loaded by codegen.star, so the
  compiler carries it along and stage2.wasm is self-contained. Line numbers
  inside the string equal the file's lines.
- add_prelude() parses it as one more module and keeps only what the program
  can reach: a syntactic scan of identifiers and method names in the user
  modules, closed over references between prelude defs/assignments. A
  program using none of it pays nothing.
- Names: public prelude functions are found after the program's own
  globals (so user code can shadow them) and before generated builtins.
  `x.m(...)` uses the generated rt_m_<m> if there is one, else the prelude's
  `_m_<m>(receiver, ...)` as a static call; the receiver is positional-only.
- Primitives visible only inside the prelude (PRELUDE_INTRINSICS):
  `_error(msg)` (fails as the builtin being called: "Error in split: ..."),
  `_error_plain(msg)` (attribute errors: "Error: int has no .x ..."),
  `_find/_rfind(s, sub, lo, hi)` (byte search in Wasm), `_bytes_to_str`,
  `_frozen`. Everything else is ordinary Starlark.
- Tracebacks: prelude functions are "hidden" frames. A builtin that calls
  back into Starlark (min/max/sorted key=) shows as `<builtin>: in max`,
  like starlark-go. Attribute errors on method calls point at the ".".
- In the prelude: all any min max zip reversed hasattr dir; string find
  rfind index rindex count startswith endswith (incl. tuples) removeprefix
  removesuffix partition rpartition split rsplit splitlines strip lstrip
  rstrip replace upper lower title capitalize isalpha isdigit isalnum
  isspace islower isupper istitle codepoints codepoint_ords format; list
  index insert remove clear; dict update popitem clear.
- Case mapping and character classes are ASCII-only (starlark-go is
  Unicode-aware); noted under deviations.

## Sets

Split between the two layers, as the prelude design suggests:
- Generated (lib/runtime.star `_sets`, lib/builtins.star): the `$Set` type,
  type/truth/len/in/iteration/repr ("set([1, 2])"), equality, the operators
  `| & ^ -` (dispatched from rt_or/rt_and/rt_xor/rt_sub after the int fast
  path), subset comparisons (`<` proper subset; `<=`/`>=` computed directly,
  since inclusion isn't a total order), unhashability, freezing, `pop`.
- Prelude: `set()` and add, discard, remove, clear, update, union,
  intersection, difference, symmetric_difference, issubset, issuperset,
  via `_set_new`, `_set_dict` (the element dict) and `_unhashable`.
- Element order matches starlark-go: `a | b` is a then b's new ones;
  `a & b` keeps b's order; `a - b` a's; `a ^ b` a's unique then b's.
  `pop` removes the oldest element. `|=` makes a new set (update() doesn't).
- intersection/difference/symmetric_difference take exactly one argument
  (starlark-go panics when called with none, so that isn't tested).

## Runtime errors and tracebacks

Runtime errors print the same thing starlark-go does, byte for byte (checked
on 45 programs in tests/errors/ plus every err_* program):

    Traceback (most recent call last):
      prog.star:9:7: in <toplevel>
      prog.star:4:13: in f
    Error in pop: pop: index -1 out of range: empty list

Zero cost at run time; no shadow stack. How it works:
- Codegen puts a source marker `("@pos", tag)` right before every call that
  can fail (callat/callbi in codegen.star). The encoder emits no bytes for
  it but records the module offset of the next instruction.
- Sections: `starwasm.marks` (per function: offset deltas + tags),
  `starwasm.pos` (per tag: file, line, col, builtin), `starwasm.debug` (JSON:
  file names, builtin names, which Wasm functions are Starlark frames and
  their display names). ~110 KB on the compiler's 450 KB module.
- rt_fail stages the message and calls `host.fail`, which captures a JS
  stack. V8 reports each Wasm frame as `wasm-function[i]:0xOFFSET`, the
  offset of the call instruction executing in that frame (verified), so the
  marker at that offset is the frame's position. Runtime helpers, dyn_
  entries and main are skipped.
- Positions follow starlark-go: calls at "(", operators at the operator
  (`not in` at `in`; `x += y` at `+=`), index/slice at "[", names at the
  name, dict entries at ":", unpacking at "=", for-loops at `for`.
- Argument-binding errors (rt_bind) get an extra frame for the callee at
  its "first instruction": the first variable read in evaluation order, else
  the def/lambda keyword (first_pos in codegen.star).
- "Error in <builtin>: ..." when the innermost frame's marker is a builtin
  or method call. Messages match starlark-go's wording (index ranges,
  "function f missing 2 arguments (a, b)", "int < string not implemented",
  frozen-value errors, ...).
- Wasm traps (null deref, stack overflow) print a traceback as an
  "internal error" and exit 3.

## Functions as values (milestone 3.5)

- Value: `$Func {code: (ref $Code), sig: $Sig, env: cells or null,
  defaults: per-slot values or null, id}`. `$Code` = `(func (ref $Func)
  $Vals eqref) -> eqref`: function value, positional args, kwargs dict/null.
- Every def/lambda gets a body function plus a dynamic entry `dyn_...` of
  type `$Code` (declared with `add_func(..., typ="Code")` so `ref.func`
  yields `(ref $Code)` for `call_ref`). The entry calls `rt_bind`, which
  matches positional / `*args` / keyword-only / `**kwargs` slots, fills
  defaults and raises Starlark-style errors, then calls the body.
- `$Sig` (name, slot names, counts) is a constant global per function,
  built with constant expressions (`struct.new`/`array.new_fixed`).
- Direct calls to top-level defs by name stay static (no rt_bind); every
  other call is `rt_call(f, args, kw)`. Call sites with `*x`/`**x` or
  keywords build a list/dict in source order first.
- Closures: compiler/resolve.star marks a binding as a cell when an inner
  def/lambda uses it, and gives every function in between a free list. Cells
  are created at function entry (params copied in) or at comprehension
  start; closures get an env array of cells in free-list order; free var i
  = `env[i].v`. Gives Starlark/Python late binding.
- Top-level def values live in globals `fv_<name>`, set when the def
  statement executes (as in Starlark).
- Functions: type "function", repr `<function name>` (`lambda` for
  lambdas), hashable by identity.

## Methods and builtins as values, getattr, struct, bytes (milestone 10)

- `x.name` not followed by a call compiles to a static call of the
  prelude's `_attr(x, "name")`: a struct's field, else a bound method
  (`_bound` → `$Bound`), else a plain error at the "." ("int has no .foo
  field or method"). getattr/hasattr/dir are prelude functions on top of it.
- Bound methods: `rt_call` prepends the receiver and calls `Bound.fn`, a
  `$Func` whose Sig has `recv = 1` (slot 0 is the receiver: never matched
  by a keyword, not counted in messages). The functions come from the
  global dict `method_funcs` that main fills after the prelude's init: the
  prelude's `fv__m_<name>`, or a hidden wrapper `bm_<name>` around a
  generated rt_m_<name>. Only methods the program may take as values go in:
  names in non-call `x.name` and `getattr(x, "literal")`, or every method if
  getattr is used any other way (add_prelude decides; mc["method_values"]).
- Builtins as values: generated builtins get a hidden wrapper `bi_<name>`
  with a dyn entry and Sig, created on first use (global `bv_<name>`);
  optional parameters default to the `Absent` sentinel. Prelude functions
  are already values. `Sig.kind`: 0 Starlark function, 1 builtin with
  positional-only parameters, 2 builtin with keyword parameters (prelude:
  2 iff keyword-only or **kwargs params). rt_bind words errors like
  starlark-go's UnpackPositionalArgs / UnpackArgs for kinds 1 / 2
  ("split: got 3 arguments, want at most 2", "sorted: missing argument for
  iterable", "split: unexpected keyword arguments"). type() is
  builtin_function_or_method; repr `<built-in function len>` /
  `<built-in method split of string value>`; equality is identity, so
  `len == len` but `[].append != [].append`, as in starlark-go.
- Tracebacks: when a frame's call marker names no builtin (a call through a
  value), the outermost hidden frame it called names it, so `f = len;
  f(1, 2)` says "Error in len: ..." and builtins calling back into Starlark
  still show `<builtin>: in max`.
- struct: prelude `struct(**kwargs)` → `_struct_new` (sorts the fields);
  generated type/repr (`struct(a = 1, b = [2])`), field-wise ==, hashing
  (unhashable if a field is), `+` (merge, right wins), freezing. When the
  program references `struct`, every method call `x.m(...)` first checks for
  a struct and then calls the field instead (fields shadow methods), and
  calls of non-method names go through `_attr`; otherwise such calls stay
  compile errors and method calls cost nothing extra.
  bin/starhost predeclares `struct` (starlark-go's starlarkstruct.Make, not
  a core builtin there) so the differential tests can use it.
- bytes: `b"..."`/`rb"..."` literals (lexer token "bytes": a list of byte
  values; `\xff`, octal up to `\377`, `\u` as UTF-8); type, len, index (a
  1-byte bytes), slices, `+`, `*`, `==`, `<` (bytewise), `in` (bytes or an
  int byte), hashing; repr `b"..."` keeps valid UTF-8 and escapes the rest
  (strings now also escape invalid UTF-8 as `\xNN`); `print` writes the raw
  bytes, `str()` replaces each invalid byte with U+FFFD, `%s`/`{}` use repr
  (all as starlark-go). Prelude `bytes(x)` (string, bytes, iterable of
  ints), `.elems()`.
- print(*args, sep=" ") takes sep, directly and as a value.
- Index errors now match starlark-go for empty sequences too ("index 0 out
  of range: empty string"; rt_norm_index takes a prefix and a type name).

## Lazy objects (milestone 11)

- range() returns `$Range {start, stop, step: i64}`, as starlark-go: repr
  `range(3)` / `range(1, 4)` / `range(10, 0, -3)`, type "range", len,
  indexing ("range index 5 out of range [-3:2]"), slicing gives a range
  (bounds scaled: `range(10, 0, -3)[::-1]` is `range(1, 13, 3)`), `in` for
  ints only, equality by elements (`range(0) == range(2, 2)`), truth = non-
  empty, "unhashable: range". Lengths are computed on unsigned differences,
  so huge ranges are fine until something needs their length.
  Argument errors: "range: for parameter 2: got string, want int" (also in
  the for-loop fast path).
- s.elems(), s.elem_ords(), s.codepoints(), s.codepoint_ords(), b.elems()
  return `$Lazy {kind, s}`: types "string.elems" (elems and elem_ords),
  "string.codepoints", "bytes.elems"; repr `"abc".elems()`; iterable;
  string.elems also has len and indexing; equal when same kind and string;
  "unhashable: string.elems"; always truthy. codepoints decode like Go (an
  invalid byte is a 1-byte string / U+FFFD). All are generated now (the
  prelude's _m_codepoints went away).
- for loops and comprehensions count through a range whatever its length
  (loop_setup checks for a $Range at run time; `for x in range(...)` written
  literally was always a counted loop). Other consumers (list(), sorted(),
  zip(), unpacking, ...) go through rt_iter, which materializes a range or
  lazy sequence as a tuple (`a, b = range(2)`; unpacking takes any
  iterable). len() and indexing work for ranges longer than 2^32; an index
  must fit in 32 bits ("range index: N out of range"), as in starlark-go,
  for every sequence.
- Slice errors: "zero is not a valid slice step", reported where starlark-go
  does: at the last positioned instruction while evaluating the operands
  (last_leaf in codegen.star), else at the "[".

## Floats (milestone 12)

- Literals `1.5 .5 1. 1e3 2.5E-3` (lexer token "float", val = the text);
  literals that overflow are compile errors ("invalid float literal",
  decided on the digits, no float math in the compiler). A literal compiles
  to a getter that parses it once (runtime + host) and caches it in a
  global, so the compiler itself never needs floats.
- `$Float {v: f64}`; `/` (rt_div, always a float), `//`, `%` (Go's Mod:
  fmod then sign of the divisor), `+ - *` on mixed ints/floats; `/=`.
  Errors as starlark-go ("floating-point division by zero", "floored
  division by zero", "floating-point modulo by zero").
- Comparisons follow starlark-go: ints and floats compare exactly
  (rt_cmp_if, no rounding of the int), NaN equals itself and sorts above
  +inf; equal ints and floats hash alike (a float hashes as its integer
  part), so `{1: "a"}[1.0]` works.
- float(), int(float) (truncates; NaN/inf errors), abs, min/max/sorted on
  mixed numbers, `%d %i %x %X %o` of floats (truncated), `%e %f %g %E %G`.
  float() of a string accepts what Go's ParseFloat does here: decimal,
  `inf`/`infinity`/`nan` (any case, signed), digit underscores.
- str/repr: Go's FormatFloat 'g' with the shortest round-trip digits (+ ".0"
  if it would look like an int): 1e+06, 123456.0, 1e-05, +inf, nan, -0.0.
- The host does the parts that need exact decimal conversion: shortest
  digits and %e/%f (JavaScript's Number formatting; same digits as Go's),
  parsing (Number), and fmod (`%`). Imports float_fmt, float_parse,
  float_mod; everything else is generated Wasm (f64 opcodes added to the
  encoder).
- Also fixed: unary + is its own operation ("unknown unary op: + string");
  index type errors say "list index: got float, want int".

## Unbounded ints (milestone 13)

- Ints outside i64 are `$Big {neg, mag}`: sign and magnitude, 32-bit limbs
  least significant first, no zero limbs on top. rt_big_make normalizes, so
  a value that fits in an i64 is never a `$Big` and representations stay
  unique (`==` on two `$Big`s compares; a `$Big` never equals a small int).
- Every int operator keeps its i64 fast path (overflow detected inline) and
  falls back to the `$Big` code (rt_big_* on top of rt_mag_* limb routines:
  schoolbook add/sub/mul, short division by one limb, binary long division,
  shifts, two's-complement bit operations). `//` and `%` floor like Python;
  `~x` is its own operation now ("unknown unary op: ~ string").
- Shifts follow starlark-go: the count must fit in 32 bits ("N out of
  range"), be non-negative, and be < 512 for `<<` ("shift count too large").
- str/repr/%d/%x/%X/%o print big ints by repeated division by the largest
  power of the base below 2^31; int("...") parses any length.
- Floats: float(big) rounds correctly (top 64 bits plus a sticky bit, then
  an exact power of two; "int too large to convert to float" past the
  range); int(float) is exact for any finite float; int/float comparisons
  stay exact and integral floats hash like the equal int.
- Contexts that need a machine int report starlark-go's messages: "list
  index: N out of range", "range: for parameter 1: N out of range (want
  value in signed 64-bit range)", "repeat count N too large", "chr: N out
  of range".
- Literals: decimal and hex literals are unbounded (the lexer now just
  accumulates; codegen's vi() emits a `$Big` constant as limbs); octal and
  binary literals must fit in 64 bits ("invalid int literal"), as in
  starlark-go. The compiler's own source still avoids big ints.

## Mutation during iteration (milestone 15)

- As in starlark-go, a list, dict or set can't change while a for loop or
  comprehension goes over it, or while sorted()/min()/max() call a key
  function on it ("append: cannot append to list during iteration",
  "cannot insert into hash table during iteration", ...).
- The count of iterations in progress lives in the "frozen" field next to
  the frozen flag (bit 0 = frozen, the rest = count), so no layout changed;
  check_mutable() tests both. rt_iter_track(x, +2/-2) is called when a loop
  starts and ends: after the loop block (so break is covered), and before
  `return` inside loops (fc["iters"]; the return value is computed first).
  The prelude checks _iterating() next to _frozen().
- Since a list can't change during a loop, for loops now go over a list's
  items in place instead of copying them; dicts and sets still snapshot
  their keys.

## Closing the deviations (milestone 16)

- Comparisons recurse at most 10 levels into lists, tuples, dicts and
  structs, like starlark-go's CompareLimit ("comparison exceeded maximum
  recursion depth"); that also stops cyclic values. Containers get no
  identity shortcut (as in starlark-go: a 12-deep list isn't == itself).
- %e/%f round exact decimal ties to even like Go: the host formats them
  from the float's exact binary value with BigInt (scaledDigits).
- int / int: starlark-go converts both ints to floats too (and fails with
  "int too large to convert to float"), so this was never a deviation;
  tests/compile/intdiv.star checks it.
- Calls never fail to compile because of their arguments. A static call
  whose arguments don't match (user defs, prelude builtins, generated
  builtins, methods), uses keywords where the builtin is positional-only,
  or passes *args/**kwargs to a builtin, becomes a dynamic call through
  the function's value (methods: a $Bound), so rt_bind reports
  starlark-go's message at run time, and only if the call runs. Calls of
  unknown methods compile to _attr (a run-time "has no .x field or
  method"). Removed compile errors: bad_kwarg, missing_arg, too_many,
  builtin_arity, unknown_method.
- Builtin signatures as starlark-go: int(x, base) (prelude: bases 0 and
  2..36 with 0x/0o/0b prefixes, starlark-go's parseInt rules), dict(pairs
  or mapping, **kwargs) (prelude), enumerate(x, start), fail(*args,
  sep=" "), startswith/endswith(prefix, start, end), start/end checks in
  find/count/index ("invalid start index: got string, want int"), str/type
  ("want exactly 1", "does not accept keyword arguments"), pop arity per
  type. KEYWORD_PRELUDE lists prelude builtins whose parameters may be
  passed by keyword (Sig.kind 2).
- Unicode: lib/unicode_tables.star is generated from Go's unicode package
  by tools/gen_unicode.go: printable ranges (strconv.IsPrint), per-rune
  class flags (letter, digit, space, upper, lower, title, cased) and
  unicode.CaseRanges. They become passive data segments read as $I32A on
  first use. repr escapes non-printable code points (\u0085, \U000e0001)
  like strconv.Quote; upper/lower/title/capitalize and the is* methods are
  generated (rt_str_case / rt_str_class) and follow Go's unicode.To* and
  starlark-go's rules (title/istitle, cased = SimpleFold). The print table
  (~6 KB) is in every program; the class and case tables (~30 KB) only in
  programs that keep one of those methods.

## starlark-go's own tests (tests/upstream/)

tests/upstream/run.mjs splits starlark-go's test scripts into chunks and
runs each one under starlark-go as its own tests do, under starlark-go
configured like starwasm (all options on), and compiled by starwasm; a
chunk fails only when starwasm differs from the second. The assert module
(tests/upstream/assert.star) needs five test-only builtins (test_catch,
test_error, ...), visible only with `compiler/main.star --test`; normal
compiles, and the bootstrap, are unchanged. known_failures.txt lists what
starwasm fails today, with reasons; that list is the to-do list for
starlark-go parity.

- `assert` is no longer a reserved word: starlark-go accepts it as a name.

## Gotchas learned

- WasmGC: a non-nullable local only counts as initialized inside the block
  that set it. If it's assigned in an if/else and used after, declare it
  nullable (`ref(T, True)`).
- Remember the two stages: Starlark `if` picks code to emit; `if_` runs later.

- A self-hosting edge case: code in the compiler must not rely on big ints
  (e.g. the lexer checks literal range BEFORE multiplying; MAX_INT is
  written out because 1 << 63 overflows when compiled).

## Known deviations / not yet done

- Lists, tuples and materialized ranges hold at most 134,217,724
  (2^27 - 4) elements: V8's largest GC array ("list too large", "range
  too large to materialize"); starlark-go is limited only by memory. Such a
  list takes over 1 GB; lifting the limit would mean chunked storage for
  every list (a slower representation for all programs), so it stays.
  Loops over ranges are not limited (they count).
- Unicode data comes from the Go toolchain that ran tools/gen_unicode.go
  (lib/unicode_tables.star, Unicode 15.0 from Go 1.24); a starlark-go built
  with a Go of another Unicode version may classify new characters
  differently. Regenerate with `go run tools/gen_unicode.go >
  lib/unicode_tables.star`.
- Small message differences that remain in rare paths, e.g. sorted() with
  a positional None key (starlark-go: "for parameter key: got NoneType,
  want callable"), unhashable values inside dict()/set() arguments
  (starlark-go prefixes "dict: "), "{+0}".format (starlark-go parses the
  field with strconv.Atoi, which accepts a sign).

## Milestones

1. [x] Encoder in Starlark; module returning 42; recursive i64 fact; loop macro.
2. [x] WasmGC encoding; value representation; generated runtime (~70 funcs,
       ~15 KB); differential test vs starlark-go (69 lines) + error goldens.
3. [x] Lexer, parser, codegen; 10 differential programs (5 expected to fail)
       vs starlark-go; 18 compile-error tests; compiled front end parses all
       44 project .star files identically to the interpreted one.
3.5 [x] Functions as values: closures with cells, lambdas, nested defs,
       dynamic calls, *args/**kwargs at call sites and in params. Tests:
       closures.star, funcvalues.star, 4 err_* programs, 3 compile errors.
4. [x] Self-host: % formatting, load(), freezing, sorted/all/any, builtins
       as values; the compiler compiles its own ~5k lines.
5. [x] Fixpoint: stage1 == stage2 == stage3, byte-identical; self-compiled
       compiler passes the whole suite.

6. [x] Runtime errors with starlark-go-identical tracebacks (file:line:col
       per frame), zero runtime cost, via source markers + V8 stack offsets.

7. [x] Prelude: ~45 builtins/methods written in Starlark on top of six
       primitives; outputs and tracebacks identical to starlark-go
       (tests/compile/prelude.star + 51 error programs).

8. [x] set: generated core + prelude methods; tests/compile/sets.star and
       25 error programs match starlark-go (incl. frozen sets).

9. [x] REPL (replay-based) on the self-compiled compiler; host code split
       into host/wasmhost.mjs.

10. [x] Methods and builtins as values, getattr, struct, bytes, hash(),
       print(sep=), cycle-safe repr; tests/compile/{values,structs,bytes,
       hash,cycles}.star + 63 error programs (tests/errors/value_*.star)
       match starlark-go.
11. [x] Lazy range and string/bytes element sequences, as starlark-go;
       tests/compile/{lazy,unpack_lazy}.star + 41 error programs.
12. [x] Floats; tests/compile/{floats,floats2}.star + 43 error programs.
13. [x] Unbounded ints; tests/compile/{bigint,bigint2}.star (incl. divmod
       identities over mixed big/small/negative operands) + 26 error programs.
14. [x] Ranges of any length in loops; arrays up to V8's limit (lists grow
       to 2^27 - 4 elements instead of trapping at 2^26); 64-bit range
       len/indexing; tests/compile/bigrange.star + 6 error programs.
15. [x] Mutation during iteration is an error, as in starlark-go; lists
       are iterated without copying; tests/compile/iteration.star + 31
       error programs.
16. [x] The remaining deviations: comparison depth, Go rounding of %e/%f,
       arguments checked at run time for every call, full builtin
       signatures (int base, dict, enumerate start, fail sep, ...), Unicode
       repr and case/classes from Go's tables. tests/compile/{unicode,
       builtins_sig,fmtties,intdiv,compare_depth,startswith_bounds}.star +
       ~90 error programs.

17. [x] starlark-go's own test files run against starwasm
       (tests/upstream/): 182 chunks, failures listed with reasons in
       tests/upstream/known_failures.txt.

Possible next steps: performance (unboxed int fast
paths in codegen, static calls to nested defs, avoiding rt_iter snapshots);
a checked-in boot compiler so starlark-go is only needed to rebuild it.
