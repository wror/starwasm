# error: modules/reactive_bad_mod.star:3:1: reactive variables can only be defined in the main file, not in a loaded module
load("modules/reactive_bad_mod.star", "v")
print(v)
