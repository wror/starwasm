# None surprises

Places where, with contagious None on, a variable, parameter or function
result can hold None even though the type checker (`typecheck/`) gives it
a type without `| None`. That includes every place the checker infers
`Any`, because `Any` takes in a None without a trace.

Method: I compared what the runtime turns into None (compiler/ext/none.star,
compiler/ext/reactive.star, EXTENSIONS.md "Contagious None") with what the
checker treats as possibly None (`_fallible_op`, `_fallible_call`,
`FALLIBLE_METHODS`, `LOOKS_INSIDE`, `STORES`, `_fails`, `_records`,
`_committed` in typecheck/infer.star; `mk_opt` in typecheck/types.star).
Unless a case is marked *not verified*, I checked it both ways: the
checker's output (`bin/starhost --recursion typecheck/main.star --print
[--contagiousnone] prog.star`), and a real run (`node host/run.mjs
[--recursion] prog.star`, with an update such as `n : 1` on stdin) that
printed the None and its `provenance`. The types quoted are what the
checker printed.

**When the None appears.** Contagious None turns errors into None in two
situations:

- **Update**: while a reactive program applies a line of input, *every*
  error becomes a None (`catch_all`).
- **Anywhere**: in any program with contagious None, including the first
  run and non-reactive programs compiled with `--contagiousnone`, only
  errors caused by a None ("None further in"), and Nones that are just
  passed along, are silent.

Each finding below says which one applies. In an update, a None that
reaches a reactive definition without `?? None` makes the update fail
(and fills `xError`), so the reactive variable itself stays clean. The
surprises are in the defs, locals, parameters and observer expressions
that run along the way, and in values that get through to an observer.

---

## 1. Structural gaps (each covers many cases)

**Status: fixed** in the checker (typecheck/nones.star, new, and
infer.star, unify.star, types.star, stubs.star; documented in
EXTENSIONS.md, "Fallible operations"; tests:
tests/types/contagious_escape, contagious_fails, contagious_any,
err_contagious_escape, err_contagious_hashable, err_contagious_any). Each
subsection starts with what the fix does. The line numbers below are from
before the fix. What it still leaves out:

- 1.1: inside the def the parameter still holds the None while typed
  `T`. That is safe only because the None can't leave the call except as
  its (optional) result. The analysis is syntactic, and it takes a
  method call `s.f(x)` to be a builtin method's. A struct field that holds
  a def and has the name of a method that stores its argument (`append`,
  `add`, ...) is a way out it doesn't see.
- 1.2: an `Any` that may be None is told apart from one that isn't only
  directly and as a list's, dict's or set's elements. Elsewhere inside a
  type (a struct's field, a function's parameter) unification still takes
  it for anything. A type variable that nothing solves is printed as
  `Any`, so it reads back from a `.starit` as an `Any` that isn't None.
- 1.3: `Hashable` doesn't look at the fields of a struct that the row
  variable of an open struct type stands for.
- 1.3 and 1.4: a name bound by several defs (a def redefined with
  `--globalreassign`, or in the REPL) has one function type, which the
  checker compares exactly. So its defs don't get the failure marks:
  otherwise a fixed version (`-> int`) wouldn't match a failing one
  (`-> int | None`).

### 1.1 A def's parameter gets the None the checker stripped from the argument (anywhere)

**Fixed:** the checker still strips the None at a call of a def, but only
where an escape analysis (`nones.escapes`) shows the None can't come out
of the call except in its result. Elsewhere the argument goes into the
call with its None. Now `c_param` is `-> int | None` with `acc: list[int |
None]`, `w` is a `list[int | None]` and `b` a `struct[v: int | None]`. A
def whose parameter has a concrete type and keeps the None
(`acc.append(x.upper())`) is a type error at the call.

`infer_call` (typecheck/infer.star:1665-1690) handles an argument that may
be None by removing the `None` from its type and making the *result* of
the call optional. That is right for builtins, which aren't called on a
None. A **def is called**, though (EXTENSIONS.md: "calling a def ... with
it: the function runs"). So inside the def, the parameter holds a None
while its type says `T`, and whatever the def builds from it keeps the
None:

```python
def push(acc, x):          # def push[T](acc: list[T], x: T) -> int
    acc.append(x)
    return 0

