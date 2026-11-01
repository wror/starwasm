# error: reactive_err_lambda.star:3:31: lambda refers to reactive variable x
x : [3, 1, 2]
y : sorted(x, key = lambda v: x[0] - v)
