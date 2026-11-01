// Command protoc compiles .proto files to a binary FileDescriptorSet (what
// `protoc --include_imports --descriptor_set_out` writes), in pure Go, with
// github.com/bufbuild/protocompile. It builds the descriptor sets the proto
// tests use (tests/proto/*.binpb), so neither the tests nor this repository
// need protoc itself.
//
// Usage: go run ./tools/protoc -I tests/proto -o tests/proto/test.binpb a.proto b.proto
//
// (run from the repository root; this directory is its own Go module).
package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/bufbuild/protocompile"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"
)

func main() {
	include := flag.String("I", ".", "import path")
	out := flag.String("o", "", "output file (binary FileDescriptorSet)")
	flag.Parse()
	if *out == "" || flag.NArg() == 0 {
		fmt.Fprintln(os.Stderr, "usage: protoc -I dir -o out.binpb file.proto...")
		os.Exit(2)
	}
	comp := protocompile.Compiler{
		Resolver: protocompile.WithStandardImports(&protocompile.SourceResolver{ImportPaths: []string{*include}}),
	}
	files, err := comp.Compile(context.Background(), flag.Args()...)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	// Every file with its imports first, each once (--include_imports).
	set := &descriptorpb.FileDescriptorSet{}
	seen := map[string]bool{}
	var add func(fd protoreflect.FileDescriptor)
	add = func(fd protoreflect.FileDescriptor) {
		if seen[fd.Path()] {
			return
		}
		seen[fd.Path()] = true
		imports := fd.Imports()
		for i := 0; i < imports.Len(); i++ {
			add(imports.Get(i).FileDescriptor)
		}
		set.File = append(set.File, protodesc.ToFileDescriptorProto(fd))
	}
	for _, f := range files {
		add(f)
	}
	data, err := proto.MarshalOptions{Deterministic: true}.Marshal(set)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := os.WriteFile(*out, data, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
