// Command starhost runs a Starlark program with host builtins for file
// I/O. It is the stage-0 bootstrap interpreter, and the reference the
// differential tests compare compiled programs with.
//
// Usage: starhost [--globalreassign] [--recursion] [--descriptor_set=FILE] <file.star> [args...]
//
// The dialect is starlark-go's default, as the compiler's: no reassigning
// top-level names, no while loops, no if/for at top level, unless
// --globalreassign (starlark-go's AllowGlobalReassign); no recursion unless
// --recursion. The compiler itself needs --recursion.
//
// The predeclared proto module is starlark-go's lib/proto; its descriptor
// pool holds the files of the binary FileDescriptorSet FILE (what
// `protoc --include_imports --descriptor_set_out` writes), or none.
//
// Host builtins (the only "external" functions the compiler may use):
//
//	read_file(path) -> string
//	write_file(path, data)   data: bytes, or list of ints 0..255
//	argv                     list of extra command-line args
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"strings"

	starlarkproto "go.starlark.net/lib/proto"
	"go.starlark.net/starlark"
	"go.starlark.net/starlarkstruct"
	"go.starlark.net/syntax"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"
)

// descriptorPool reads a binary FileDescriptorSet (no file: an empty pool).
func descriptorPool(file string) (*protoregistry.Files, error) {
	if file == "" {
		return new(protoregistry.Files), nil
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	set := new(descriptorpb.FileDescriptorSet)
	if err := proto.Unmarshal(data, set); err != nil {
		return nil, fmt.Errorf("%s: %v", file, err)
	}
	return protodesc.NewFiles(set)
}

func readFile(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var path string
	if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 1, &path); err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return starlark.String(data), nil
}

func writeFile(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var path string
	var data starlark.Value
	if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 2, &path, &data); err != nil {
		return nil, err
	}
	var out []byte
	switch d := data.(type) {
	case starlark.Bytes:
		out = []byte(d)
	case starlark.String:
		out = []byte(d)
	case *starlark.List:
		out = make([]byte, d.Len())
		for i := 0; i < d.Len(); i++ {
			n, err := starlark.AsInt32(d.Index(i))
			if err != nil || n < 0 || n > 255 {
				return nil, fmt.Errorf("write_file: element %d is not a byte: %v", i, d.Index(i))
			}
			out[i] = byte(n)
		}
	default:
		return nil, fmt.Errorf("write_file: want bytes, string or list of ints, got %s", data.Type())
	}
	return starlark.None, os.WriteFile(path, out, 0o644)
}

func main() {
	args := os.Args[1:]
	fds := ""
	reassign := false  // starlark-go's AllowGlobalReassign (off by default, as there)
	recursion := false // starlark-go's Recursion (off by default, as there)
	for len(args) > 0 {
		if strings.HasPrefix(args[0], "--descriptor_set=") {
			fds = strings.TrimPrefix(args[0], "--descriptor_set=")
		} else if args[0] == "--globalreassign" {
			reassign = true
		} else if args[0] == "--recursion" {
			recursion = true
		} else {
			break
		}
		args = args[1:]
	}
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "usage: starhost [--globalreassign] [--recursion] [--descriptor_set=FILE] <file.star> [args...]")
		os.Exit(2)
	}
	pool, err := descriptorPool(fds)
	if err != nil {
		fmt.Fprintln(os.Stderr, "starhost:", err)
		os.Exit(2)
	}
	argv := make([]starlark.Value, 0, len(args)-1)
	for _, a := range args[1:] {
		argv = append(argv, starlark.String(a))
	}
	predeclared := starlark.StringDict{
		"read_file":  starlark.NewBuiltin("read_file", readFile),
		"write_file": starlark.NewBuiltin("write_file", writeFile),
		"argv":       starlark.NewList(argv),
		// struct is not a core builtin; starlark-go provides it in a library.
		"struct": starlark.NewBuiltin("struct", starlarkstruct.Make),
		// proto: starlark-go's lib/proto (not a core builtin either)
		"proto": starlarkproto.Module,
	}
	opts := &syntax.FileOptions{
		// as starlark-go's defaults (cmd/starlark: -globalreassign controls
		// the first three; set is standard), and the compiler's flags
		GlobalReassign:  reassign,
		While:           reassign,
		TopLevelControl: reassign,
		Recursion:       recursion,
		Set:             true,
	}
	// load("x.star", ...) resolves relative to the directory of the file
	// doing the loading (thread.Name holds that file's path). Each module
	// is executed once and cached.
	type entry struct {
		globals starlark.StringDict
		err     error
	}
	cache := map[string]*entry{}
	var load func(*starlark.Thread, string) (starlark.StringDict, error)
	load = func(from *starlark.Thread, module string) (starlark.StringDict, error) {
		path := filepath.Clean(filepath.Join(filepath.Dir(from.Name), module))
		e, ok := cache[path]
		if e == nil {
			if ok {
				return nil, fmt.Errorf("cycle in load graph at %s", module)
			}
			cache[path] = nil // mark in progress
			t := &starlark.Thread{Name: path, Load: load,
				Print: func(_ *starlark.Thread, msg string) { fmt.Println(msg) }}
			starlarkproto.SetPool(t, pool)
			g, err := starlark.ExecFileOptions(opts, t, path, nil, predeclared)
			e = &entry{g, err}
			cache[path] = e
		}
		return e.globals, e.err
	}
	thread := &starlark.Thread{
		Name:  args[0],
		Load:  load,
		Print: func(_ *starlark.Thread, msg string) { fmt.Println(msg) },
	}
	starlarkproto.SetPool(thread, pool)
	if _, err := starlark.ExecFileOptions(opts, thread, args[0], nil, predeclared); err != nil {
		msg := err.Error()
		if evalErr, ok := err.(*starlark.EvalError); ok {
			msg = evalErr.Backtrace()
		}
		// protobuf-go's error messages start "proto: " or, depending on a
		// hash of the binary, "proto:\u00a0" (to discourage comparing them):
		// normalized, so that tests don't depend on how starhost was built
		fmt.Fprintln(os.Stderr, strings.ReplaceAll(msg, "proto:\u00a0", "proto: "))
		os.Exit(1)
	}
}
