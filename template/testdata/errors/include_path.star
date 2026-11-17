# error: $include takes the name of a file in the template
load("../../template.star", "render_string")
render_string("$include ../a.html\n", {}, {"a.html": "$include b.html", "b.html": "$include a.html", "bad.html": "x\n$nope"})
