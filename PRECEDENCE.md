# Operator precedence

Here are all the operators and punctuation supported by starwasm.

Operators on higher lines bind more tightly than those on lower lines, when they are unambiguous.

Starwasm forbids many cases where the precedence is ambiguous, see below.

- `( )` `[ ]` `{ }` `.`
- prefix operators: `-` `+` `~` `not`
- `*` `&` `/` `//` `%` `<<` `>>`
- `+` `-` `^` `|`
- `==` `!=` `<` `>` `<=` `>=` `in` `not in`
- `and`
- `or` `??`
- `x if c else y`
- `lambda`
- `,`

Assignment binds less tightly than all the operators: `:` `=` `+=` `-=` `*=` `/=` `//=` `%=` `&=` `|=` `^=` `<<=` `>>=`.

Statement separation `;` binds least tightly of all.

`#` starts a comment.

`\` at the end of a line continues it on the next.

`**` can occur only at the beginning of a function parameter/argument.

`*` `=` and `:` are also used in other contexts.

The ambiguous cases are:

* Different operators within the same line in the list above generally, e.g. `a * b / c`, except:
  * mixing `+` with `-`, mixing `()` `[]` `{}` and `.` with each other, and mixing prefix operators. Those three cases are not considered ambiguous.
* Different operators on different lines, in these cases:
  * `not` with comparisons, arithmetic, bitwise operators or `??`, e.g. `not x == y`
  * `and` or `or` with arithmetic, bitwise operators or `??`, e.g. `a and x + y`
  * `??` with comparisons, e.g. `n ?? 0 == 1`
  * bitwise operators (`&` `<<` `>>` `^` `|`) with arithmetic (`*` `/` `//` `%` `+` `-`) or comparisons, e.g. `1 << n - 1`, `a & b == c`
  * except that prefix `-` `+` `~` are never ambiguous, nor is `not` directly after another operator, e.g. `-a and b`, `a ?? not b`.
* These operators do not even chain with themselves:  `/` `//` `%` `<<` `>>` `==` `!=` `<` `>` `<=` `>=` `in` `not in`

## Spacing

Where operators may be mixed, the spacing must not contradict how they
group. An operator that binds more tightly may not be spaced more widely
than the operator around it:

    a+b * c                # error: a+(b * c), spaced as (a+b) * c
    a * b+c                # error: (a * b)+c, spaced as a * (b+c)
    a - b-c                # error: (a - b)-c, spaced as a - (b-c)
    x + 1==y               # error: (x + 1)==y, spaced as x + (1==y)
    not  a or b            # error: (not  a) or b, spaced as not (a or b)
    a or b  and  c         # error: a or (b  and  c), spaced as (a or b) and c
    - x+y                  # error: (- x)+y, spaced as -(x+y)

    a + b*c                # a + (b*c)
    a+b+c                  # (a+b)+c
    x+1 < y                # (x+1) < y
    a or b and c           # a or (b and c)

The precise rule:

- An operator's **width** is the number of spaces or tabs on its wider
  side. For a prefix operator (`not`, `-`, `+`, `~`), it is the number
  after it.
- Wherever one operator's expression is the unparenthesized operand of
  another, the inner operator's width must be no greater than the outer
  one's. Equal widths are always fine, so `a + b * c` and `a+b*c` are
  both accepted.
- An operator with a line break, a comment or a backslash continuation on
  either side has no width and is not checked. Where a long expression
  breaks across lines, the break says nothing about grouping.
- A prefix operator right after another operator, as in `a * -b` or
  `a or not  b`, can be read only one way, so its spacing is not checked.

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
  binds less tightly than every set after it, and nothing else. The
  spacing rule is `_spacing`. Both checks are in `check_stmts`, run on
  each module the checker reads (`check_module` in
  `typecheck/infer.star`).
- `compiler/parser.star` marks every parenthesized expression with
  `paren: True`. That is how the checker tells `(a & b) == c` from
  `a & b == c`.
- Tests: `tests/types/precedence.star` (accepted) and
  `tests/types/err_precedence.star` (each kind of error), run by
  `tests/types.sh`; `tests/precedence_test.star` (unit tests).
