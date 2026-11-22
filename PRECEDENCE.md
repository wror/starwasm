# Operator precedence

Starlark, like C and Python, places every operator in one ranked list, so
any mix of operators parses without parentheses. Some of those parses
surprise readers:

    flags & mask == 0      # (flags & mask) == 0 here, but flags & (mask == 0) in C
    not x == y             # not (x == y) here, but (!x) == y in C
    1 << n - 1             # 1 << (n - 1)
    x / y * z              # (x / y) * z
    count ?? 0 + 1         # count ?? (0 + 1), not (count ?? 0) + 1
    ready ?? a or b        # ready ?? (a or b)

starwasm's **type checker** (`node host/typecheck.mjs prog.star`, and
`.check on` in the REPL) holds programs to a stricter rule. Operators are
ranked against each other only where there is a convention everyone
shares, such as `*` before `+`, `and` before `or`, and arithmetic before
comparison. Where there is no such convention, the two operators can't be
mixed without parentheses. The checker reports each such place as an
error:

    prog.star:3:10: error: operator precedence: `&` and `==` have no precedence relative to each other: add parentheses, as in (a & b) == c (how it parses) or a & (b == c)
        3 | if flags & mask == 0:
          |          ^

The language itself is unchanged. The compiler and starlark-go parse and
run every program as before. A program the checker accepts means the same
thing to every reader, whatever language they came from.

## The rule

Each operator belongs to a **group**:

| Group       | Operators                              | Chains with itself?          |
|-------------|----------------------------------------|------------------------------|
| coalesce    | `??`                                   | yes: `a ?? b ?? c`           |
| or          | `or`                                   | yes                          |
| and         | `and`                                  | yes                          |
| not         | `not` (prefix)                         | yes: `not not x`             |
| comparison  | `==` `!=` `<` `>` `<=` `>=` `in` `not in` | no (a syntax error already)  |
| add         | `+` `-`                                | yes: `a - b + c`             |
| multiply    | `*`                                    | yes: `a * b * c`             |
| divide      | `/` `//`                               | **no**: `a / b / c` is an error |
| modulo      | `%`                                    | **no**: `a % b % c` is an error |
| bit-or      | `\|`                                   | yes                          |
| bit-xor     | `^`                                    | yes                          |
| bit-and     | `&`                                    | yes                          |
| shift       | `<<` `>>`                              | **no**: `a << b >> c` is an error |

Chaining is always from the left: `a - b - c` is `(a - b) - c`.

An operand of an operator may be another operator's expression, without
parentheses, only if that operator binds more tightly. The **only** pairs
where one binds more tightly than the other are the ones below. No others
follow from them: precedence here is *not transitive*. For example, `and`
binds less tightly than `==`, and `==` less tightly than `+`, yet `and`
and `+` are not related, so `a and x + y` is an error.

| Operator     | Its operands may be, unparenthesized                   |
|--------------|--------------------------------------------------------|
| `??`         | `+ - * / // %`, `\| ^ & << >>`                         |
| `or`         | `and`, `not`, comparisons                              |
| `and`        | `not`, comparisons                                     |
| `not`        | nothing but terms (and `not`)                          |
| comparisons  | `+ -`, `* / // %`                                      |
| `+ -`        | `* / // %`                                             |
| `* / // %`   | nothing but terms (and `*` chains with `*`)            |
| `\|` `^`     | `&`, `<< >>` (and each of `\|` `^` with itself)        |
| `& << >>`    | nothing but terms (and `&` with itself)                |

A **term** is anything that is not an operator expression. That covers a
name, a literal, a call, indexing or slicing, an attribute, a list, dict or
comprehension, anything in parentheses, and a prefix `-x`, `+x` or `~x`.

Put the other way round, these are the mixes that need parentheses:

- **Logic with anything but comparisons**: `a and x + y`, `a or b | c`,
  `not x + y`.
- **`not` with a comparison**: `not x == y`. Write `x != y`, `x not in y`,
  or `not (x == y)`. C, Java, Go and JavaScript read `!x == y` as
  `(!x) == y`, while Python and Starlark read it as `not (x == y)`.
- **Bitwise operators with comparisons**: `a & b == c`. C reads this as
  `a & (b == c)` and Python as `(a & b) == c`.
- **Bitwise operators with arithmetic**: `1 << n - 1`, `a & b + 1`.
- **`|` with `^`**: `a | b ^ c`. C and Python read it as `a | (b ^ c)`,
  Go and Swift as `(a | b) ^ c`.
