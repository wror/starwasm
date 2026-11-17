// Command starserve serves a reactive program's relations over HTTP
// (EXTENSIONS.md, "Serving relations").
//
// Usage: starserve [--addr=HOST:PORT] [--templates=DIR] [--journal=FILE]
//
//	[compiler options] <program.star>
//
// It is net/http and little else: every request is answered by handle() in
// serve/serve.star, run here by starlark-go, which is where the routes, the
// forms and the templates are. This file gives that code its builtins:
// files, and the reactive program as a child process (node host/run.mjs)
// whose standard input it writes and whose output it reads.
//
// Options:
//
//	--addr=HOST:PORT   where to listen (default localhost:8080)
//	--templates=DIR    where the HTML templates are (default: next to the program)
//	--journal=FILE     host/run.mjs's: the program's input is kept in FILE,
//	                   and replayed when it starts again
//	--root=DIR         the starwasm checkout (default: the parent of this
//	                   binary's directory)
//	--now=TEXT         the time given to every request, instead of the clock's
//	--globalreassign, --recursion, --contagiousnone, --nocontagiousnone,
//	--rollback         the compiler's
package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"go.starlark.net/starlark"
	"go.starlark.net/syntax"
)

// child is the reactive program.
type child struct {
	cmd *exec.Cmd
	in  io.WriteCloser
	out *bufio.Reader
}

func (c *child) spawn(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var argv *starlark.List
	if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 1, &argv); err != nil {
		return nil, err
	}
	if c.cmd != nil {
		return nil, fmt.Errorf("spawn: the program is already running")
	}
	var words []string
	for i := 0; i < argv.Len(); i++ {
		s, ok := starlark.AsString(argv.Index(i))
		if !ok {
			return nil, fmt.Errorf("spawn: got %s, want a list of strings", argv.Index(i).Type())
		}
		words = append(words, s)
	}
	if len(words) == 0 {
		return nil, fmt.Errorf("spawn: empty command")
	}
	cmd := exec.Command(words[0], words[1:]...)
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = cmd.Stdout // one pipe, so that errors come in order with the output
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	c.cmd, c.in, c.out = cmd, in, bufio.NewReader(out)
	return starlark.None, nil
}

func (c *child) send(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var line string
	if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 1, &line); err != nil {
		return nil, err
	}
	if c.cmd == nil || strings.Contains(line, "\n") {
		return nil, fmt.Errorf("send: want one line, for a running program")
	}
	if _, err := io.WriteString(c.in, line+"\n"); err != nil {
		return nil, fmt.Errorf("send: %v", err)
	}
	return starlark.None, nil
}

func (c *child) recv(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 0); err != nil {
		return nil, err
	}
	if c.cmd == nil {
		return nil, fmt.Errorf("recv: no program is running")
	}
	line, err := c.out.ReadString('\n')
	if err != nil && line == "" {
		return starlark.None, nil
	}
	return starlark.String(strings.TrimRight(line, "\r\n")), nil
}

// stop ends the program by ending its input, as it ends normally.
func (c *child) stop() {
	if c.cmd == nil {
		return
	}
	c.in.Close()
	done := make(chan struct{})
	go func() { c.cmd.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		c.cmd.Process.Kill()
	}
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
	var path, data string
	if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 2, &path, &data); err != nil {
		return nil, err
	}
	return starlark.None, os.WriteFile(path, []byte(data), 0o644)
}

func message(err error) string {
	if e, ok := err.(*starlark.EvalError); ok {
		return e.Backtrace()
	}
	return err.Error()
}

