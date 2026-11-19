# Without a field <name>_id, a dependency and the relation it updates
# match on a field ending in "id" that both have (the latest
# alphabetically: here customer_id over account_id), and only failing
# that on id.
payment:
    account_id: 0
    customer_id: 0
    amount: 0

# each payment updates the balance with its customer_id, not its id
a balance:
    account_id: payment.account_id
    customer_id: payment.customer_id
    total: balance.total + payment.amount

# keyed read: the latest payment for the balance's customer_id
a receipt:
    customer_id: balance.customer_id
    last: payment.amount
    total: balance.total

# no field ending in "id" in common: matches on id
a note:
    amount: payment.amount

print("balances", balance)
print("receipts", receipt)
print("notes", note)