def c_param(n):            # def c_param(n: int) -> int
    acc = [0]              #   acc: list[int]   -> holds [0, None]
    d = {0: 0}
    push(acc, d.get(n))
    t = 0
    for v in acc:          #   v: int            -> None
        t = t + v          #   t: int            -> None
    return t               # n : 1  ->  None
```

The same goes for a None returned *inside* a container or struct, where
`??` only removes the outer None:

```python
def wrap(x):               # def wrap[T](x: T) -> list[T]
    return [x]
w = wrap(d.get(n)) ?? []   # w: list[int]   -> [None]

def box(x):                # def box[T](x: T) -> struct[v: T]
    return struct(v = x)
b = box(d.get(n)) ?? struct(v = 0)
b.v                        # int            -> None
```

This applies to every def and lambda called with an optional argument,
directly or through a value. The same happens through `f(*[1, x])`,
`f(**{"q": x})` (section 5), and when an unset reactive variable is read
on the first run (4.4).

### 1.2 `Any` takes in None (anywhere)

**Fixed:** with contagious None, an `Any` counts as possibly None. It is
printed `Any | None`, and the checker handles it as a `T | None`: a
fallible operation's `Any` result, a def that tests, iterates or unpacks
one, a variable assigned one (it becomes optional), and an `Any` used
where a type that isn't optional is wanted (an error), elements of lists,
dicts and sets included. `x ?? y` gives an `Any` that isn't None (printed
`Any`), which is also what `Any` means in a `.start` file.

`mk_opt(Any)` returns `Any` (types.star:118), and `_strip_opt(Any)` is
`None` (infer.star:681). So:

- a fallible operation whose result is `Any` loses its `| None`
  (`getattr(s, name)` is marked fallible, but the result is just `Any`);
- an `Any` passed to a def, tested in `if`/`while`, iterated or unpacked
  never makes the def "fail" or its call optional;
- an `Any` unifies with, and flows into, any non-optional type
  (unify.star:380, `flow` at unify.star:721), so the None spreads to
  variables typed `int`, `str` and so on.

Every place `Any` comes from is listed in section 5.

### 1.3 Statements that fail without marking the def as failing (update)

**Fixed:** these now make the def fail, so its result is `T | None`:

- a read of a variable that may be unassigned (`nones.unbound_def`;
  globals the module may leave unassigned too);
- recursion, including cycles of defs;
- an item assignment, except into a dict the def made itself and isn't
  looping over, or into a list it made, by an index each of its literals
  has, that it doesn't shrink or give away (`nones.safe_setitems`);
- a call with `*args` or `**kwargs`, which is `T | None` itself.

Unhashable dict keys and set elements are type errors (a new bound,
`Hashable`, on what a def makes into a key). A closure that assigns into
its enclosing def's dict (`counter()` in tests/types/fallible.star) is
`T | None` now too, rightly: once a global holds the closure, the dict is
frozen. That was checked at run time.

During an update, an error that is not inside an expression the runtime
can make None (an operator, index, slice, field or builtin call) makes
**the whole call of the enclosing def** None. The checker marks a def as
failing (`_fails`, infer.star:880) only for an `if`/`while`/`for` over a
possibly-None value, unpacking a non-tuple, `fail(...)`, and proto field
assignment. These also fail, and the def's result type stays without
`| None`:

| statement | example | checker | runtime (`n : 1`) |
| --- | --- | --- | --- |
| read of a possibly unbound local | `if n != 1: x = 5` then `return x` | `-> int` | None, "local variable x referenced before assignment" |
| list item assignment out of range | `xs = [0]; xs[n] = 7; return 1` | `-> int` | None, "list index 1 out of range" |
| item assignment during iteration | `for x in xs: xs[0] = 3` | `-> int` | None, "cannot assign to element of list during iteration" |
| assignment into a frozen value | `L[0] = 9` / `D["b"] = 9` (L, D loaded from a module) | `-> int` | None, "cannot assign to element of frozen list" / "cannot insert into frozen hash table" |
| unhashable key or element | `[n] in set()`, `{[n]: 1}`, `d[[n]] = v` | `-> bool` | None, "unhashable type: list" |
| too deep recursion | `def deep(k): return 0 if k == 0 else 1 + deep(k - 1)` | `-> int` | None, "Starlark stack overflow" |
| `*args` of the wrong length | `two(*[n] * (2 - n))` | `-> int` | None, "function two missing 1 argument (b)" |
| `**kwargs` with an unknown key | `two(**{"a": 1, "c": n})` | `-> T` (free, see 5.3) | None, "unexpected keyword argument" |

The common pattern `for x in xs: ...` followed by `return x` (unbound when
`xs` is empty) is the first row. **Module globals are frozen after the
first run**, so any def that assigns into a global list or dict during an
update hits the fourth row. (`G.append(x)` fails too, but that is a
builtin call, so only the call is None, not the def.)

### 1.4 Lambdas don't get the "fails" mark (update)

**Fixed:** a lambda has its own mark. `f_lambda` below is now `->
list[int] | None`, and its failure no longer marks the enclosing def.

`_infer_lambda` (infer.star:1527) copies the enclosing `fc`, so a failing
unpacking inside a lambda's comprehension marks the *enclosing* def (or
nothing, at top level) instead of the lambda's own result:

```python
f_lambda = lambda ps = [[1, 2]]: [a for a, b in ps]   # -> list[int]
f_lambda([[1, 2, 3]])      # None: "too many values to unpack"
```

---

## 2. Operations that can fail but aren't in the checker's lists (update)

`_fallible_op`, `_fallible_call` and `FALLIBLE_METHODS = {index, rindex,
remove, pop}` (infer.star:1439, 1747-1788) leave these out. Each one gives
None in an update, and so does every def that returns it:

| operation | checker | runtime error that becomes the None |
| --- | --- | --- |
| `"{} {}".format(n)` (`str.format`, builtins.star:67) | `str` | "format: tuple index out of range" (also missing named keys) |
| `s.partition(sep)`, `s.rpartition(sep)` with `sep == ""` | `tuple[str, str, str]` | "partition: empty separator" |
| `d.popitem()` on an empty dict | `tuple[K, V]` | "popitem: empty dict" (*not verified*, by analogy with `pop`) |
| a record entry after `d.popitem()`: `d = {"a": n}; d.popitem(); d["a"]` | `T` (no `| None`: `_removals`, infer.star:841, knows only `pop`, `remove`, `clear`) | `key "a" not in dict` |
| slice with a step that may be 0: `xs[::k]` | `list[int]` (slices are never fallible, infer.star:1300) | "zero is not a valid slice step" |
| `bytes(n)` of an int, or of anything that isn't str, bytes or ints (`x: Any`, builtins.star:25) | `bytes` | "bytes: got int, want ..." |
| `float(big)` of an int beyond float range | `float` (`float` of an int is taken to be safe) | "int too large to convert to float" |
| int and float mixed with such an int: `big * 0.5`, `big + 1.0` | `float` | "int too large to convert to float" (verified for `*`) |
| `s.startswith(p)` / `endswith` with a `p` that isn't a str or a tuple of str (`prefix: Any`) | `bool` | "startswith: got int, want string or tuple of string" |
| `s.union(x)`, `s.update(x)` (set) with a non-iterable `x` (`*others: Any`) | `set[T]` | "union: argument #1 is not iterable" |
| `d.update(x)` (dict) with something that isn't pairs (`*args: Any`) | `None` (as a call) | "update: got int, want iterable" (only matters for what it stores: 3.2) |
| `hash(x)` of a list, dict or set (`x: Any`) | `int` | "unhashable type" (*not verified*; same cause as 1.3) |
| `read_file(path)` of a missing or unreadable file | `str` | "read_file: cannot read ..." |
| `getattr(s, name)` with a missing field | `Any` (marked fallible, but see 1.2) | "struct has no .b attribute" |
| `struct(**d).b`: a field of an open struct that isn't there | type of the use (`s: struct[b: int, **Any]`) | "struct has no .b attribute" |

Written-out literals the checker *assumes* are valid (documented, but
still surprises, and easy to get wrong):

| operation | checker | runtime |
| --- | --- | --- |
| `int("zz")`, `int("12", base)` where the base is invalid or doesn't fit the literal | `int` | "invalid literal with base ..." |
| `"%d" % s` with a format string written out but the wrong value type | `str` | "%d format requires integer" |
| `"%s %s" % (n,)`: wrong number of values | `str` | "not enough arguments for format string" |
| `"%(a)s" % m` with a key that isn't in the dict | `str` | "format: key not found in mapping" |
| `chr(1114112)`: an int written out that is no code point (`chr(-1)` is fine: it's an expression) | `str` | "chr: Unicode code point ... out of range" (*not verified* for the positive literal) |

---

## 3. A None stored where the element type has none

**Status: fixed** (typecheck/infer.star: `.setdefault` with one argument
and `dict.update` are typed where they are called, `_dict_store`,
`_sp_dict_update`; `bytes` is in `LOOKS_INSIDE`; typecheck/builtins.star:
`set.update` and `set.union` take iterables of the set's elements, not
`Any`; tests: tests/types/contagious_containers,
err_contagious_containers). Now `d.setdefault("b")` is `int | None`, and
`d` (made by a literal) a `dict[str, int | None]`. `d.update({"b":
e.get(n)})` does the same for `d`. `s.update([e.get(n)])` into a `set[int]`
is an error, and so is a set or dict element of the wrong type.
`bytes([65, x])` is `bytes | None`. The typing of `setdefault`,
`update` and `union` applies with contagious None off too. There the
literal's values don't widen, so `{"a": 1}.setdefault("b")` is an error
("expected int, got None"). A `d.update(x)`
whose `x` is of a type not known yet is still checked against the `Any`
signature.

### 3.1 `d.setdefault(k)` with no default (anywhere)

`def setdefault[K, V](self: dict[K, V], key: K, default: V = ...) -> V`
(builtins.star:111). Leaving out the default stores None and returns it,
and no error is involved:

```python
d = {"a": 1}               # d: dict[str, int]  -> {"a": 1, "b": None}
v = d.setdefault("b")      # int                -> None
```

### 3.2 Builtins with `Any` parameters that store their argument's elements (anywhere)

The argument isn't itself optional, so `infer_call` doesn't strip or lift
it. Its elements aren't checked against the receiver's element type:

```python
s = set([1])
s.update([e.get(n)])       # s: set[int]       -> {1, None}
s.union([x])               # set[int]          -> set([1, None])
d = {"a": 1}
d.update({"b": e.get(n)})  # d: dict[str, int] -> {"a": 1, "b": None}
```

`d.update` and `set.update`/`union` also take elements of the wrong type
altogether, which then give None in the operations that read them (an
update).

### 3.3 `bytes([65, x])` with a None among the elements (anywhere)

`bytes` looks inside its argument but isn't in `LOOKS_INSIDE`
(infer.star:1565): the type is `bytes`, the value None ("None further
in", even outside updates).

---

## 4. Reactive programs: values from input and the first run

### 4.1 A None inside a value from stdin (anywhere)

The rule that a reactive variable is never None only looks at the top
level and at struct block fields. `ql : [1, 2]` is a `list[int]`, but the
input line `ql : [1, None]` is accepted, and `ql` holds `[1, None]`.
Every def that `ql` is passed to gets the None as in 1.1.

### 4.2 Members of an implicit relation with None fields (anywhere)

For `an order:` / `qty: req.qty ?? 0`, the checker types `req` as
`list[struct[qty: int, **Any]]`. The input line `req : struct(id = 1, qty
= None)` is accepted, and an observer's `[inc(r.qty) for r in req]` calls
`inc` (`-> T: (int, float)`) with None and gets `[None]`.

### 4.3 Input of another type (update)

`q : 3` is an `int`, but `q : "x"` on stdin is accepted. A def called on
`q` from an observer (`print(inc(q))`, `def inc(v): return v + 1`) then
fails with "unknown binary op: string + int" and returns None. Its type
says `int`. Reactive definitions are protected, because their update
fails, but observers and the defs they call are not.

### 4.4 First run: an unset reactive variable reads as None (first run)

A definition that reads a variable left unset (one computed from an empty
relation, say `first : order.qty`) gets None and passes it on:
`seen : double(first)` calls `double` with `v = None`, while `v` is an
`int`. Mutating globals from a reactive definition is rejected
(mutation.star), so the effects are limited to what the def does with
the None itself (prints, the values it builds), but the parameter is
None all the same.

### 4.5 Relations of errors: `<x>_id` is `Any`, and is None for a lone variable (anywhere)

(Now `Any | None`, with the fix of 1.2.)

`xError: list[struct[id: int, x_id: Any, trigger: str, field: str,
value: None]]` (the field comes from `_fresh`, infer.star:332). For a
lone variable there is no id: the input `qq : None` gave
`struct(field = "", id = 1, qq_id = None, trigger = "qq", value = None)`.
`value: None` is honest. `x_id` is an `Any` that holds a None.

### 4.6 Fields of an implicit relation that nothing constrains are `Any`

`req.name`, only read into `name: req.name`, makes `order: list[struct[...,
name: Any]]` and `req: list[struct[..., name: Any, **Any]]`. Members from
stdin may lack the field. In a definition the update then fails, but
anything else that reads it gets None.

### 4.7 gRPC requests (*not verified*)

EXTENSIONS.md "gRPC": "a float that isn't finite [is] None" and "a field
read may be missing" (an unset message field, an unset oneof member).
`grpc_struct` (proto.star:486) types every field as present and floats as
`float`. Whether such a request is rejected as a whole (it would be if the
"No None fields" rule applies to it) or gets through to observers wasn't
tested. A message that holds itself more than 6 levels down is `Any`
there (proto.star:490).

---

## 5. Every source of `Any` (and of results that act like it)

Before the fix of 1.2, each of these was a place where a None could
enter without the checker noticing. Now each counts as possibly None
(printed `Any | None`), within the limits listed at the top of section 1.
An `Any` written in a `.start` file means a value that isn't None; for
one that may be None, write `Any | None`.

### 5.1 `Any` the checker infers

| where | source |
| --- | --- |
| `x or y`, `x and y` of different types: `d.get(n) or 3` is `Any` (and holds None when the key is missing) | `_quiet_join`, infer.star:1318 |
| `getattr(x, name)` with a name that isn't written out; `getattr(x, name, default)` unless the name is written out and `x` a known struct | `_sp_getattr`, infer.star:1929 |
| the key function given to `sorted`: `sorted(xs, key = lambda x: x.k)` makes the field `k` `Any` in the inferred types (`key: (T) -> Any`, builtins.star:31) | builtins.star:31 |
| builtins used other than as their special forms: `f = max` / `min` / `struct` / `getattr` / `dict` / `zip`; `min(*xs)`, `max(*xs)`; `dict(*args)` and `dict(**kw)`; `zip(*rows)`, which gives `list[Any]` (`cols[0][0]` is then a free `U | None`) | builtins.star:43-48, `SPECIAL` returning None |
| `struct(**d)`: the rest of the row is `**Any` | `_sp_struct`, infer.star:1908 |
| a type that would contain itself (trees: `kids: list[Any]`) | `bind`, unify.star:189 |
| the elements of an untyped `*args` | EXTENSIONS.md "Any" |
| `proto` without `--descriptor_set`; the `time` module, always | builtins.star:53-54 |
| gRPC messages nested more than 6 levels; map entries without key/value types | proto.star:333, 479-491 |
| implicit relations: the row tail `**Any` and fields only copied (4.6); `<x>_id` of every relation of errors (4.5) | infer.star:257, 332 |
| after an error has been reported (a missing loaded name, a tuple index out of range, a bad unpacking, a call of a non-function...): `Any`, so that checking can go on | infer.star:320, 1127-1145, 1797 |

### 5.2 `Any` the programmer writes

`Any` in a `.start` file (e.g. `dict[str, Any]`, the recommended way to
type dict records), and bare `list`, `dict`, `tuple` there, which become
`list[Any]` etc. (stubs.star:605, 612).

### 5.3 Results that are a free type parameter

Some inferred results are a type parameter that nothing ties to the
arguments, so the caller can use them as any type, as with `Any`:

- a call with `**kwargs`: arguments given with `**` aren't matched
  against the parameters (`apply`, `any_kw`), so `def c_kwstar(n) ->
  two(**{...})` is `def c_kwstar[T](n: int) -> T`;
- elements obtained through an `Any` container: `zip(*rows)[0][0]` is
  `U | None`.

---

## 6. Checked and found consistent

What the checker does get right, for reference (verified by a run, or read in the code):
`d.get(k)`, indexing, `//` `/` `%` by a value, `min`/`max` of one
sequence, `getattr` with a written-out name, `.index`/`.remove`/`.pop`,
`.split("")`, `range(..., 0)`, `ord`/`chr`/`int`/`float` of values, a
None inside `sorted`, `.join`, `%` with conversions other than `%s`/`%r`,
and `dict(pairs)`, comparisons that look inside (`(1, x) == (1, 2)`), a
`Contagious` type parameter meeting a None (`k([d.get(2)])`), `*[x]`
arguments to builtins and defs (but `**{"q": x}` gives `Any`: 5.3), `if`/`for`/unpacking on an
optional value, fields of an optional struct (`f(struct(a = x))`), and a
reactive variable set to None on stdin (`qq : None` is rejected, and goes
to `qqError`).
