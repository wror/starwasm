# A dependency with a field <name>_id refers to a member of <name>: the
# definition of <name> matches on that field instead of the dependency's id.
deposit:
    account_id: 0
    amount: 0

# each deposit (its own id) updates the account it names (account_id)
an account:
    balance: account.balance + deposit.amount
    deposits: account.deposits + 1

# the field must be named after the definition: ledger matches on id, and
# its members carry report_id
a ledger:
    amount: deposit.amount
    report_id: 5

# a lone struct block reading a relation: its implicit id is the member's
# report_id
report:
    amount: ledger.amount

print("accounts", account)
print("ledger", ledger)
print("report", report)
