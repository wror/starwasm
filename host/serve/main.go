// Command starserve serves a reactive program over HTTP
// (EXTENSIONS.md, "Serving reactive programs").
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
//	--descriptor_set=FILE  a binary FileDescriptorSet: the program's proto
//	                   module's (as host/run.mjs's), and the services for gRPC
//	--grpc=HOST:PORT   serve the methods the program answers over gRPC
//	                   (serve/grpc.star; EXTENSIONS.md, "gRPC")
//	--grpc_target=[SERVICE=]HOST:PORT  where to call SERVICE's methods
//	                   (without SERVICE: any service's); repeatable
//	--grpc_timeout=DURATION  how long a call, or a request's answer, may
//	                   take (default 30s)
//	--addr=none        serve no HTTP (gRPC only)
//	--globalreassign, --recursion, --contagiousnone, --nocontagiousnone,
//	--rollback         the compiler's
package main

import (
	"bufio"
	"fmt"
	"google.golang.org/grpc"
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

// isFile(path): is there a regular file at path?
func isFile(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var path string
	if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 1, &path); err != nil {
		return nil, err
	}
	fi, err := os.Stat(path)
	return starlark.Bool(err == nil && fi.Mode().IsRegular()), nil
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
	descriptorSet, grpcAddr := "", ""
	targets := map[string]string{}
	timeout := 30 * time.Second
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
		case strings.HasPrefix(a, "--descriptor_set="):
			descriptorSet = strings.TrimPrefix(a, "--descriptor_set=")
			run = append(run, starlark.String(a))
		case strings.HasPrefix(a, "--grpc="):
			grpcAddr = strings.TrimPrefix(a, "--grpc=")
		case strings.HasPrefix(a, "--grpc_target="):
			t := strings.TrimPrefix(a, "--grpc_target=")
			svc, addr, found := strings.Cut(t, "=")
			if !found {
				svc, addr = "", t
			}
			targets[svc] = addr
		case strings.HasPrefix(a, "--grpc_timeout="):
			d, err := time.ParseDuration(strings.TrimPrefix(a, "--grpc_timeout="))
			if err != nil {
				fmt.Fprintln(os.Stderr, "starserve:", err)
				os.Exit(2)
			}
			timeout = d
		case strings.HasPrefix(a, "--journal="), a == "--globalreassign", a == "--recursion",
			a == "--contagiousnone", a == "--nocontagiousnone", a == "--rollback":
			run = append(run, starlark.String(a))
		default:
			fmt.Fprintln(os.Stderr, "starserve: unknown option", a)
			os.Exit(2)
		}
	}
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: starserve [--addr=HOST:PORT|none] [--templates=DIR] [--journal=FILE] [--descriptor_set=FILE [--grpc=HOST:PORT] [--grpc_target=[SERVICE=]HOST:PORT]...] [compiler options] <program.star>")
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
		"is_file":    starlark.NewBuiltin("is_file", isFile),
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

	// gRPC: the methods of the descriptor set's services that the program
	// serves and calls (serve/grpc.star's plan)
	var g *grpcHost
	var extra []starlark.Value
	var grpcPlan starlark.Value
	if grpcAddr != "" || len(targets) > 0 {
		if descriptorSet == "" {
			die(fmt.Errorf("--grpc and --grpc_target need --descriptor_set=FILE, for the services"))
		}
		files, err := readPool(descriptorSet)
		if err != nil {
			die(err)
		}
		gmod, err := load(thread, "grpc.star")
		if err != nil {
			die(err)
		}
		g = &grpcHost{thread: thread, module: gmod, byName: map[string]*method{}, served: map[string]*method{}, waiting: map[string]chan answer{},
			conns: map[string]*grpc.ClientConn{}, targets: targets, timeout: timeout}
		var ms []starlark.Value
		all := map[string]*method{}
		for _, m := range methods(files) {
			all[m.path] = m
			d := starlark.NewDict(6)
			d.SetKey(starlark.String("name"), starlark.String(m.name))
			d.SetKey(starlark.String("path"), starlark.String(m.path))
			d.SetKey(starlark.String("service"), starlark.String(m.service))
			d.SetKey(starlark.String("streaming"), starlark.Bool(m.streaming))
			ms = append(ms, d)
		}
		tdict := starlark.NewDict(len(targets))
		for k, v := range targets {
			tdict.SetKey(starlark.String(k), starlark.String(v))
		}
		grpcPlan, err = g.call("plan", starlark.String(program), starlark.NewList(ms), tdict)
		if err != nil {
			die(err)
		}
		pd := grpcPlan.(*starlark.Dict)
		errs, _ := dictGet(pd, "errors")
		if es := listOf(errs); len(es) > 0 {
			for _, e := range es {
				s, _ := starlark.AsString(e)
				fmt.Fprintln(os.Stderr, "starserve: grpc:", s)
			}
			prog.stop()
			os.Exit(1)
		}
		for _, role := range []string{"served", "called"} {
			v, _ := dictGet(pd, role)
			for _, m := range listOf(v) {
				p, _ := dictGet(m.(*starlark.Dict), "path")
				ps, _ := starlark.AsString(p)
				g.byName[all[ps].name] = all[ps]
				if role == "served" {
					g.served[ps] = all[ps]
				}
			}
		}
		x, _ := dictGet(pd, "extra")
		extra = listOf(x)
		if grpcAddr != "" {
			served, _ := dictGet(pd, "served")
			if len(listOf(served)) == 0 {
				die(fmt.Errorf("--grpc: the program serves no method of the descriptor set's services (it would define <Method>_response)"))
			}
		}
	}

	// Listen before starting the program: an address in use is found at once.
	var listener, grpcListener net.Listener
	if addr != "none" {
		if listener, err = net.Listen("tcp", addr); err != nil {
			die(err)
		}
	}
	if grpcAddr != "" {
		if grpcListener, err = net.Listen("tcp", grpcAddr); err != nil {
			die(err)
		}
	}
	config := starlark.NewDict(5)
	config.SetKey(starlark.String("extra"), starlark.NewList(extra))
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
	if g != nil {
		g.server, g.mu = server, &mu
		if _, err := g.call("setup", server, grpcPlan); err != nil {
			die(err)
		}
		mu.Lock()
		g.after() // (calls the first run makes)
		mu.Unlock()
	}
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
		query := starlark.NewDict(0)
		for k, v := range r.URL.Query() {
			query.SetKey(starlark.String(k), starlark.String(v[0]))
		}
		req := starlark.NewDict(8)
		req.SetKey(starlark.String("method"), starlark.String(r.Method))
		req.SetKey(starlark.String("path"), starlark.String(r.URL.Path))
		req.SetKey(starlark.String("query"), query)
		req.SetKey(starlark.String("referer"), starlark.String(r.Referer()))
		req.SetKey(starlark.String("host"), starlark.String(r.Host))
		req.SetKey(starlark.String("form"), form)
		req.SetKey(starlark.String("time"), starlark.String(at))

		mu.Lock()
		res, err := starlark.Call(thread, globals["handle"], starlark.Tuple{server, req}, nil)
		if g != nil {
			g.after() // (a post may make calls, and answer requests)
		}
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
	if grpcListener != nil {
		gs := grpc.NewServer(grpc.UnknownServiceHandler(g.handle), grpc.ForceServerCodec(rawCodec{}))
		fmt.Fprintf(os.Stderr, "starserve: grpc://%s\n", grpcListener.Addr())
		if listener == nil {
			die(gs.Serve(grpcListener))
		}
		go func() { die(gs.Serve(grpcListener)) }()
	}
	if listener == nil {
		select {} // (--addr=none and no --grpc: just the calls)
	}
	fmt.Fprintf(os.Stderr, "starserve: http://%s/\n", listener.Addr())
	die(http.Serve(listener, http.HandlerFunc(handler)))
}
