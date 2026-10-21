# error: 3:1: cannot reassign helper, which was loaded from another module
load("../compile/modules/util.star", "helper")
helper = 1
