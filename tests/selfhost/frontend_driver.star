# Appended to compiler/lexer.star + compiler/parser.star by
# tests/selfhost/gen_frontend_test.star. Lexes and parses the file named by
# argv[0] and prints a full, deterministic dump of the tokens and AST, so
# the interpreted and compiled front ends can be compared.

SRC_NAME = argv[0]
SRC = read_file(SRC_NAME)

def dump(x):
    t = type(x)
    if t == "dict":
        parts = []
        for k in x.keys():
            parts.append(k + "=" + dump(x[k]))
        return "{" + " ".join(parts) + "}"
    if t == "list" or t == "tuple":
        parts = []
        for e in x:
            parts.append(dump(e))
        return "[" + " ".join(parts) + "]"
    return repr(x)

def count_nodes(x):
    t = type(x)
    if t == "dict":
        n = 1 if "kind" in x else 0
        for k in x.keys():
            n += count_nodes(x[k])
        return n
    if t == "list" or t == "tuple":
        n = 0
        for e in x:
            n += count_nodes(e)
        return n
    return 0

toks = lex(SRC, SRC_NAME)
kinds = {}
for t in toks:
    kinds[t["kind"]] = kinds.get(t["kind"], 0) + 1
print("tokens:", len(toks))
print("kinds:", kinds)

stmts = parse_file(SRC, SRC_NAME)
print("statements:", len(stmts), "nodes:", count_nodes(stmts))
defs = [s["name"] for s in stmts if s["kind"] == "def"]
print("defs:", len(defs), defs)
for s in stmts:
    print(dump(s))
