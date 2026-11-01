# More relations (`a name:` / `an name:` + a struct block).
deposit:
    account: "none"
    amount: 0

# self-reference in a relation: the member being replaced (the one with the
# triggering change's id), so this keeps a balance per id
an account:
    owner: deposit.account
    balance: account.balance + deposit.amount

# an explicit id: the member is exactly as written
a ledger_line:
    id: account.id * 100
    balance: account.balance

# a trigger without an id (an int): every change adds a member, with the
# next id after the largest
tick : 0
a tick_log:
    at: tick

# a lone variable computed from a relation is unset until the relation has
# a member: observers reading it are skipped until then
richest:
    owner: account.owner
    balance: account.balance
print("richest", richest)

# observers read a relation as its list of members
print("accounts", account)
print("ledger", [l.id for l in ledger_line])
print("ticks", tick_log)