- **`&` with shifts**: `a & b << 4`. C and Python read it as
  `a & (b << 4)`, Go as `(a & b) << 4`. (`&` and shifts inside `|` or
  `^` are fine: `a | b & c`, `a ^ b << 4`.)
- **`*`, `/`, `//` and `%` with each other**: `x / y * z`, `x * y // z`,
  `x * y % z`. Is `6 / 2 * 3` 9 or 1? People disagree. Chains of `/`,
  `//`, `%` and of shifts are errors too: `x / y / z`.
- **`??` with comparisons or logic**: `n ?? 0 == 1`, `n ?? a or b`,
  `not n ?? b`. Swift and Kotlin rank `??` above comparisons, while C# and
  JavaScript rank it below. JavaScript forbids `a ?? b || c` outright.

## What needs no parentheses

    x + y * z                  # x + (y * z)
    x - y - z                  # (x - y) - z
    x + 1 < y * 2              # (x + 1) < (y * 2)
    x in xs + [1]              # x in (xs + [1])
    a or b and c               # a or (b and c)
    not a and b                # (not a) and b
    x < y and y < z            # (x < y) and (y < z)
    -x * y                     # (-x) * y
    a and -b                   # a and (-b)
    ~mask & flags              # (~mask) & flags
    flags | mask & 1           # flags | (mask & 1)
    flags ^ mask & 1           # flags ^ (mask & 1)
    flags | n << 4             # flags | (n << 4)
    "%d items" % n + "!"       # ("%d items" % n) + "!"
    total + tax ?? 0           # (total + tax) ?? 0
    n ?? m ?? 0                # (n ?? m) ?? 0
    x + 1 if ok else y - 1     # (x + 1) if ok else (y - 1)
    x if a else y if b else z  # x if a else (y if b else z)

### Prefix operators

`-`, `+` and `~` always bind more tightly than any binary operator, and
their operand is always a single term. `-x.y` is `-(x.y)`, and `-f(x)` is
`-(f(x))`. That holds in every language with these operators. Starlark
has no `**`, so the one exception, Python's `-x ** 2`, doesn't arise. So
they never need parentheses: `-a and b`, `~m == 0` and `x << -n` are all
fine.

`not` binds less tightly than comparisons in Starlark, and more tightly
in C. It is in the table above like a binary operator. A `not` right after
another operator, as in `a or not b` or `x ?? not y`, can be read only one
way, so it never needs parentheses there.

### Conditional expressions and lambdas

`x if c else y` and `lambda` bind less tightly than every operator. The
keywords mark off their parts, so each part may be any expression. Used as
an operand they must be in parentheses, and Starlark's parser already
requires that.

## Why

This follows Jeff Walker, ["Operator Precedence: We can do
better"](https://blog.adamant-lang.org/2019/operator-precedence/) (2019).
Most languages give operator precedence as a *total order*: a list of
levels, where every operator outranks or is outranked by every other. That
forces a decision on pairs no reader has an intuition for, like `&`
against `==` or `??` against `or`, and whatever gets picked surprises
someone. Making every operator need parentheses fixes that, but then
`x + y * z` needs them too.

The article's answer is **intransitive precedence**. Declare
"binds more tightly than" only between operators that have a convention,
and make the relation deliberately *not transitive*. `and` below `==` and
`==` below `+` must not imply `and` below `+`, or `a and x + y` would be
accepted. An expression that mixes two unrelated operators needs
parentheses. Operators of one group may chain only when the group says
they associate: comparisons, divisions, `%` and shifts don't.

The article's example grammar is for a small language. Here the same idea
is applied to Starlark's operators, under one constraint: the checker
can't change how Starlark parses. Every relation it declares therefore
agrees with Starlark's own ranking. The checker reads the tree the parser
built and only rejects operands that the relation does not allow there
without parentheses.

## In the code

- `typecheck/precedence.star`: the groups (`GROUP`), what chains
  (`ASSOC`) and the relation (`CHAINS`). The relation is written in the
  article's notation: each chain says that every set of groups in it
  binds less tightly than every set after it, and nothing else. The check
  is `check_stmts`, run on each module the checker reads (`check_module`
  in `typecheck/infer.star`).
- `compiler/parser.star` marks every parenthesized expression with
  `paren: True`. That is how the checker tells `(a & b) == c` from
  `a & b == c`.
- Tests: `tests/types/precedence.star` (accepted) and
  `tests/types/err_precedence.star` (each kind of error), run by
  `tests/types.sh`.
