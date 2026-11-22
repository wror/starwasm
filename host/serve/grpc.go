// gRPC for starserve (EXTENSIONS.md, "gRPC"): the transport, with grpc-go,
// and the conversion of messages to the program's values and back. What
// the program serves and calls, and how requests and answers become its
// input and output, is serve/grpc.star's.
//
// Messages are not compiled in: they are dynamic (dynamicpb), from the
// descriptor set, and travel as bytes (rawCodec).
package main

import (
	"context"
	"fmt"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"go.starlark.net/starlark"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/dynamicpb"
)

// rawCodec passes messages through as bytes: they are encoded and decoded
// here, from the descriptor set.
type rawCodec struct{}

func (rawCodec) Marshal(v any) ([]byte, error) {
	if b, ok := v.(*[]byte); ok {
		return *b, nil
	}
	return nil, fmt.Errorf("rawCodec: can't marshal %T", v)
}

func (rawCodec) Unmarshal(data []byte, v any) error {
	if b, ok := v.(*[]byte); ok {
		*b = append([]byte(nil), data...)
		return nil
	}
	return fmt.Errorf("rawCodec: can't unmarshal into %T", v)
}

func (rawCodec) Name() string { return "proto" }

// method is a method of a service in the descriptor set.
type method struct {
	name, path, service string
	input, output       protoreflect.MessageDescriptor
	streaming           bool
}

func methods(files *protoregistry.Files) []*method {
	var out []*method
	files.RangeFiles(func(fd protoreflect.FileDescriptor) bool {
		for i := 0; i < fd.Services().Len(); i++ {
			sd := fd.Services().Get(i)
			for j := 0; j < sd.Methods().Len(); j++ {
				md := sd.Methods().Get(j)
				out = append(out, &method{
					name:      string(md.Name()),
					path:      "/" + string(sd.FullName()) + "/" + string(md.Name()),
					service:   string(sd.FullName()),
					input:     md.Input(),
					output:    md.Output(),
					streaming: md.IsStreamingClient() || md.IsStreamingServer(),
				})
			}
		}
		return true
	})
	sort.Slice(out, func(i, j int) bool { return out[i].path < out[j].path })
	return out
}

// ---- messages as the program's values

// fields is a message as the fields of a struct: [(name, source)], each
// value written as the program's standard input reads it. Every field is
// there but a message that isn't set and the members of a oneof that
// aren't; a field id that is 0 (unset) is left out too, so that a
// relation gives the member a new id (top: the message is a request's or
// reply's, not one inside it).
func fields(m protoreflect.Message, top bool) starlark.Tuple {
	var out starlark.Tuple
	fds := m.Descriptor().Fields()
	for i := 0; i < fds.Len(); i++ {
		fd := fds.Get(i)
		if (fd.Kind() == protoreflect.MessageKind || fd.Kind() == protoreflect.GroupKind || fd.ContainingOneof() != nil) &&
			!fd.IsList() && !fd.IsMap() && !m.Has(fd) {
			continue
		}
		if top && fd.Name() == "id" && !m.Has(fd) {
			continue
		}
		out = append(out, starlark.Tuple{starlark.String(fd.Name()), starlark.String(source(fd, m.Get(fd)))})
	}
	return out
}

func structSource(m protoreflect.Message) string {
	var parts []string
	for _, f := range fields(m, false) {
		t := f.(starlark.Tuple)
		parts = append(parts, fmt.Sprintf("%s = %s", t[0].(starlark.String).GoString(), t[1].(starlark.String).GoString()))
	}
	return "struct(" + strings.Join(parts, ", ") + ")"
}

func source(fd protoreflect.FieldDescriptor, v protoreflect.Value) string {
	if fd.IsList() {
		l := v.List()
		parts := make([]string, l.Len())
		for i := range parts {
			parts[i] = source1(fd, l.Get(i))
		}
		return "[" + strings.Join(parts, ", ") + "]"
	}
	if fd.IsMap() {
		// a list of struct(key, value), by key: the input has no dicts
		type entry struct{ k, v string }
		var es []entry
		v.Map().Range(func(k protoreflect.MapKey, x protoreflect.Value) bool {
			es = append(es, entry{source1(fd.MapKey(), k.Value()), source1(fd.MapValue(), x)})
			return true
		})
		sort.Slice(es, func(i, j int) bool { return es[i].k < es[j].k })
		parts := make([]string, len(es))
		for i, e := range es {
			parts[i] = "struct(key = " + e.k + ", value = " + e.v + ")"
		}
		return "[" + strings.Join(parts, ", ") + "]"
	}
	return source1(fd, v)
}

