# error: no template "zzz.html"
load("../../template.star", "render_string")
render_string("$include zzz.html\n", {}, {"a.html": "$include b.html", "b.html": "$include a.html", "bad.html": "x\n$nope"})
