# wasm.star — a WebAssembly (incl. WasmGC) binary encoder written in Starlark.
#
# Instructions are plain data. An instruction is a tuple whose first
# element is the opcode name, followed by its immediates:
#
#     ("i32.const", 42)   ("local.get", "n")   ("call", "fact")
#     ("struct.get", "List", "len")            ("ref.test", ref("Str"))
#     ("block", None, "exit")  ...  ("br", "exit")
#
# A bare string like "i64.add" is shorthand for ("i64.add",). Bodies may
# contain nested lists; they are flattened during encoding, so Starlark
# functions can return code fragments and be composed freely.
#
# Everything is referred to by NAME and resolved at encode time: locals,
# functions, globals, types, struct fields, data segments, and labels.
# Labels may also be given as raw relative depths (ints).

# ---------------------------------------------------------------- value types

I32 = 0x7f
I64 = 0x7e
F32 = 0x7d
F64 = 0x7c
I8 = "i8"  # packed storage types: only valid as struct fields / array elements
I16 = "i16"

# Abstract heap types. A heap type is either one of these names, or the
# name of a type declared with add_type.
ABSTRACT_HEAP = {
    "any": 0x6e,
    "eq": 0x6d,
    "i31": 0x6c,
    "struct": 0x6b,
    "array": 0x6a,
    "none": 0x71,
    "func": 0x70,
    "nofunc": 0x73,
    "extern": 0x6f,
    "noextern": 0x72,
}

def ref(ht, null = False):
    """A reference value type: (ref ht) or, with null=True, (ref null ht)."""
    return ("ref", null, ht)

ANYREF = ref("any", True)
EQREF = ref("eq", True)
I31REF = ref("i31", True)
FUNCREF = ref("func", True)
EXTERNREF = ref("extern", True)

def struct_type(fields):
    """fields: list of (name, storage type, mutable)."""
    return ("struct", fields)

def array_type(elem, mutable):
    return ("array", elem, mutable)

_BLOCKTYPE_EMPTY = 0x40

_SEC_CUSTOM = 0
_SEC_TYPE = 1
_SEC_IMPORT = 2
_SEC_FUNCTION = 3
_SEC_MEMORY = 5
_SEC_GLOBAL = 6
_SEC_EXPORT = 7
_SEC_ELEM = 9
_SEC_CODE = 10
_SEC_DATA = 11
_SEC_DATACOUNT = 12

_MAGIC = [0x00, 0x61, 0x73, 0x6d]  # "\0asm"
_VERSION = [0x01, 0x00, 0x00, 0x00]

# ---------------------------------------------------------------- LEB128

def uleb(n):
    """Unsigned LEB128 encoding of a non-negative int, as a list of bytes."""
    if n < 0:
        fail("uleb: negative value %d" % n)
    out = []
    while True:
        b = n & 0x7f
        n = n >> 7
        if n == 0:
            out.append(b)
            return out
        out.append(b | 0x80)

def sleb(n):
    """Signed LEB128 encoding of an int, as a list of bytes."""
    out = []
    while True:
        b = n & 0x7f
        n = n >> 7  # arithmetic shift
        if (n == 0 and b & 0x40 == 0) or (n == -1 and b & 0x40 != 0):
            out.append(b)
            return out
        out.append(b | 0x80)

def _check_range(n, bits, what):
    if bits == 64:
        # Written without 1 << 63: when this file is itself compiled, ints
        # are 64-bit and that shift would overflow.
        if type(n) != "int" or n < -9223372036854775807 - 1 or n > 9223372036854775807:
            fail("%s: %r does not fit in %d bits" % (what, n, bits))
        return n
    lo = -(1 << (bits - 1))
    hi = (1 << bits) - 1  # allow unsigned spellings too, e.g. 0xffffffff
    if type(n) != "int" or n < lo or n > hi:
        fail("%s: %r does not fit in %d bits" % (what, n, bits))
    if n >= (1 << (bits - 1)):
        n = n - (1 << bits)  # reinterpret as signed
    return n

# ---------------------------------------------------------------- helpers

def utf8(s):
    """UTF-8 bytes of a string, as a list of ints."""
    return list(s.elem_ords())

