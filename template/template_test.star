# Tests of template.star. Run with any Starlark interpreter that resolves
# load() relative to this file, e.g. bin/starhost template/template_test.star

load("template.star", "render", "render_string")

FILES = {
    "dog.html": "the dog barked\n",
    "cat.html": "the $adj cat sat\n",
    "mouse.html": "the mouse ran",
    "header.html": "<h1>$title</h1>\n",
    "t/page.html": "$include part.html\nend\n",
    "t/part.html": "part of $title",
    "outer.html": "<ul>\n$for items\n$include item.html\n$endfor\n</ul>\n",
    "item.html": "  <li>$items.name</li>\n",
}

def eq(label, got, want):
    if got != want:
        fail("%s:\n--- want\n%s\n--- got\n%s" % (label, want, got))

def t(label, src, vars, want):
    eq(label, render_string(src, vars, FILES), want)

def test_vars():
    t("var", "the quick brown fox $action the lazy dog", {"action": "jumped over"}, "the quick brown fox jumped over the lazy dog")
    t("dotted", "$a.b.c, $a.n.", {"a": {"b": {"c": "x"}, "n": 3}}, "x, 3.")
    t("braces", "${a}b $$5 $ 5 $1 a$", {"a": "x"}, "xb $5 $ 5 $1 a$")
    t("struct-free scalars", "$i $f $b", {"i": 1, "f": 1.5, "b": True}, "1 1.5 True")

def test_line():
    src = "the quick brown fox\n$if action\njumped over\n$endif\nthe lazy dog\n"
    t("if true", src, {"action": True}, "the quick brown fox\njumped over\nthe lazy dog\n")
    t("if false", src, {"action": False}, "the quick brown fox\nthe lazy dog\n")
    t("if unset", src, {}, "the quick brown fox\nthe lazy dog\n")
    t("indented directive", "a\n  $if x  \nb\n\t$endif\nc", {"x": 1}, "a\nb\nc")
    src = "$for pets\n- $pets.name ($pets.kind)\n$endfor\n"
    t("for", src, {"pets": [{"name": "Rex", "kind": "dog"}, {"name": "Tom", "kind": "cat"}]}, "- Rex (dog)\n- Tom (cat)\n")
    t("for empty", "a\n" + src + "b", {"pets": []}, "a\nb")
    t("for scalars", "$for n\n$n,\n$endfor\n", {"n": (1, 2, 3)}, "1,\n2,\n3,\n")
    src = "$for g\n$g.name:\n$for g.items\n  $g.items of $g.name\n$if g.items.x\n!\n$endif\n$endfor\n$endfor\n"
    t("nested for", src, {"g": [{"name": "a", "items": ["1", "2"]}, {"name": "b", "items": []}, {"name": "c", "items": ["3"]}]}, "a:\n  1 of a\n  2 of a\nb:\nc:\n  3 of c\n")
    t("shadow restored", "$for x\n$x\n$endfor\n$if x\nyes\n$endif\n", {"x": ["a"]}, "a\nyes\n")
    t("include", "<body>\n$include header.html\n</body>\n", {"title": "Hi"}, "<body>\n<h1>Hi</h1>\n</body>\n")
    t("include adds newline", "a\n$include mouse.html\nb\n", {}, "a\nthe mouse ran\nb\n")
    t("include at eof", "a\n$include mouse.html", {}, "a\nthe mouse ran")
    t("include in for", "$include outer.html\n", {"items": [{"name": "a"}, {"name": "b"}]}, "<ul>\n  <li>a</li>\n  <li>b</li>\n</ul>\n")
    eq("include dir", render("t/page.html", {"title": "T"}, FILES), "part of T\nend\n")
    eq("read function", render("t/page.html", {"title": "T"}, lambda p: FILES[p]), "part of T\nend\n")

def test_line_alternatives():
    src = "a\n$if animal dog.html cat.html mouse.html\nb\n"
    t("alt by name", src, {"animal": "dog"}, "a\nthe dog barked\nb\n")
    t("alt by file name", src, {"animal": "cat.html", "adj": "fat"}, "a\nthe fat cat sat\nb\n")
    t("alt by index", src, {"animal": 2}, "a\nthe mouse ran\nb\n")
    t("alt unset", src, {}, "a\nb\n")
    t("alt empty", src, {"animal": ""}, "a\nb\n")
    t("alt true", "$if x dog.html mouse.html\n", {"x": True}, "the dog barked\n")
    t("alt false", "$if x dog.html mouse.html\n", {"x": False}, "the mouse ran\n")
    t("alt false, one file", "$if x dog.html\n", {"x": False}, "")

