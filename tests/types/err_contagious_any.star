# With contagious None (on here: the program has a reactive variable), an Any
# that nothing is known about may be None, and can't be used where a type
# that isn't optional is wanted (an annotation's); `?? default` makes it
# one that isn't None. An Any in the .start file isn't None.
cfg = struct(width = 3)

def setting(name):
    return getattr(cfg, name + "")

limit = 0
limit = setting("width")
other = setting("width") ?? 0
items = {"a": 1}
items = {"b": items.get("a")}

tick : 1
names = ["a"]
names = [d.get(1) for d in [{1: "b"}]]
getter = lambda: setting("width")      # its result may be None
