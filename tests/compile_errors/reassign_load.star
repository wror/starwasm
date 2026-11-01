# error: 3:1: cannot reassign local helper declared at tests/compile_errors/reassign_load.star:2:39
load("../compile/modules/util.star", "helper")
helper = 1