def vec(items):
    """A Wasm vector: length prefix, then the already-encoded items."""
    out = uleb(len(items))
    for it in items:
        out.extend(it)
    return out

def name(s):
    b = utf8(s)
    return uleb(len(b)) + b

def section(id, payload):
    return [id] + uleb(len(payload)) + payload

def flatten(body):
    """Flatten nested instruction lists into a single list of tuples."""
    out = []
    stack = [body]
    while stack:
        x = stack.pop()
        if type(x) == "list":
            for i in range(len(x) - 1, -1, -1):
                stack.append(x[i])
        elif type(x) == "string":
            out.append((x,))
        elif type(x) == "tuple":
            out.append(x)
        elif x == None:
            pass  # lets helpers return None for "no code"
        else:
            fail("flatten: unexpected %s in instruction list: %r" % (type(x), x))
    return out

# ---------------------------------------------------------------- opcodes
#
# name -> (opcode bytes, immediate kinds)
#
# Immediate kinds:
#   s32 s64      signed constants
#   u32          unsigned constant
#   local func global type data
#                names resolved to indices
#   field        struct field name (of the type in the preceding immediate)
#   label        label name or relative depth
#   block        block type: None, or a value type; optional label name follows
#   heap         heap type (abstract name or type name)
#   mem0 mem2 mem3  memarg with alignment 2^k; immediate is the offset
#   table        br_table: (list of labels, default label)

def _gc(n):
    return [0xfb] + uleb(n)

