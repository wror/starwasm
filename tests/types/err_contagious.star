# With contagious None (on here: the program has a reactive variable),
# comparing with None is an error, as the compiler has it: the comparison
# would be None whatever the value. ?? replaces a None.
def missing(d):
    if d["a"] == None:
        return 0
    return 1

def present(d):
    return d["a"] != None

tick : 1
