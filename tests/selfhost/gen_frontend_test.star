# Run by starhost: builds a single-file program = lexer + parser + driver,
# with load() lines removed (the compiler does not support load yet).
#
#   bin/starhost tests/selfhost/gen_frontend_test.star out/frontend.star

def strip_loads(src):
    out = []
    for line in src.split("\n"):
        if not line.startswith("load("):
            out.append(line)
    return "\n".join(out)

write_file(argv[0], "\n".join([
    strip_loads(read_file("compiler/lexer.star")),
    strip_loads(read_file("compiler/parser.star")),
    read_file("tests/selfhost/frontend_driver.star"),
]))