OPS = {
    "unreachable": ([0x00], []),
    "nop": ([0x01], []),
    "block": ([0x02], ["block"]),
    "loop": ([0x03], ["block"]),
    "if": ([0x04], ["block"]),
    "else": ([0x05], []),
    "end": ([0x0b], []),
    "br": ([0x0c], ["label"]),
    "br_if": ([0x0d], ["label"]),
    "br_table": ([0x0e], ["table"]),
    "return": ([0x0f], []),
    "call": ([0x10], ["func"]),
    "return_call": ([0x12], ["func"]),
    "call_ref": ([0x14], ["type"]),
    "return_call_ref": ([0x15], ["type"]),
    "drop": ([0x1a], []),
    "select": ([0x1b], []),
    "local.get": ([0x20], ["local"]),
    "local.set": ([0x21], ["local"]),
    "local.tee": ([0x22], ["local"]),
    "global.get": ([0x23], ["global"]),
    "global.set": ([0x24], ["global"]),
    "i32.load": ([0x28], ["mem2"]),
    "i64.load": ([0x29], ["mem3"]),
    "i32.load8_u": ([0x2d], ["mem0"]),
    "i32.store": ([0x36], ["mem2"]),
    "i64.store": ([0x37], ["mem3"]),
    "f64.load": ([0x2b], ["mem3"]),
    "i32.store8": ([0x3a], ["mem0"]),
    "f64.store": ([0x39], ["mem3"]),
    "i32.const": ([0x41], ["s32"]),
    "i64.const": ([0x42], ["s64"]),
    "i32.eqz": ([0x45], []),
    "i32.eq": ([0x46], []),
    "i32.ne": ([0x47], []),
    "i32.lt_s": ([0x48], []),
    "i32.lt_u": ([0x49], []),
    "i32.gt_s": ([0x4a], []),
    "i32.gt_u": ([0x4b], []),
    "i32.le_s": ([0x4c], []),
    "i32.le_u": ([0x4d], []),
    "i32.ge_s": ([0x4e], []),
    "i32.ge_u": ([0x4f], []),
    "i64.eqz": ([0x50], []),
    "i64.eq": ([0x51], []),
    "i64.ne": ([0x52], []),
    "i64.lt_s": ([0x53], []),
    "i64.lt_u": ([0x54], []),
    "i64.gt_s": ([0x55], []),
    "i64.gt_u": ([0x56], []),
    "i64.le_s": ([0x57], []),
    "i64.le_u": ([0x58], []),
    "i64.ge_s": ([0x59], []),
    "i64.ge_u": ([0x5a], []),
    "i32.clz": ([0x67], []),
    "i32.ctz": ([0x68], []),
    "i32.popcnt": ([0x69], []),
    "i32.add": ([0x6a], []),
    "i32.sub": ([0x6b], []),
    "i32.mul": ([0x6c], []),
    "i32.div_s": ([0x6d], []),
    "i32.div_u": ([0x6e], []),
    "i32.rem_s": ([0x6f], []),
    "i32.rem_u": ([0x70], []),
    "i32.and": ([0x71], []),
    "i32.or": ([0x72], []),
    "i32.xor": ([0x73], []),
    "i32.shl": ([0x74], []),
    "i32.shr_s": ([0x75], []),
    "i32.shr_u": ([0x76], []),
    "i64.clz": ([0x79], []),
    "i64.ctz": ([0x7a], []),
    "i64.popcnt": ([0x7b], []),
    "i64.add": ([0x7c], []),
    "i64.sub": ([0x7d], []),
    "i64.mul": ([0x7e], []),
    "i64.div_s": ([0x7f], []),
    "i64.div_u": ([0x80], []),
    "i64.rem_s": ([0x81], []),
    "i64.rem_u": ([0x82], []),
    "i64.and": ([0x83], []),
    "i64.or": ([0x84], []),
    "i64.xor": ([0x85], []),
    "i64.shl": ([0x86], []),
    "i64.shr_s": ([0x87], []),
    "i64.shr_u": ([0x88], []),
    "f64.eq": ([0x61], []),
    "f64.ne": ([0x62], []),
    "f64.lt": ([0x63], []),
    "f64.gt": ([0x64], []),
    "f64.le": ([0x65], []),
    "f64.ge": ([0x66], []),
    "f64.abs": ([0x99], []),
    "f64.neg": ([0x9a], []),
    "f64.ceil": ([0x9b], []),
    "f64.floor": ([0x9c], []),
    "f64.trunc": ([0x9d], []),
    "f64.nearest": ([0x9e], []),
    "f64.sqrt": ([0x9f], []),
    "f64.add": ([0xa0], []),
    "f64.sub": ([0xa1], []),
    "f64.mul": ([0xa2], []),
    "f64.div": ([0xa3], []),
    "f64.min": ([0xa4], []),
    "f64.max": ([0xa5], []),
    "f64.copysign": ([0xa6], []),
    "i32.wrap_i64": ([0xa7], []),
    "i64.trunc_f64_s": ([0xb0], []),
    "f64.convert_i64_s": ([0xb9], []),
    "f64.convert_i64_u": ([0xba], []),
    "i64.reinterpret_f64": ([0xbd], []),
    "f64.reinterpret_i64": ([0xbf], []),
    "i64.extend_i32_s": ([0xac], []),
    "i64.extend_i32_u": ([0xad], []),
    "ref.null": ([0xd0], ["heap"]),
    "ref.is_null": ([0xd1], []),
    "ref.func": ([0xd2], ["func"]),
    "ref.eq": ([0xd3], []),
    "ref.as_non_null": ([0xd4], []),
    "br_on_null": ([0xd5], ["label"]),
    "br_on_non_null": ([0xd6], ["label"]),
    "struct.new": (_gc(0), ["type"]),
    "struct.new_default": (_gc(1), ["type"]),
    "struct.get": (_gc(2), ["type", "field"]),
    "struct.get_s": (_gc(3), ["type", "field"]),
    "struct.get_u": (_gc(4), ["type", "field"]),
    "struct.set": (_gc(5), ["type", "field"]),
    "array.new": (_gc(6), ["type"]),
    "array.new_default": (_gc(7), ["type"]),
    "array.new_fixed": (_gc(8), ["type", "u32"]),
    "array.new_data": (_gc(9), ["type", "data"]),
    "array.get": (_gc(11), ["type"]),
    "array.get_s": (_gc(12), ["type"]),
    "array.get_u": (_gc(13), ["type"]),
    "array.set": (_gc(14), ["type"]),
    "array.len": (_gc(15), []),
    "array.fill": (_gc(16), ["type"]),
    "array.copy": (_gc(17), ["type", "type"]),
    # ref.test / ref.cast / br_on_cast(_fail) are special-cased in _encode_instrs.
    "any.convert_extern": (_gc(26), []),
    "extern.convert_any": (_gc(27), []),
    "ref.i31": (_gc(28), []),
    "i31.get_s": (_gc(29), []),
    "i31.get_u": (_gc(30), []),
}

_BLOCK_OPS = ("block", "loop", "if")

