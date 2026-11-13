# template

A small template language, implemented in plain Starlark. It is independent
of the rest of this repository: `template.star` loads nothing and uses no
recursion, `while`, or host builtins, so it runs in any Starlark.

    load("template.star", "render", "render_string")

    render("pages/index.html", {"title": "Hi"}, read_file)   # a template file
    render_string("hello $name", {"name": "world"})          # template text

`read` is how files are read: a function from a path to its contents, or a
dict from paths to contents. Errors `fail()` with `file:line: message`.

## Variables

    the quick brown fox $action the lazy dog

`$name` is replaced by the variable's value (a string, number or bool).
`$a.b` reaches into a nested dict or struct. `${name}` delimits the name
from following text, and `$$` is a literal `$`; a `$` that is not followed
by a name is left alone. Using a variable that is not defined is an error.
Values are inserted as they are: nothing is HTML-escaped.

## $if, $for, $include

These take a variable name (or, for `$include`, a file name) and no logic.
Each can be written in two ways.

**On a line of its own**, with nothing else on the line but whitespace; the
blocks end with a line holding `$endif` or `$endfor`. Directive lines leave
nothing in the output.

    the quick brown fox
    $if action
    jumped over
    $endif
    the lazy dog

    $for pets
    - $pets.name is a $pets.kind
    $endfor

    $include header.html

**As an attribute of an HTML element**, which must have a closing tag. The
element's content is expanded, and the attribute is removed:

    the quick brown fox
    <div $if="action">
    jumped over
    </div>
    the lazy dog

    <ul>
      <li $for="pets">$pets.name</li>
    </ul>

    <div $include="header.html"/>

* `$if` keeps the section (or the element) if the variable is defined and
  true, in Starlark's sense.
* `$for` repeats the section (or the element, tags included) for each item
  of a list. Its variable name is the prefix for the item inside the
  section: within `$for pets`, `$pets` is the current pet and `$pets.name`
  its name. Loops nest: `$for pets.toys` inside it makes `$pets.toys` the
  current toy.
* `$include` is replaced by the expansion of another template file in the
  same directory, with the same variables. As an attribute it is allowed
  only on `<div>`, `<span>` and `<section>`, and replaces the whole element
  (which must be empty; it may be self-closing).

An element that is dropped, or replaced by an include, takes its lines with
it if it has them to itself, so no blank line is left behind.

## $if with alternatives

Instead of a section, an `$if` can choose among template files.

On a line, the file names follow the variable name, and there is no
`$endif`:

    $if animal dog.html cat.html mouse.html

On an element, they go in an `$else` attribute:

    the story is <q><span $if="animal" $else="dog.html cat.html mouse.html"/></q> imagine that!

    the story is <q><span $if="animal" $else="dog.html cat.html mouse.html">the
    quick brown fox jumped over the lazy dog.</span></q> imagine that!

The variable picks the file, which then replaces the line or the whole
element:

| value | includes |
| --- | --- |
| a string | the file of that name, with or without its extension (`"cat"` or `"cat.html"`); any other string is an error |
| an int | the file at that index, from 0 |
| `True` / `False` | the first file / the second, if there is one |
| not defined, `None`, `""` | no file |

When no file is picked, a self-closing element (and the line form) expands
to nothing, and an element with content is kept, with the two attributes
removed and its content expanded: the content is the fallback.

## Tests

    template/test.sh [interpreter]     # default: bin/starhost
