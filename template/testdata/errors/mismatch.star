# error: $for at line 1 is closed by $endif
load("../../template.star", "render_string")
render_string("$for x\n$endif\n", {}, {"a.html": "$include b.html", "b.html": "$include a.html", "bad.html": "x\n$nope"})
