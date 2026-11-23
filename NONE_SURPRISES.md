# None surprises

Where, with contagious None on, a variable, parameter or function result
can hold None although the type checker (`typecheck/`) gives it a type
without `| None`; and where the checker gives `Any`. What the checker does
model is described in EXTENSIONS.md ("Fallible operations", "Input that
doesn't fit"); this file lists only what it doesn't.

**When a None appears.** Contagious None turns errors into None in two
situations:

- **Update**: while a reactive program applies a line of input, *every*
  error becomes a None.
- **Anywhere**: in any program with contagious None (the first run, and
  non-reactive programs compiled with `--contagiousnone`), only errors
  caused by a None, and Nones that are passed along, are silent.

A None that reaches a reactive definition that doesn't allow it (no `??
None`) makes the update fail, into `xError`, so reactive variables stay
as typed. The cases below are about the defs, locals, parameters and
observer expressions that run along the way.

Every case was seen in a run: the types are the checker's output
(`bin/starhost --recursion typecheck/main.star --print`), and the None is
what `node host/run.mjs` printed, with an update on stdin where the case
says "update".

---

## 1. In the checker

### 1.1 A def's parameter holds the None of its argument (anywhere)

At a call of a def with an argument that may be None, the checker checks
the call as if the argument weren't None and makes the result optional.
It does that only where an escape analysis (typecheck/nones.star,
`escapes`) shows the None can't leave the call except in its result.
Inside the def, though, the parameter holds the None while typed `T`, and
so do the locals computed from it:

```python
def describe(v):           # def describe[T: (int, float)](v: T) -> str
    w = v * 2              #   w: T   -> None
    print("double:", w)    #   prints "double: None"
    return "done"

r = describe(d.get(5))     # r: str | None   (here "done")
```

The None doesn't get out of the call: what the caller sees is the result,
which is optional (and may be None where the def returns what it computed
from the parameter). Only what the def does inside, as the `print` here,
shows a value of type `T` that is None.

### 1.2 `Hashable` and declared open structs (update)

A struct used as a dict key or set element must be hashable, and so must
the fields its row variable (`**R`) turns out to stand for. The checker
keeps that requirement on the row variable, but the annotation language
has no way to write it (`**R` takes no bound), so the `.starit` file
doesn't show it. A def whose signature is declared in a `.start` file
(the `.starit` used as one, too) has a rigid `**R` without it, and a list
in one of those fields isn't seen:

```python
# keyed.start:  def keyed[T: Hashable, **R](s: struct[a: T, **R]) -> dict[struct[a: T, **R], T]
def keyed(s):
    return {s: s.a}

bad = keyed(struct(a = 1, b = [2]))   # in an update: "unhashable type: list" -> None
```

Without the declaration, that call is a type error.

### 1.3 A name bound by several defs (update)

A def redefined (`--globalredefine`, the REPL) has one function type for
all its definitions, compared exactly. Its defs don't get the marks that
make a def's result optional (a read of an unassigned variable, recursion,
an item assignment that may fail), since a fixed version (`-> int`) would
then not match a failing one (`-> int | None`):

```python
def f(c):
    return 2

def f(c):                  # f: (c: bool) -> int
    if c:
        y = 1
    return y               # f(False) in an update  ->  None
```

### 1.4 `float` of a huge int (update)

`float(n)`, and `n` in arithmetic with floats (`n * 0.5`), fail for an int
beyond about 1.8e308: "int too large to convert to float". The checker
types them as `float`. Making every int-to-float conversion `| None` would
cost every program for ints almost none has.

---

## 2. In reactive programs

### 2.1 Input checked against a value that says little (update)

A value from standard input must be of the type of the value it replaces
(EXTENSIONS.md, "Input that doesn't fit"). Where that value says nothing,
anything that isn't None goes: an unset variable, an empty list or dict
(its elements), the first member of an implicit relation. A value of the
wrong type then makes what observers and the defs they call do with it
fail, which gives None:

```python
def inc(v):                # def inc[T: (int, float)](v: T) -> T
    return v + 1

xs : []                    # xs: list[Any]
print([inc(x) for x in xs])   # xs : ["a"]  ->  [None]
```

### 2.2 Fields that only observers read (update)

A member of an implicit relation must have the fields that the relations'
definitions read (except before `??`). A field that only an observer reads
may be missing, and reading it gives None. Where nothing tells the field's
type, the checker says so (`other: Any | None`); where the observer's use
does, it doesn't:

```python
an order:
    qty: req.qty           # req: list[struct[qty: Any, other: int, **Any]]

print([r.other + 1 for r in req])   # req : struct(id = 1, qty = 2)  ->  [None]
```

---

## 3. Where the checker gives `Any`

With contagious None, every `Any` the checker infers is `Any | None`, and
treated as possibly None. These are the places
it infers one:

| where | code |
| --- | --- |
| `x or y`, `x and y` of different types | `_quiet_join`, typecheck/infer.star |
| `getattr(x, name)` with a name not written out; `getattr(x, name, default)` unless the name is written out and `x` a known struct | `_sp_getattr` |
| `struct(**d)`: its fields aren't known | `_sp_struct` |
| a type that would contain itself (trees: `kids: list[Any]`) | `bind`, typecheck/unify.star |
| builtins used as values (`f = max`), and `min`, `max`, `dict`, `zip` called in other ways than their typed forms | typecheck/builtins.star |
| `proto` without `--descriptor_set`; the `time` module, always | typecheck/builtins.star |
| gRPC messages nested more than 6 levels; map entries without key or value types | typecheck/proto.star |
| the rest of an implicit relation's fields (`**Any`) | `_implicit_relations` |
| after a reported error (a missing loaded name, a tuple index out of range, a bad unpacking, a call of a non-function), so that checking goes on | typecheck/infer.star |

An `Any` written in a `.start` file (`dict[str, Any]`, and a bare `list`,
`dict` or `tuple`) means a value that isn't None; `Any | None` one that
may be. Either opts the value out of checking: it may be of any type at
run time, and an operation it doesn't support fails, which in an update
gives None where the checker gives a type without `| None`.
