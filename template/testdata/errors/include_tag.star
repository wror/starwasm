# error: $include can be an attribute of <div>, <span> or <section>, not <p>
load("../../template.star", "render_string")
render_string("<p $include=\"a.html\"/>", {}, {"a.html": "$include b.html", "b.html": "$include a.html", "bad.html": "x\n$nope"})
