# error: which is none of dog.html cat.html
load("../../template.star", "render_string")
render_string("$if x dog.html cat.html\n", {"x": "cow"}, {"a.html": "$include b.html", "b.html": "$include a.html", "bad.html": "x\n$nope"})