func main() {
	addr := "localhost:8080"
	templates, root, now := "", "", ""
	run := []starlark.Value{}
	args := os.Args[1:]
	for ; len(args) > 0 && strings.HasPrefix(args[0], "--"); args = args[1:] {
		a := args[0]
		switch {
		case strings.HasPrefix(a, "--addr="):
			addr = strings.TrimPrefix(a, "--addr=")
		case strings.HasPrefix(a, "--templates="):
			templates = strings.TrimPrefix(a, "--templates=")
		case strings.HasPrefix(a, "--root="):
			root = strings.TrimPrefix(a, "--root=")
		case strings.HasPrefix(a, "--now="):
			now = strings.TrimPrefix(a, "--now=")
		case strings.HasPrefix(a, "--journal="), a == "--globalreassign", a == "--recursion",
			a == "--contagiousnone", a == "--nocontagiousnone", a == "--rollback":
			run = append(run, starlark.String(a))
		default:
			fmt.Fprintln(os.Stderr, "starserve: unknown option", a)
			os.Exit(2)
		}
	}
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: starserve [--addr=HOST:PORT] [--templates=DIR] [--journal=FILE] [compiler options] <program.star>")
		os.Exit(2)
	}
	program := args[0]
	if templates == "" {
		templates = filepath.Dir(program)
	}
	if root == "" {
		exe, err := os.Executable()
		if err != nil {
			fmt.Fprintln(os.Stderr, "starserve:", err)
			os.Exit(2)
		}
		root = filepath.Dir(filepath.Dir(exe))
	}

	// serve/serve.star, as bin/starhost --recursion would run it (it loads
	// the compiler's parser, which is recursive).
	prog := &child{}
	predeclared := starlark.StringDict{
		"read_file":  starlark.NewBuiltin("read_file", readFile),
		"write_file": starlark.NewBuiltin("write_file", writeFile),
		"spawn":      starlark.NewBuiltin("spawn", prog.spawn),
		"send":       starlark.NewBuiltin("send", prog.send),
		"recv":       starlark.NewBuiltin("recv", prog.recv),
	}
	opts := &syntax.FileOptions{Recursion: true, Set: true}
	print := func(_ *starlark.Thread, msg string) { fmt.Println(msg) }
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
			cache[path] = nil
			t := &starlark.Thread{Name: path, Load: load, Print: print}
			g, err := starlark.ExecFileOptions(opts, t, path, nil, predeclared)
			e = &entry{g, err}
			cache[path] = e
		}
		return e.globals, e.err
	}
	main := filepath.Join(root, "serve", "serve.star")
	thread := &starlark.Thread{Name: main, Load: load, Print: print}
	die := func(err error) {
		fmt.Fprintln(os.Stderr, "starserve:", message(err))
		prog.stop()
		os.Exit(1)
	}
	globals, err := starlark.ExecFileOptions(opts, thread, main, nil, predeclared)
	if err != nil {
		die(err)
	}

	// Listen before starting the program: an address in use is found at once.
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		die(err)
	}
	config := starlark.NewDict(4)
	config.SetKey(starlark.String("id"), starlark.String(fmt.Sprintf("%x", time.Now().UnixNano())))
	config.SetKey(starlark.String("program"), starlark.String(program))
	config.SetKey(starlark.String("templates"), starlark.String(templates))
	config.SetKey(starlark.String("run"), starlark.NewList(append([]starlark.Value{
		starlark.String("node"), starlark.String(filepath.Join(root, "host", "run.mjs")),
	}, run...)))
	server, err := starlark.Call(thread, globals["start"], starlark.Tuple{config}, nil)
	if err != nil {
		die(err)
	}

	var mu sync.Mutex // the program takes one update at a time
	handler := func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
		if err := r.ParseForm(); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		form := starlark.NewDict(len(r.PostForm))
		for k, v := range r.PostForm {
			form.SetKey(starlark.String(k), starlark.String(v[0]))
		}
		at := now
		if at == "" {
			at = time.Now().UTC().Format(time.RFC3339)
		}
		req := starlark.NewDict(4)
		req.SetKey(starlark.String("method"), starlark.String(r.Method))
		req.SetKey(starlark.String("path"), starlark.String(r.URL.Path))
		req.SetKey(starlark.String("form"), form)
		req.SetKey(starlark.String("time"), starlark.String(at))

		mu.Lock()
		res, err := starlark.Call(thread, globals["handle"], starlark.Tuple{server, req}, nil)
		mu.Unlock()
		if err != nil {
			fmt.Fprintln(os.Stderr, message(err))
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		var status int
		var headers *starlark.Dict
		var body string
		if err := starlark.UnpackPositionalArgs("handle's result", res.(starlark.Tuple), nil, 3, &status, &headers, &body); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		for _, item := range headers.Items() {
			k, _ := starlark.AsString(item[0])
			v, _ := starlark.AsString(item[1])
			w.Header().Set(k, v)
		}
		w.WriteHeader(status)
		io.WriteString(w, body)
	}

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-signals
		mu.Lock() // not in the middle of an update
		prog.stop()
		os.Exit(0)
	}()
	fmt.Fprintf(os.Stderr, "starserve: http://%s/\n", listener.Addr())
	die(http.Serve(listener, http.HandlerFunc(handler)))
}
