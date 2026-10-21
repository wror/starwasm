# Parse the file named by argv[0] with starwasm's front end (lexer + parser)
# and nothing more; a syntax error fails with "file:line:col: msg", as the
# compiler reports it. tests/upstream/run.mjs uses this for
# syntax/testdata, whose chunks are only meant to be parsed.

load("../../compiler/parser.star", "parse_file")

parse_file(read_file(argv[0]), argv[0])