func source1(fd protoreflect.FieldDescriptor, v protoreflect.Value) string {
	switch fd.Kind() {
	case protoreflect.BoolKind:
		if v.Bool() {
			return "True"
		}
		return "False"
	case protoreflect.Int32Kind, protoreflect.Sint32Kind, protoreflect.Sfixed32Kind,
		protoreflect.Int64Kind, protoreflect.Sint64Kind, protoreflect.Sfixed64Kind:
		return strconv.FormatInt(v.Int(), 10)
	case protoreflect.Uint32Kind, protoreflect.Fixed32Kind, protoreflect.Uint64Kind, protoreflect.Fixed64Kind:
		return strconv.FormatUint(v.Uint(), 10)
	case protoreflect.FloatKind, protoreflect.DoubleKind:
		f := v.Float()
		if math.IsInf(f, 0) || math.IsNaN(f) {
			return "None" // (the input has no infinities)
		}
		s := strconv.FormatFloat(f, 'g', -1, 64)
		if !strings.ContainsAny(s, ".eEn") {
			s += ".0"
		}
		return s
	case protoreflect.StringKind:
		return strconv.Quote(v.String())
	case protoreflect.BytesKind:
		return strconv.Quote(string(v.Bytes())) // (a string: the input has no bytes)
	case protoreflect.EnumKind:
		if ev := fd.Enum().Values().ByNumber(v.Enum()); ev != nil {
			return strconv.Quote(string(ev.Name()))
		}
		return strconv.FormatInt(int64(v.Enum()), 10)
	case protoreflect.MessageKind, protoreflect.GroupKind:
		return structSource(v.Message())
	}
	return "None"
}

// message is a value of the program (as serve.star reads one: a struct is
// a dict) as a message of type desc: the struct's fields named like the
// message's; others (its id, references) are left out, and so are None.
func toMessage(desc protoreflect.MessageDescriptor, v starlark.Value) (*dynamicpb.Message, error) {
	m := dynamicpb.NewMessage(desc)
	d, ok := v.(*starlark.Dict)
	if !ok {
		if s, ok := v.(starlark.String); ok {
			return nil, fmt.Errorf("%s: not made of literals and structs: %s", desc.FullName(), s.GoString())
		}
		return nil, fmt.Errorf("%s: want a struct, got %s", desc.FullName(), v.Type())
	}
	for _, item := range d.Items() {
		name, _ := starlark.AsString(item[0])
		fd := desc.Fields().ByName(protoreflect.Name(name))
		if fd == nil || item[1] == starlark.None {
			continue
		}
		if err := setField(m, fd, item[1]); err != nil {
			return nil, fmt.Errorf("%s.%s: %v", desc.FullName(), name, err)
		}
	}
	return m, nil
}

func elements(v starlark.Value) ([]starlark.Value, bool) {
	it, ok := v.(starlark.Iterable)
	if !ok {
		return nil, false
	}
	if _, isDict := v.(*starlark.Dict); isDict {
		return nil, false
	}
	var out []starlark.Value
	iter := it.Iterate()
	defer iter.Done()
	var x starlark.Value
	for iter.Next(&x) {
		out = append(out, x)
	}
	return out, true
}