# ---------------------------------------------------------------- module

def new_module():
    return {
        "types": [],  # list of dicts: name, comp, supers, final
        "type_index": {},  # type name -> index
        "functype_index": {},  # (params, results) -> index
        "fields": {},  # struct type name -> {field name: index}
        "imports": [],
        "funcs": [],
        "func_index": {},  # name -> function index
        "globals": [],
        "global_index": {},
        "data": [],  # list of (name, bytes list); lists may grow until encode
        "data_index": {},
        "memory": None,  # (min pages,) or None
        "exports": [],  # list of (export name, kind, index)
        "customs": [],  # extra custom sections: (name, bytes)
    }

def add_type(m, tname, comp, supers = [], final = True):
    """Declare a named struct/array/func type. All types share one rec group,
    so types may refer to each other (and themselves) in any order."""
    if tname in ABSTRACT_HEAP or tname in m["type_index"]:
        fail("add_type: bad or duplicate type name %r" % tname)
    m["type_index"][tname] = len(m["types"])
    m["types"].append({"name": tname, "comp": comp, "supers": supers, "final": final})
    if comp[0] == "struct":
        m["fields"][tname] = {f[0]: i for i, f in enumerate(comp[1])}

def func_type(m, params, results):
    """Index of the (deduplicated) function type params -> results."""
    key = (tuple(params), tuple(results))
    if key not in m["functype_index"]:
        m["functype_index"][key] = len(m["types"])
        m["types"].append({"name": None, "comp": ("func", key[0], key[1]), "supers": [], "final": True})
    return m["functype_index"][key]

def _declare(m, fname):
    if fname in m["func_index"]:
        fail("function %r declared twice" % fname)
    m["func_index"][fname] = len(m["imports"]) + len(m["funcs"])

def import_func(m, module, field, params, results, as_name = None):
    """Declare an imported function. Imports must precede defined functions."""
    if m["funcs"]:
        fail("import_func(%r): imports must be declared before functions" % field)
    fname = as_name or field
    _declare(m, fname)
    m["imports"].append({
        "name": fname,
        "module": module,
        "field": field,
        "type": func_type(m, params, results),
    })

def add_func(m, fname, params, results, body, locals = [], export = None, typ = None):
    """Define a function.

    params, locals: lists of (name, valtype) pairs
    results:        list of valtypes
    body:           instruction list (may be nested)
    export:         export name, or True to export under fname
    typ:            name of a declared func type to use (needed when the
                    function is referenced with ref.func and called through
                    call_ref of that type); default: structural func type
    """
    _declare(m, fname)
    tidx = func_type(m, [t for _, t in params], results) if typ == None else _type_ref(m, typ, fname)
    m["funcs"].append({
        "name": fname,
        "params": params,
        "results": results,
        "locals": locals,
        "body": body,
        "type": tidx,
    })
    if export:
        m["exports"].append((fname if export == True else export, 0, m["func_index"][fname]))

def has_func(m, fname):
    return fname in m["func_index"]

def add_global(m, gname, valtype, mutable, init):
    """Define a global. init is a constant expression (instruction list)."""
    if gname in m["global_index"]:
        fail("global %r declared twice" % gname)
    m["global_index"][gname] = len(m["globals"])
    m["globals"].append({"name": gname, "type": valtype, "mutable": mutable, "init": init})

def add_data(m, dname, data):
    """Define a passive data segment. `data` is a list of byte values; the
    same list object may keep growing until encode() is called."""
    if dname in m["data_index"]:
        fail("data segment %r declared twice" % dname)
    m["data_index"][dname] = len(m["data"])
    m["data"].append((dname, data))

def add_memory(m, min_pages, export = None):
    m["memory"] = (min_pages,)
    if export:
        m["exports"].append((export, 2, 0))

# ---------------------------------------------------------------- types encoding

def _type_ref(m, tname, what):
    if tname not in m["type_index"]:
        fail("%s: unknown type %r" % (what, tname))
    return m["type_index"][tname]

def _heaptype(m, ht, what):
    if ht in ABSTRACT_HEAP:
        return [ABSTRACT_HEAP[ht]]
    return sleb(_type_ref(m, ht, what))  # s33, always non-negative here

