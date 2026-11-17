# error: $if must be alone on its line
load("../../template.star", "render_string")
render_string("a $if x\n", {}, {"a.html": "$include b.html", "b.html": "$include a.html", "bad.html": "x\n$nope"})