func setField(m *dynamicpb.Message, fd protoreflect.FieldDescriptor, v starlark.Value) error {
	if fd.IsMap() {
		mp := m.Mutable(fd).Map()
		add := func(k, x starlark.Value) error {
			kv, err := value(fd.MapKey(), k)
			if err != nil {
				return fmt.Errorf("key: %v", err)
			}
			xv, err := value(fd.MapValue(), x)
			if err != nil {
				return fmt.Errorf("value: %v", err)
			}
			mp.Set(kv.MapKey(), xv)
			return nil
		}
		if d, ok := v.(*starlark.Dict); ok {
			for _, item := range d.Items() {
				if err := add(item[0], item[1]); err != nil {
					return err
				}
			}
			return nil
		}
		es, ok := elements(v)
		if !ok {
			return fmt.Errorf("want a dict or a list of struct(key, value), got %s", v.Type())
		}
		for _, e := range es {
			d, ok := e.(*starlark.Dict)
			k, kok := dictGet(d, "key")
			x, xok := dictGet(d, "value")
			if !ok || !kok || !xok {
				return fmt.Errorf("want struct(key = ..., value = ...), got %s", e.String())
			}
			if err := add(k, x); err != nil {
				return err
			}
		}
		return nil
	}
	if fd.IsList() {
		es, ok := elements(v)
		if !ok {
			return fmt.Errorf("want a list, got %s", v.Type())
		}
		l := m.Mutable(fd).List()
		for i, e := range es {
			x, err := value(fd, e)
			if err != nil {
				return fmt.Errorf("[%d]: %v", i, err)
			}
			l.Append(x)
		}
		return nil
	}
	x, err := value(fd, v)
	if err != nil {
		return err
	}
	m.Set(fd, x)
	return nil
}

func dictGet(d *starlark.Dict, k string) (starlark.Value, bool) {
	if d == nil {
		return nil, false
	}
	v, found, _ := d.Get(starlark.String(k))
	return v, found
}

// value is v as one value of field fd.
func value(fd protoreflect.FieldDescriptor, v starlark.Value) (protoreflect.Value, error) {
	bad := func() (protoreflect.Value, error) {
		return protoreflect.Value{}, fmt.Errorf("want %s, got %s", fd.Kind(), v.Type())
	}
	switch fd.Kind() {
	case protoreflect.BoolKind:
		b, ok := v.(starlark.Bool)
		if !ok {
			return bad()
		}
		return protoreflect.ValueOfBool(bool(b)), nil
	case protoreflect.Int32Kind, protoreflect.Sint32Kind, protoreflect.Sfixed32Kind:
		i, ok := v.(starlark.Int)
		n, exact := i.Int64()
		if !ok || !exact || n < math.MinInt32 || n > math.MaxInt32 {
			return bad()
		}
		return protoreflect.ValueOfInt32(int32(n)), nil
	case protoreflect.Int64Kind, protoreflect.Sint64Kind, protoreflect.Sfixed64Kind:
		i, ok := v.(starlark.Int)
		n, exact := i.Int64()
		if !ok || !exact {
			return bad()
		}
		return protoreflect.ValueOfInt64(n), nil
	case protoreflect.Uint32Kind, protoreflect.Fixed32Kind:
		i, ok := v.(starlark.Int)
		n, exact := i.Uint64()
		if !ok || !exact || n > math.MaxUint32 {
			return bad()
		}
		return protoreflect.ValueOfUint32(uint32(n)), nil
	case protoreflect.Uint64Kind, protoreflect.Fixed64Kind:
		i, ok := v.(starlark.Int)
		n, exact := i.Uint64()
		if !ok || !exact {
			return bad()
		}
		return protoreflect.ValueOfUint64(n), nil
	case protoreflect.FloatKind, protoreflect.DoubleKind:
		f, ok := starlark.AsFloat(v)
		if !ok {
			return bad()
		}
		if fd.Kind() == protoreflect.FloatKind {
			return protoreflect.ValueOfFloat32(float32(f)), nil
		}
		return protoreflect.ValueOfFloat64(f), nil
	case protoreflect.StringKind:
		s, ok := starlark.AsString(v)
		if !ok {
			return bad()
		}
		return protoreflect.ValueOfString(s), nil
	case protoreflect.BytesKind:
		s, ok := starlark.AsString(v)
		if !ok {
			return bad()
		}
		return protoreflect.ValueOfBytes([]byte(s)), nil
	case protoreflect.EnumKind:
		if s, ok := starlark.AsString(v); ok {
			ev := fd.Enum().Values().ByName(protoreflect.Name(s))
			if ev == nil {
				return protoreflect.Value{}, fmt.Errorf("no value %s in enum %s", s, fd.Enum().FullName())
			}
			return protoreflect.ValueOfEnum(ev.Number()), nil
		}
		i, ok := v.(starlark.Int)
		n, exact := i.Int64()
		if !ok || !exact || n < math.MinInt32 || n > math.MaxInt32 {
			return bad()
		}
		return protoreflect.ValueOfEnum(protoreflect.EnumNumber(n)), nil
	case protoreflect.MessageKind, protoreflect.GroupKind:
		m, err := toMessage(fd.Message(), v)
		if err != nil {
			return protoreflect.Value{}, err
		}
		return protoreflect.ValueOfMessage(m), nil
	}
	return bad()
}