def _valtype(m, t, what = "valtype"):
    if type(t) == "int":
        return [t]
    if t == I8:
        return [0x78]
    if t == I16:
        return [0x77]
    if type(t) == "tuple" and len(t) == 3 and t[0] == "ref":
        _, null, ht = t
        if null and ht in ABSTRACT_HEAP:
            return [ABSTRACT_HEAP[ht]]  # shorthand, e.g. anyref
        return [0x63 if null else 0x64] + _heaptype(m, ht, what)
    fail("%s: not a value type: %r" % (what, t))

def _comptype(m, t):
    comp = t["comp"]
    what = "type %s" % (t["name"] or "<func>")
    if comp[0] == "func":
        return [0x60] + vec([_valtype(m, p, what) for p in comp[1]]) + vec([_valtype(m, r, what) for r in comp[2]])
    if comp[0] == "struct":
        return [0x5f] + vec([_valtype(m, ft, what) + [1 if mut else 0] for _, ft, mut in comp[1]])
    if comp[0] == "array":
        return [0x5e] + _valtype(m, comp[1], what) + [1 if comp[2] else 0]
    fail("%s: bad composite type %r" % (what, comp))

def _type_section(m):
    plain = all([t["comp"][0] == "func" and t["final"] and not t["supers"] for t in m["types"]])
    if plain:
        # MVP-compatible encoding when there are no GC types.
        return vec([_comptype(m, t) for t in m["types"]])
    subs = []
    for t in m["types"]:
        supers = [uleb(_type_ref(m, s, "supertype of %s" % t["name"])) for s in t["supers"]]
        subs.append([0x4f if t["final"] else 0x50] + vec(supers) + _comptype(m, t))
    return uleb(1) + [0x4e] + vec(subs)  # one rec group holding every type

# ---------------------------------------------------------------- code encoding

def _resolve_label(ctx, lab, op):
    labels = ctx["labels"]
    if type(lab) == "int":
        if lab < 0 or lab > len(labels):
            fail("%s: %s %d is outside the %d enclosing blocks" % (ctx["what"], op, lab, len(labels)))
        return lab
    for depth in range(len(labels)):
        if labels[len(labels) - 1 - depth] == lab:
            return depth
    fail("%s: %s to unknown label %r" % (ctx["what"], op, lab))

