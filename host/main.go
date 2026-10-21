// Command starhost runs a Starlark program with the extensions the
// starwasm compiler needs: recursion and while loops enabled, plus
// host builtins for file I/O. It is the stage-0 bootstrap interpreter.
//
// Usage: starhost <file.star> [args...]
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

	"go.starlark.net/starlark"
	"go.starlark.net/starlarkstruct"
	"go.starlark.net/syntax"
)

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
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: starhost <file.star> [args...]")
		os.Exit(2)
	}
	argv := make([]starlark.Value, 0, len(os.Args)-2)
	for _, a := range os.Args[2:] {
		argv = append(argv, starlark.String(a))
	}
	predeclared := starlark.StringDict{
		"read_file":  starlark.NewBuiltin("read_file", readFile),
		"write_file": starlark.NewBuiltin("write_file", writeFile),
		"argv":       starlark.NewList(argv),
		// struct is not a core builtin; starlark-go provides it in a library.
		"struct": starlark.NewBuiltin("struct", starlarkstruct.Make),
	}
	opts := &syntax.FileOptions{
		Recursion:       true, // parsers and tree walkers need it
		While:           true,
		Set:             true,
		GlobalReassign:  true,
		TopLevelControl: true,
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
			g, err := starlark.ExecFileOptions(opts, t, path, nil, predeclared)
			e = &entry{g, err}
			cache[path] = e
		}
		return e.globals, e.err
	}
	thread := &starlark.Thread{
		Name:  os.Args[1],
		Load:  load,
		Print: func(_ *starlark.Thread, msg string) { fmt.Println(msg) },
	}
	if _, err := starlark.ExecFileOptions(opts, thread, os.Args[1], nil, predeclared); err != nil {
		if evalErr, ok := err.(*starlark.EvalError); ok {
			fmt.Fprintln(os.Stderr, evalErr.Backtrace())
		} else {
			fmt.Fprintln(os.Stderr, err)
		}
		os.Exit(1)
	}
}
