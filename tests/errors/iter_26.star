l = [1]
def f():
    l.append(1)
for x in l:
    f()

# option:globalreassign (top-level control flow or rebinding above)
