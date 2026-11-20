# With contagious None (on here: the program has a reactive variable), a
# def that tests, compares or sorts values of a type parameter fails (gives
# None) if they are None: its annotation must say so, by the bound
# Contagious, or a call with values that may be None would seem not to be
# None.
def n_true(xs):
    n = 0
    for x in xs:
        if x:
            n += 1
    return n

def ranked(xs):
    return sorted(xs)

tick : 1
