# tests/grpc_refire.sh's client: a Quote_call made from an incoming event
# (ask, a form) that also reads state (note, another form). Changing the
# state alone must not call Quote again: nothing new came in.
an ask:
    sku: "apple"

note: "none"

a Quote_call:
    sku: ask.sku
    note: note       # not the request's: it comes back in the reply

a quote:
    text: "Quote %d: %s %s (note: %s)" % (Quote_reply.Quote_call_id, Quote_reply.sku, Quote_reply.price, Quote_reply.note)
