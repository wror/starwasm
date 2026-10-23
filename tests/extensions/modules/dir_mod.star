# Loaded by tests/extensions/dir_scope.star: dir() at a loaded module's top level.
load("../../compile/modules/util.star", "helper")
print("dirmod", dir())
_private = 1
public = [dir()]

def fn():
    return dir()