// ---- the server and the client

type answer struct {
	data []byte
	err  error
}

// grpcHost runs serve/grpc.star's side: it is called under the lock
// (*mu) that serves the program one update at a time.
type grpcHost struct {
	thread  *starlark.Thread
	module  starlark.StringDict
	server  starlark.Value // serve.star's state
	mu      *sync.Mutex
	byName  map[string]*method // the methods served and called, by name
	served  map[string]*method // the methods served, by path
	waiting map[string]chan answer
	conns   map[string]*grpc.ClientConn
	targets map[string]string // service ("" for any) -> address
	timeout time.Duration
}

func (g *grpcHost) call(fn string, args ...starlark.Value) (starlark.Value, error) {
	return starlark.Call(g.thread, g.module[fn], starlark.Tuple(args), nil)
}

func waitKey(name string, id starlark.Value) string { return name + "\x00" + id.String() }

// codeName is c as gRPC's documents write it: DEADLINE_EXCEEDED.
func codeName(c codes.Code) string {
	var b strings.Builder
	prev := ' '
	for _, r := range c.String() {
		if r >= 'A' && r <= 'Z' && prev >= 'a' && prev <= 'z' {
			b.WriteByte('_')
		}
		b.WriteRune(r)
		prev = r
	}
	return strings.ToUpper(b.String())
}

func codeOf(name string) codes.Code {
	for c := codes.OK; c <= codes.Unauthenticated; c++ {
		if strings.EqualFold(strings.ReplaceAll(c.String(), "_", ""), strings.ReplaceAll(name, "_", "")) {
			return c
		}
	}
	return codes.Unknown
}

// after delivers what the updates since the last look did (serve/grpc.star's
// after): answers to the requests waiting, and new calls, which it starts.
// Under the lock.
func (g *grpcHost) after() {
	res, err := g.call("after", g.server)
	if err != nil {
		fmt.Fprintln(os.Stderr, "starserve: grpc:", message(err))
		return
	}
	d := res.(*starlark.Dict)
	ready, _ := dictGet(d, "ready")
	for _, r := range listOf(ready) {
		t := r.(starlark.Tuple)
		name, _ := starlark.AsString(t[0])
		ch := g.waiting[waitKey(name, t[1])]
		if ch == nil {
			continue
		}
		delete(g.waiting, waitKey(name, t[1]))
		var a answer
		if e, ok := t[3].(starlark.Tuple); ok {
			c, _ := starlark.AsString(e[0])
			msg, _ := starlark.AsString(e[1])
			a.err = status.Error(codeOf(c), msg)
		} else if m, err := toMessage(g.byName[name].output, t[2]); err != nil {
			a.err = status.Error(codes.Internal, err.Error())
		} else if a.data, err = proto.Marshal(m); err != nil {
			a.err = status.Error(codes.Internal, err.Error())
		}
		ch <- a
	}
	calls, _ := dictGet(d, "calls")
	for _, c := range listOf(calls) {
		t := c.(starlark.Tuple)
		name, _ := starlark.AsString(t[0])
		go g.invoke(g.byName[name], t[1], t[2])
	}
}

func listOf(v starlark.Value) []starlark.Value {
	es, _ := elements(v)
	return es
}

