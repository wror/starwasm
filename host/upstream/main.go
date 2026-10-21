// Command upstreamhost is the oracle for tests/upstream/: it runs one chunk
// of a starlark-go test file under starlark-go, with the test builtins that
// programs compiled with `compiler/main.star --test` get (see
// add_test_builtins in lib/builtins.star), printing the same reports.
//
// Usage: upstreamhost [-options=starwasm|file] [-mode=exec|resolve|parse] file.star
//
//	-options=starwasm  every dialect option on, as bin/starhost and the
//	                   compiler (default)
//	-options=file      only the options named in the file ("option:set"
//	                   etc.), as starlark-go's own tests run it
//	-mode=exec         run it (starlark/testdata, starlarkstruct/testdata)
//	-mode=resolve      parse and resolve only (resolve/testdata)
//	-mode=parse        parse only (syntax/testdata)
//
// Output: the program's prints on stdout; on stderr, one
// "@@test_error {json}" line per test_error() call, and a final error as a
// traceback (exec) or one "file:line:col: msg" line per error (static
// modes). Exit status 1 if there was a final error.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"go.starlark.net/resolve"
	"go.starlark.net/starlark"
	"go.starlark.net/starlarkstruct"
	"go.starlark.net/syntax"
)

func testCatch(thread *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var fn starlark.Callable
	if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 1, &fn); err != nil {
		return nil, err
	}
	if _, err := starlark.Call(thread, fn, nil, nil); err != nil {
		return starlark.String(err.Error()), nil
	}
	return starlark.None, nil
}

func testError(thread *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var msg starlark.Value
	if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 1, &msg); err != nil {
		return nil, err
	}
	text, ok := starlark.AsString(msg)
	if !ok {
		text = msg.String()
	}
	frames := []string{}
	for _, fr := range thread.CallStack() {
		if fr.Pos.Filename() == "<builtin>" {
			continue
		}
		frames = append(frames, fmt.Sprintf("%s:%d:%d", fr.Pos.Filename(), fr.Pos.Line, fr.Pos.Col))
	}
	line, _ := json.Marshal(map[string]any{"msg": text, "frames": frames})
	fmt.Fprintf(os.Stderr, "@@test_error %s\n", line)
	return starlark.None, nil
}

func testMatches(thread *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var pattern, str string
	if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 2, &pattern, &str); err != nil {
		return nil, err
	}
	ok, err := regexp.MatchString(pattern, str)
	if err != nil {
		return nil, fmt.Errorf("test_matches: %s", err)
	}
	return starlark.Bool(ok), nil
}

func testFreeze(thread *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var x starlark.Value
	if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 1, &x); err != nil {
		return nil, err
	}
	x.Freeze()
	return x, nil
}

func testFloateq(thread *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var xf, yf starlark.Float
	if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 2, &xf, &yf); err != nil {
		return nil, err
	}
	x, y := float64(xf), float64(yf)
	switch {
	case x == y:
		return starlark.True, nil
	case math.IsNaN(x):
		return starlark.Bool(math.IsNaN(y)), nil
	case math.IsNaN(y):
		return starlark.False, nil
	}
	a, c := math.Float64bits(x), math.Float64bits(y)
	return starlark.Bool(a == c+1 || c == a+1), nil
}

func main() {
	options := flag.String("options", "starwasm", "starwasm or file")
	mode := flag.String("mode", "exec", "exec, resolve or parse")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: upstreamhost [-options=starwasm|file] [-mode=exec|resolve|parse] file.star")
		os.Exit(2)
	}
	filename := flag.Arg(0)
	src, err := os.ReadFile(filename)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	opts := &syntax.FileOptions{Set: true, While: true, TopLevelControl: true, GlobalReassign: true, Recursion: true}
	if *options == "file" {
		has := func(name string) bool { return strings.Contains(string(src), "option:"+name) }
		opts = &syntax.FileOptions{
			Set:               has("set"),
			While:             has("while"),
			TopLevelControl:   has("toplevelcontrol"),
			GlobalReassign:    has("globalreassign"),
			LoadBindsGlobally: has("loadbindsglobally"),
			Recursion:         has("recursion"),
		}
		if *mode == "parse" {
			opts = syntax.LegacyFileOptions() // as syntax.Parse in TestParseErrors
		}
	}

	predeclared := starlark.StringDict{
		"struct":       starlark.NewBuiltin("struct", starlarkstruct.Make),
		"test_catch":   starlark.NewBuiltin("test_catch", testCatch),
		"test_error":   starlark.NewBuiltin("test_error", testError),
		"test_matches": starlark.NewBuiltin("test_matches", testMatches),
		"test_freeze":  starlark.NewBuiltin("test_freeze", testFreeze),
		"test_floateq": starlark.NewBuiltin("test_floateq", testFloateq),
	}

	staticErrors := func(err error) {
		if list, ok := err.(resolve.ErrorList); ok {
			for _, e := range list {
				fmt.Fprintf(os.Stderr, "%s: %s\n", e.Pos, e.Msg)
			}
		} else if e, ok := err.(syntax.Error); ok {
			fmt.Fprintf(os.Stderr, "%s: %s\n", e.Pos, e.Msg)
		} else {
			fmt.Fprintln(os.Stderr, err)
		}
		os.Exit(1)
	}

	switch *mode {
	case "parse":
		if _, err := opts.Parse(filename, src, 0); err != nil {
			staticErrors(err)
		}
		return
	case "resolve":
		f, err := opts.Parse(filename, src, 0)
		if err != nil {
			staticErrors(err)
		}
		isPredeclared := func(name string) bool { return predeclared.Has(name) }
		isUniversal := func(name string) bool { return starlark.Universe.Has(name) }
		if *options == "file" { // as resolve_test.go
			isPredeclared = func(name string) bool { return name == "M" }
			isUniversal = func(name string) bool { return name == "U" || name == "float" }
		}
		if err := resolve.File(f, isPredeclared, isUniversal); err != nil {
			staticErrors(err)
		}
		return
	}

	// load() resolves relative to the loading file, as in bin/starhost.
	type entry struct {
		globals starlark.StringDict
		err     error
	}
	cache := map[string]*entry{}
	var load func(*starlark.Thread, string) (starlark.StringDict, error)
	print := func(_ *starlark.Thread, msg string) { fmt.Println(msg) }
	load = func(from *starlark.Thread, module string) (starlark.StringDict, error) {
		path := filepath.Clean(filepath.Join(filepath.Dir(from.Name), module))
		e, ok := cache[path]
		if e == nil {
			if ok {
				return nil, fmt.Errorf("cycle in load graph at %s", module)
			}
			cache[path] = nil
			t := &starlark.Thread{Name: path, Load: load, Print: print}
			g, err := starlark.ExecFileOptions(opts, t, path, nil, predeclared)
			e = &entry{g, err}
			cache[path] = e
		}
		return e.globals, e.err
	}
	thread := &starlark.Thread{Name: filename, Load: load, Print: print}
	if _, err := starlark.ExecFileOptions(opts, thread, filename, src, predeclared); err != nil {
		if evalErr, ok := err.(*starlark.EvalError); ok {
			fmt.Fprintln(os.Stderr, evalErr.Backtrace())
		} else {
			staticErrors(err)
		}
		os.Exit(1)
	}
}
