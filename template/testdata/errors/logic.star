# error: $if takes a variable name
load("../../template.star", "render_string")
render_string("$if x==1\n$endif\n", {}, {"a.html": "$include b.html", "b.html": "$include a.html", "bad.html": "x\n$nope"})