def _encode_instrs(m, ctx, instrs):
    what = ctx["what"]
    out = []
    for ins in flatten(instrs):
        op = ins[0]

        # Source marker: no bytes; remembers where the next instruction
        # starts, so engine stack offsets can be mapped back to source.
        if op == "@pos":
            ctx["marks"].append((len(out), ins[1]))
            continue

        # Ops whose encoding depends on immediates.
        if op == "ref.test" or op == "ref.cast":
            if len(ins) != 2:
                fail("%s: %s takes a reference type, got %r" % (what, op, ins))
            _, null, ht = ins[1]
            base = 20 if op == "ref.test" else 22
            out.extend(_gc(base + (1 if null else 0)) + _heaptype(m, ht, what))
            continue
        if op == "br_on_cast" or op == "br_on_cast_fail":
            if len(ins) != 4:
                fail("%s: %s takes (label, from reftype, to reftype), got %r" % (what, op, ins))
            _, lab, t1, t2 = ins
            flags = (1 if t1[1] else 0) | (2 if t2[1] else 0)
            out.extend(_gc(24 if op == "br_on_cast" else 25) + [flags] +
                       uleb(_resolve_label(ctx, lab, op)) +
                       _heaptype(m, t1[2], what) + _heaptype(m, t2[2], what))
            continue

        if op not in OPS:
            fail("%s: unknown instruction %r" % (what, op))
        code, kinds = OPS[op]
        nimm = len(ins) - 1
        if op in _BLOCK_OPS:
            if nimm != 1 and nimm != 2:
                fail("%s: %s takes a block type and optional label, got %r" % (what, op, ins))
        elif nimm != len(kinds):
            fail("%s: %s takes %d immediate(s), got %r" % (what, op, len(kinds), ins))
        out.extend(code)

        for i, kind in enumerate(kinds):
            imm = ins[i + 1]
            if kind == "s32":
                out.extend(sleb(_check_range(imm, 32, op)))
            elif kind == "s64":
                out.extend(sleb(_check_range(imm, 64, op)))
            elif kind == "u32":
                out.extend(uleb(imm))
            elif kind == "local":
                if imm not in ctx["locals"]:
                    fail("%s: %s of unknown local %r" % (what, op, imm))
                out.extend(uleb(ctx["locals"][imm]))
            elif kind == "func":
                if imm not in m["func_index"]:
                    fail("%s: %s of unknown function %r" % (what, op, imm))
                idx = m["func_index"][imm]
                out.extend(uleb(idx))
                if op == "ref.func":
                    ctx["refs"][idx] = True
            elif kind == "global":
                if imm not in m["global_index"]:
                    fail("%s: %s of unknown global %r" % (what, op, imm))
                out.extend(uleb(m["global_index"][imm]))
            elif kind == "type":
                out.extend(uleb(_type_ref(m, imm, "%s: %s" % (what, op))))
            elif kind == "field":
                tname = ins[i]
                fields = m["fields"].get(tname)
                if fields == None or imm not in fields:
                    fail("%s: %s: type %r has no field %r" % (what, op, tname, imm))
                out.extend(uleb(fields[imm]))
            elif kind == "data":
                if imm not in m["data_index"]:
                    fail("%s: %s of unknown data segment %r" % (what, op, imm))
                out.extend(uleb(m["data_index"][imm]))
            elif kind == "heap":
                out.extend(_heaptype(m, imm, what))
            elif kind == "label":
                out.extend(uleb(_resolve_label(ctx, imm, op)))
            elif kind == "table":
                labs, default = imm
                out.extend(vec([uleb(_resolve_label(ctx, l, op)) for l in labs]))
                out.extend(uleb(_resolve_label(ctx, default, op)))
            elif kind == "block":
                out.extend([_BLOCKTYPE_EMPTY] if imm == None else _valtype(m, imm, what))
            elif kind == "mem0" or kind == "mem2" or kind == "mem3":
                out.extend(uleb(int(kind[3:])) + uleb(imm))
            else:
                fail("internal: bad immediate kind %r" % kind)

        if op in _BLOCK_OPS:
            ctx["labels"].append(ins[2] if nimm == 2 else None)
        elif op == "end":
            if not ctx["labels"]:
                fail("%s: unbalanced `end`" % what)
            ctx["labels"].pop()
    if ctx["labels"]:
        fail("%s: %d unclosed block(s)" % (what, len(ctx["labels"])))
    return out + [0x0b]  # final `end`

def _encode_body(m, f, refs):
    local_index = {}
    for i, (lname, _) in enumerate(f["params"] + f["locals"]):
        if lname in local_index:
            fail("%s: duplicate local %r" % (f["name"], lname))
        local_index[lname] = i

    # Locals are encoded as run-length groups of identical types.
    groups = []
    for _, t in f["locals"]:
        if groups and groups[-1][1] == t:
            groups[-1] = (groups[-1][0] + 1, t)
        else:
            groups.append((1, t))
    out = vec([uleb(n) + _valtype(m, t, f["name"]) for n, t in groups])
    ctx = {"what": f["name"], "locals": local_index, "labels": [], "refs": refs, "marks": []}
    start = len(out)
    out.extend(_encode_instrs(m, ctx, f["body"]))
    size = uleb(len(out))
    # marks as offsets from the start of this function's entry (size prefix included)
    marks = [(len(size) + start + o, tag) for o, tag in ctx["marks"]]
    return (size + out, marks)

def _const_expr(m, what, instrs, refs):
    ctx = {"what": what, "locals": {}, "labels": [], "refs": refs, "marks": []}
    return _encode_instrs(m, ctx, instrs)

def add_custom(m, cname, data):
    """Append a custom section (name, list of byte values)."""
    m["customs"].append((cname, data))

# ---------------------------------------------------------------- name section

def _namemap(pairs):
    return vec([uleb(i) + name(n) for i, n in sorted(pairs)])

def _subsection(id, payload):
    return [id] + uleb(len(payload)) + payload

