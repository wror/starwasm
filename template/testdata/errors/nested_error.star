# error: bad.html:2: $nope is not defined
load("../../template.star", "render_string")
render_string("$include bad.html\n", {}, {"a.html": "$include b.html", "b.html": "$include a.html", "bad.html": "x\n$nope"})
