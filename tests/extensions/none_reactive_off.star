# option:nocontagiousnone
# With --nocontagiousnone, a program with reactive variables has the usual
# None: an operation on it is an error (here, a failed update, rolled back).

qty : 2
total : qty * 3
print("total", total)
