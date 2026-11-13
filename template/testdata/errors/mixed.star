# error: is closed by
load("../../template.star", "render_string")
render_string("<div $if=\"x\">\n$for x\n</div>\n$endfor\n", {}, {"a.html": "$include b.html", "b.html": "$include a.html", "bad.html": "x\n$nope"})
