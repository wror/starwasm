# error: $for x: it is a string, not a list
load("../../template.star", "render_string")
render_string("$for x\n$endfor\n", {"x": "s"}, {"a.html": "$include b.html", "b.html": "$include a.html", "bad.html": "x\n$nope"})
