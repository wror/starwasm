# error: string>:1: $endif without $if
load("../../template.star", "render_string")
render_string("$endif\n", {}, {"a.html": "$include b.html", "b.html": "$include a.html", "bad.html": "x\n$nope"})
