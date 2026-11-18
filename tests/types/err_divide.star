def average(xs):
    total = 0.0
    for x in xs:
        total += x
    return total / len(xs) + 1

# total would be both a number and maybe None: write
# total = (total / n) ?? 0.0, or divide into another variable
def divide_in_place(total, n):
    total /= n
    return total
