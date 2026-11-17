# error: needs a closing </div>
load("../../template.star", "render_string")
render_string("<div $if=\"x\"/>", {}, {"a.html": "$include b.html", "b.html": "$include a.html", "bad.html": "x\n$nope"})
