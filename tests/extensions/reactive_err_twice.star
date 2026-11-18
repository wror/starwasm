# error: reactive_err_twice.star:3:1: reactive variable x defined twice
x : 1
x : 2
# skip:globalreassign (where reactive variables may be redefined: reactive_redefine.star)
