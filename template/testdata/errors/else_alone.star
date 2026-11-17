# error: needs an $if attribute
load("../../template.star", "render_string")
render_string("<div $else=\"a.html\"/>", {}, {"a.html": "$include b.html", "b.html": "$include a.html", "bad.html": "x\n$nope"})
