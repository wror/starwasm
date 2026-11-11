# Errors in a loaded module are reported in it; so is a name it lacks.
load("modules/broken.star", "half", "thrd")

x = half(4)
y = half("four")
