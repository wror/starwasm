# A top-level use refers to the module's variable even before its
# assignment (GlobalReassign is off): not the builtin len.
print(len)
len = 1
