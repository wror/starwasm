# error: string>:2: $x is not defined
load("../../template.star", "render_string")
render_string("a\n$x", {}, {"a.html": "$include b.html", "b.html": "$include a.html", "bad.html": "x\n$nope"})
