# A struct block without a field `id` gets one: its previous id + 1 (1 the
# first time), so it counts the times the struct has been computed.
w : 2
box:
  width: w
  area: w * w
print("box", box.id, box.area)

# a field may still read the struct's previous value
acc:
  total: acc.total + w
print("acc", acc)

# an explicit id: the struct is exactly as written
fixed:
  id: 7
  w: w
print("fixed", fixed)
counted:
  id: counted.id + 10
  w: w
print("counted", counted)

# nested blocks get no id
outer:
  inner:
    w: w
print("outer", outer)
