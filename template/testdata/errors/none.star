# error: only strings and numbers
load("../../template.star", "render_string")
render_string("$x", {"x": None}, {"a.html": "$include b.html", "b.html": "$include a.html", "bad.html": "x\n$nope"})
