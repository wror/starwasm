# Protocol buffer schemas for the proto tests

The proto module (lib/proto.star; starlark-go's lib/proto in bin/starhost)
finds .proto files in a descriptor pool: a binary FileDescriptorSet, given
to bin/starhost and to the compiler as `--descriptor_set=FILE`.
tests/compile_one.sh passes `tests/proto/test.binpb` to both, for every
differential test.

- `p3.proto`: proto3 (implicit presence, `optional`, packed repeated
  fields, maps, oneofs, nested types, an open enum).
- `p2.proto`: proto2 (required fields, explicit defaults, a group,
  extensions at file and message scope, an enum alias).
- `editions.proto`: starlark-go's own starlark/testdata/proto/test.proto
  (edition 2023).
- `features.proto`: editions features (implicit presence by default,
  field-level overrides, expanded repeated fields, a closed enum, delimited
  encoding, LEGACY_REQUIRED).

`test.binpb` is checked in, so running the tests needs no protoc. After
changing a schema, regenerate it with the pure-Go compiler in tools/protoc
(github.com/bufbuild/protocompile):

    cd tools/protoc && go mod tidy && cd ../..   # once
    go run -C tools/protoc . -I ../../tests/proto -o ../../tests/proto/test.binpb \
        p3.proto editions.proto features.proto

(p2.proto comes in as an import of p3.proto; protoc
`--include_imports --descriptor_set_out` writes the same thing.)
