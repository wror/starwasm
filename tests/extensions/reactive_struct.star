# Struct blocks: `name :` then indented `field : value` lines is sugar for
# `name : struct(field = value, ...)`.
a:
 b: 123
 c: 456
print(a)

w : 3
box:
    size:                       # blocks nest
        width: w
        height: w * 2

    # blank lines and comments are fine
    label: "box " + str(w)
    tags: [
        "multi",
        "line",
    ]
print(box)
print(box.size.width * box.size.height)

step : 1
counter:                        # self-reference, as with struct(...)
  n: counter.n + step
  log: counter.log + [step]
print(counter)