def test_html():
    src = "the quick brown fox\n<div $if=\"action\">\njumped over\n</div>\nthe lazy dog\n"
    t("html if true", src, {"action": 1}, "the quick brown fox\n<div>\njumped over\n</div>\nthe lazy dog\n")
    t("html if false", src, {}, "the quick brown fox\nthe lazy dog\n")
    t("html if inline", "a <b class=\"$c\" $if='x' id=i>$x</b> c", {"x": "X", "c": "k"}, "a <b class=\"k\" id=i>X</b> c")
    t("html if inline false", "a <b $if=x>$x</b> c", {}, "a  c")
    t("html nested same tag", "<div $if=\"x\"><div>a</div><div/>b</div>c", {"x": 1}, "<div><div>a</div><div/>b</div>c")
    t("html nested same tag false", "<div $if=\"x\"><div>a</div>b</div>c", {}, "c")
    t("html nested directives", "<p $if=\"x\"><i $if=\"y\">$y</i><b $if=\"z\">$z</b></p>", {"x": 1, "z": "Z"}, "<p><b>Z</b></p>")
    t("html for", "<ul>\n  <li $for=\"items\">$items.name</li>\n</ul>\n", {"items": [{"name": "a"}, {"name": "b"}]}, "<ul>\n  <li>a</li>\n  <li>b</li>\n</ul>\n")
    t("html for inline", "<p><i $for=\"n\">$n</i></p>", {"n": [1, 2]}, "<p><i>1</i><i>2</i></p>")
    t("html for empty", "<ul>\n  <li $for=\"items\">$items</li>\n</ul>\n", {"items": []}, "<ul>\n</ul>\n")
    t("html and line mixed", "<ul $if=\"items\">\n$for items\n<li>$items</li>\n$endfor\n</ul>\n", {"items": ["a", "b"]}, "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n")
    t("quoted >", "<a title=\"a>b\" $if=\"x\">t</a>", {"x": 1}, "<a title=\"a>b\">t</a>")
    t("html include", "<body>\n  <div $include=\"header.html\"/>\n</body>\n", {"title": "Hi"}, "<body>\n<h1>Hi</h1>\n</body>\n")
    t("html include inline", "<p>[<span class=\"x\" $include=\"dog.html\"></span>]</p>", {}, "<p>[the dog barked]</p>")
    t("html include section", "a <section $include=mouse.html /> b", {}, "a the mouse ran b")

def test_html_alternatives():
    src = "something funny happened. the story is <q><span $if=\"animal\" $else=\"dog.html cat.html mouse.html\"/></q> imagine that!"
    t("else by name", src, {"animal": "cat", "adj": "fat"}, "something funny happened. the story is <q>the fat cat sat</q> imagine that!")
    t("else by index", src, {"animal": 0}, "something funny happened. the story is <q>the dog barked</q> imagine that!")
    t("else unset", src, {}, "something funny happened. the story is <q></q> imagine that!")
    src = "something funny happened. the story is <q><span $if=\"animal\" $else=\"dog.html cat.html mouse.html\">the quick brown $fox jumped over the lazy dog.</span></q> imagine that!"
    t("else+content by name", src, {"animal": "mouse"}, "something funny happened. the story is <q>the mouse ran</q> imagine that!")
    t("else+content unset", src, {"fox": "fox"}, "something funny happened. the story is <q><span>the quick brown fox jumped over the lazy dog.</span></q> imagine that!")
    t("else first", "<div $else=\"dog.html\" id=\"a\" $if=\"x\">d</div>", {}, "<div id=\"a\">d</div>")
    src = "a\n<div $if=\"animal\" $else=\"dog.html mouse.html\">\n  none\n</div>\nb\n"
    t("else own lines", src, {"animal": "mouse"}, "a\nthe mouse ran\nb\n")
    t("else own lines unset", src, {}, "a\n<div>\n  none\n</div>\nb\n")

def test_all():
    test_vars()
    test_line()
    test_line_alternatives()
    test_html()
    test_html_alternatives()
    print("template: ok")

test_all()
