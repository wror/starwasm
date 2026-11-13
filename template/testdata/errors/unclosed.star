# error: string>:2: $for has no $endfor
load("../../template.star", "render_string")
render_string("a\n$for x\nb", {}, {"a.html": "$include b.html", "b.html": "$include a.html", "bad.html": "x\n$nope"})