// invoke makes a call of m (id: the call's id in the program; v: its
// value) and gives the program the answer.
func (g *grpcHost) invoke(m *method, id, v starlark.Value) {
	var fieldsOut starlark.Value = starlark.Tuple{}
	var failure starlark.Value = starlark.None
	fail := func(err error) {
		s := status.Convert(err)
		failure = starlark.Tuple{starlark.String(codeName(s.Code())), starlark.String(s.Message())}
	}
	if req, err := toMessage(m.input, v); err != nil {
		fail(status.Error(codes.InvalidArgument, err.Error()))
	} else if data, err := proto.Marshal(req); err != nil {
		fail(status.Error(codes.InvalidArgument, err.Error()))
	} else if conn, err := g.conn(m.service); err != nil {
		fail(status.Error(codes.Unavailable, err.Error()))
	} else {
		ctx, cancel := context.WithTimeout(context.Background(), g.timeout)
		var out []byte
		err := conn.Invoke(ctx, m.path, &data, &out, grpc.ForceCodec(rawCodec{}))
		cancel()
		if err != nil {
			fail(err)
		} else {
			reply := dynamicpb.NewMessage(m.output)
			if err := proto.Unmarshal(out, reply); err != nil {
				fail(status.Error(codes.Internal, err.Error()))
			} else {
				fieldsOut = fields(reply, true)
			}
		}
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if _, err := g.call("reply", g.server, starlark.String(m.name), id, starlark.NewList(tupleItems(fieldsOut)), failure, v); err != nil {
		fmt.Fprintln(os.Stderr, "starserve: grpc:", message(err))
	}
	g.after()
}

func tupleItems(v starlark.Value) []starlark.Value {
	t, _ := v.(starlark.Tuple)
	return []starlark.Value(t)
}

func (g *grpcHost) conn(service string) (*grpc.ClientConn, error) {
	addr, ok := g.targets[service]
	if !ok {
		addr = g.targets[""]
	}
	g.mu.Lock() // (conns is shared by the calls)
	defer g.mu.Unlock()
	if c := g.conns[addr]; c != nil {
		return c, nil
	}
	c, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, err
	}
	g.conns[addr] = c
	return c, nil
}

// handle answers a request for any method: one the program serves, else
// Unimplemented.
func (g *grpcHost) handle(_ any, stream grpc.ServerStream) error {
	path, _ := grpc.MethodFromServerStream(stream)
	m := g.served[path]
	if m == nil {
		return status.Errorf(codes.Unimplemented, "%s: the program serves no such method (it would define %s_response)", path, lastPart(path))
	}
	var in []byte
	if err := stream.RecvMsg(&in); err != nil {
		return err
	}
	req := dynamicpb.NewMessage(m.input)
	if err := proto.Unmarshal(in, req); err != nil {
		return status.Error(codes.InvalidArgument, err.Error())
	}
	ch := make(chan answer, 1)
	g.mu.Lock()
	res, err := g.call("request", g.server, starlark.String(m.name), starlark.NewList(tupleItems(fields(req, true))))
	var id starlark.Value
	if err == nil {
		if e, ok := res.(starlark.Tuple); ok {
			c, _ := starlark.AsString(e[0])
			msg, _ := starlark.AsString(e[1])
			err = status.Error(codeOf(c), msg)
		} else {
			id = res
			g.waiting[waitKey(m.name, id)] = ch
			g.after()
		}
	} else {
		err = status.Error(codes.Internal, message(err))
	}
	g.mu.Unlock()
	if err != nil {
		return err
	}
	ctx := stream.Context()
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, g.timeout)
		defer cancel()
	}
	select {
	case a := <-ch:
		if a.err != nil {
			return a.err
		}
		return stream.SendMsg(&a.data)
	case <-ctx.Done():
		g.mu.Lock()
		delete(g.waiting, waitKey(m.name, id))
		g.call("forget", g.server, starlark.String(m.name), id)
		g.mu.Unlock()
		return status.Errorf(codes.DeadlineExceeded, "%s_response: no answer to request %s", m.name, id.String())
	}
}

func lastPart(path string) string { return path[strings.LastIndex(path, "/")+1:] }

// readPool reads a binary FileDescriptorSet.
func readPool(file string) (*protoregistry.Files, error) {
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
