# error: undefined: provenance
# provenance() exists only with contagious None, which is off by default
# in a program without reactive variables.
print(provenance(None))