def _name_section(m):
    nimports = len(m["imports"])
    funcs = [(i, f["name"]) for i, f in enumerate(m["imports"])]
    funcs += [(nimports + i, f["name"]) for i, f in enumerate(m["funcs"])]
    local_maps = []
    for i, f in enumerate(m["funcs"]):
        ls = [(j, ln) for j, (ln, _) in enumerate(f["params"] + f["locals"])]
        if ls:
            local_maps.append(uleb(nimports + i) + _namemap(ls))
    types = [(i, t["name"]) for i, t in enumerate(m["types"]) if t["name"]]
    field_maps = []
    for i, t in enumerate(m["types"]):
        if t["comp"][0] == "struct" and t["comp"][1]:
            field_maps.append(uleb(i) + _namemap([(j, fl[0]) for j, fl in enumerate(t["comp"][1])]))
    globals_ = [(i, g["name"]) for i, g in enumerate(m["globals"])]

    payload = name("name")
    payload += _subsection(1, _namemap(funcs))
    if local_maps:
        payload += _subsection(2, vec(local_maps))
    if types:
        payload += _subsection(4, _namemap(types))
    if globals_:
        payload += _subsection(7, _namemap(globals_))
    if field_maps:
        payload += _subsection(10, vec(field_maps))
    return payload

# ---------------------------------------------------------------- module encoding

def encode(m, names = True):
    """Encode a module to a list of byte values. names=True adds a `name`
    custom section so engines and wasm-tools show symbolic names."""
    refs = {}  # function indices used by ref.func (need declaring)
    # Code section payload, tracking where each source marker lands.
    nimports = len(m["imports"])
    code = uleb(len(m["funcs"]))
    marks = []  # (function index, offset within code payload, tag)
    for i, f in enumerate(m["funcs"]):
        body, fmarks = _encode_body(m, f, refs)
        for o, tag in fmarks:
            marks.append((nimports + i, len(code) + o, tag))
        code.extend(body)
    globals_ = vec([
        _valtype(m, g["type"], g["name"]) + [1 if g["mutable"] else 0] +
        _const_expr(m, "global " + g["name"], g["init"], refs)
        for g in m["globals"]
    ])

    out = _MAGIC + _VERSION
    if m["types"]:
        out += section(_SEC_TYPE, _type_section(m))
    if m["imports"]:
        out += section(_SEC_IMPORT, vec([
            name(i["module"]) + name(i["field"]) + [0x00] + uleb(i["type"])
            for i in m["imports"]
        ]))
    if m["funcs"]:
        out += section(_SEC_FUNCTION, vec([uleb(f["type"]) for f in m["funcs"]]))
    if m["memory"]:
        out += section(_SEC_MEMORY, vec([[0x00] + uleb(m["memory"][0])]))
    if m["globals"]:
        out += section(_SEC_GLOBAL, globals_)
    if m["exports"]:
        out += section(_SEC_EXPORT, vec([name(e) + [k] + uleb(i) for e, k, i in m["exports"]]))
    if refs:
        # One declarative segment makes ref.func legal for these functions.
        out += section(_SEC_ELEM, vec([[0x03, 0x00] + vec([uleb(i) for i in sorted(refs)])]))
    if m["data"]:
        out += section(_SEC_DATACOUNT, uleb(len(m["data"])))
    if m["funcs"]:
        base = len(out) + 1 + len(uleb(len(code)))  # module offset of the payload
        out += section(_SEC_CODE, code)
    if m["data"]:
        out += section(_SEC_DATA, vec([[0x01] + uleb(len(d)) + list(d) for _, d in m["data"]]))
    if names:
        out += section(_SEC_CUSTOM, _name_section(m))
    if marks:
        # "starwasm.marks", grouped by function (marks are in offset order):
        #   count of groups; per group: function index, count, then per mark
        #   the module-offset delta from the previous mark (the first is
        #   absolute) and the tag.
        groups = []
        for fi, o, tag in marks:
            if not groups or groups[-1][0] != fi:
                groups.append((fi, []))
            groups[-1][1].append((base + o, tag))
        payload = name("starwasm.marks") + uleb(len(groups))
        for fi, ms in groups:
            payload += uleb(fi) + uleb(len(ms))
            prev = 0
            for o, tag in ms:
                payload += uleb(o - prev) + uleb(tag)
                prev = o
        out += section(_SEC_CUSTOM, payload)
    for cname, data in m["customs"]:
        out += section(_SEC_CUSTOM, name(cname) + data)
    return out
