# proto.star — the types of the proto module's values, from the schema.
#
# With a descriptor set (main.star's --descriptor_set=FILE: the binary
# FileDescriptorSet the program is compiled and run with), the checker
# knows the .proto files a program can open with proto.file(), and types
# what it does with them (EXTENSIONS.md, "Protocol buffers"). Without one,
# `proto` is Any, as before.
#
# The types are constructor types (types.star's con) with these names:
#
#   proto.Module                      the predeclared `proto`
#   proto.FileDescriptor["f.proto"]   proto.file("f.proto") (the name is
#                                     the whole con name; a file not known
#                                     statically is proto.FileDescriptor)
#   pkg.Msg                           a message of type pkg.Msg (its full
#                                     name), and an enum value of enum pkg.E
#   type[pkg.Msg]                     the message descriptor (it is called
#                                     to make a message), the enum
#                                     descriptor type[pkg.E]
#   proto.FieldDescriptor[M, T]       a field of message M whose value is a T
#                                     (p.Msg.f, and extensions)
#   proto.RepeatedField[T]            a repeated field's value
#   proto.MapField[K, V]              a map field's value
#
# Types are nominal: messages and enums are known by their full names, and
# a message is a struct only where it is passed to code that reads fields
# of a struct (unify.star: flow). This file decodes the descriptor set and
# answers what the schema says (the members of each type); unify.star and
# infer.star use it.

load("../compiler/spell.star", "nearest")
load("types.star", "T_ANY", "con", "field", "lit", "rec", "resolve", "row")

MODULE = "proto.Module"
FILE = "proto.FileDescriptor"
FIELD = "proto.FieldDescriptor"
REPEATED = "proto.RepeatedField"
MAP = "proto.MapField"
TYPE = "type"

# the module's members, as values (a call proto.member(...) is typed by
# infer.star's _sp_proto, from its arguments)
MEMBERS = """
def file(self: proto.Module, name: str) -> proto.FileDescriptor
def has(self: proto.Module, msg: Any, field: Any) -> bool
def get_field(self: proto.Module, msg: Any, field: Any) -> Any
def set_field(self: proto.Module, msg: Any, field: Any, value: Any) -> None
def marshal(self: proto.Module, msg: Any) -> bytes
def marshal_text(self: proto.Module, msg: Any) -> str
def unmarshal(self: proto.Module, desc: Any, data: bytes) -> Any
def unmarshal_text(self: proto.Module, desc: Any, data: str) -> Any
"""

# ---------------------------------------------------------------- decoding

def _varint(o, i):
    """(value, next index) of the varint at o[i] (o: the bytes as ints).
    Only the low 32 bits are kept, as a signed int32 if the varint is
    negative (10 bytes): what a descriptor's numbers need."""
    v = 0
    shift = 0
    n = len(o)
    for _ in range(10):
        if i >= n:
            fail("typecheck: invalid descriptor set")
        b = o[i]
        i += 1
        if shift < 32:
            v |= (b & 127) << shift
        shift += 7
        if b < 128:
            break
    v &= 4294967295
    if v >= 2147483648:
        v -= 4294967296
    return v, i

def _fields(d, o, lo, hi):
    """The fields of the message encoded in o[lo:hi]: (number, wire type,
    value), the value an int for a varint, (start, end) for a
    length-delimited field (others are skipped)."""
    out = []
    i = lo
    for _ in range(hi - lo + 1):
        if i >= hi:
            break
        tag, i = _varint(o, i)
        num = (tag & 4294967295) >> 3
        wt = tag & 7
        if wt == 0:
            v, i = _varint(o, i)
            out.append((num, wt, v))
        elif wt == 2:
            n, i = _varint(o, i)
            if n < 0 or i + n > hi:
                fail("typecheck: invalid descriptor set")
            out.append((num, wt, (i, i + n)))
            i += n
        elif wt == 1:
            i += 8
        elif wt == 5:
            i += 4
        else:
            fail("typecheck: invalid descriptor set")
    return out

def _join(prefix, name):
    return prefix + "." + name if prefix else name

def decode_pool(data):
    """The schema of the binary FileDescriptorSet data (a string):
    {files: name -> file, msgs: full name -> msg, enums: full name -> enum}.
      file   {name, members}
      msg    {full, name, fields: [field], by_name, members, map_entry, required}
      enum   {full, name, values: [name], by_name: name -> number, numbers}
      field  {name, label, type, type_name, containing, required}
    members: name -> ("msg" | "enum", full name) | ("ext", field), the
    nested types and extensions (a file's top-level ones)."""
    o = list(data.elem_ords())
    pool = {"files": {}, "msgs": {}, "enums": {}, "exts": []}
    for num, wt, v in _fields(data, o, 0, len(o)):
        if num == 1 and wt == 2:
            _file(pool, data, o, v)
    for f in pool["exts"]:
        m = pool["msgs"].get(f["containing"])
        if m != None:
            m["exts"].append(f)
    # a message requires its required fields, and those of the messages it holds
    for _ in range(len(pool["msgs"]) + 1):
        more = False
        for m in pool["msgs"].values():
            if m["required"]:
                continue
            for f in m["fields"]:
                sub = pool["msgs"].get(f["type_name"])
                if f["required"] or (sub != None and sub["required"] and not sub["map_entry"]) or \
                   (sub != None and sub["map_entry"] and _map_value_required(pool, sub)):
                    m["required"] = True
                    more = True
                    break
        if not more:
            break
    return pool

def _map_value_required(pool, entry):
    for f in entry["fields"]:
        sub = pool["msgs"].get(f["type_name"])
        if f["name"] == "value" and sub != None and sub["required"]:
            return True
    return False

def _str(data, v):
    return data[v[0]:v[1]]

def _file(pool, data, o, span):
    fd = {"name": "", "package": "", "members": {}}
    raw = _fields(data, o, span[0], span[1])
    for num, wt, v in raw:
        if num == 1 and wt == 2:
            fd["name"] = _str(data, v)
        elif num == 2 and wt == 2:
            fd["package"] = _str(data, v)
    for num, wt, v in raw:
        if num == 4 and wt == 2:
            m = _message(pool, data, o, v, fd["package"])
            fd["members"].setdefault(m["name"], ("msg", m["full"]))
        elif num == 5 and wt == 2:
            e = _enum(pool, data, o, v, fd["package"])
            fd["members"].setdefault(e["name"], ("enum", e["full"]))
        elif num == 7 and wt == 2:
            f = _field(data, o, v, None)
            pool["exts"].append(f)
            fd["members"].setdefault(f["name"], ("ext", f))
    pool["files"].setdefault(fd["name"], fd)

def _message(pool, data, o, span, prefix):
    m = {"full": "", "name": "", "fields": [], "by_name": {}, "members": {}, "exts": [], "map_entry": False, "required": False}
    raw = _fields(data, o, span[0], span[1])
    for num, wt, v in raw:
        if num == 1 and wt == 2:
            m["name"] = _str(data, v)
        elif num == 7 and wt == 2:
            for n2, w2, v2 in _fields(data, o, v[0], v[1]):
                if n2 == 7 and w2 == 0:
                    m["map_entry"] = v2 != 0
    m["full"] = _join(prefix, m["name"])
    for num, wt, v in raw:
        if wt != 2:
            continue
        if num == 2:
            f = _field(data, o, v, m["full"])
            m["fields"].append(f)
            m["by_name"].setdefault(f["name"], f)
            if f["required"]:
                m["required"] = True
        elif num == 3:
            sub = _message(pool, data, o, v, m["full"])
            m["members"].setdefault(sub["name"], ("msg", sub["full"]))
        elif num == 4:
            e = _enum(pool, data, o, v, m["full"])
            m["members"].setdefault(e["name"], ("enum", e["full"]))
        elif num == 6:
            f = _field(data, o, v, None)
            pool["exts"].append(f)
            m["members"].setdefault(f["name"], ("ext", f))
    pool["msgs"].setdefault(m["full"], m)
    return m

def _enum(pool, data, o, span, prefix):
    e = {"full": "", "name": "", "values": [], "by_name": {}, "numbers": {}}
    raw = _fields(data, o, span[0], span[1])
    for num, wt, v in raw:
        if num == 1 and wt == 2:
            e["name"] = _str(data, v)
        elif num == 2 and wt == 2:
            name = ""
            number = 0
            for n2, w2, v2 in _fields(data, o, v[0], v[1]):
                if n2 == 1 and w2 == 2:
                    name = _str(data, v2)
                elif n2 == 2 and w2 == 0:
                    number = v2
            if name not in e["by_name"]:
                e["values"].append(name)
                e["by_name"][name] = number
            e["numbers"][number] = True
    e["full"] = _join(prefix, e["name"])
    pool["enums"].setdefault(e["full"], e)
    return e

def _field(data, o, span, containing):
    f = {"name": "", "label": 1, "type": 0, "type_name": "", "containing": containing, "required": False}
    for num, wt, v in _fields(data, o, span[0], span[1]):
        if num == 1 and wt == 2:
            f["name"] = _str(data, v)
        elif num == 2 and wt == 2:
            f["containing"] = _str(data, v)
        elif num == 4 and wt == 0:
            f["label"] = v
        elif num == 5 and wt == 0:
            f["type"] = v
        elif num == 6 and wt == 2:
            f["type_name"] = _str(data, v)
        elif num == 8 and wt == 2:
            # FieldOptions.features.field_presence == LEGACY_REQUIRED
            for n2, w2, v2 in _fields(data, o, v[0], v[1]):
                if n2 == 21 and w2 == 2:
                    for n3, w3, v3 in _fields(data, o, v2[0], v2[1]):
                        if n3 == 1 and w3 == 0 and v3 == 3:
                            f["required"] = True
    f["type_name"] = f["type_name"].removeprefix(".")
    if f["containing"] != None:
        f["containing"] = f["containing"].removeprefix(".")
    if f["label"] == 2:
        f["required"] = True
    return f

# ---------------------------------------------------------------- types

INT_TYPES = {3: True, 4: True, 5: True, 6: True, 7: True, 13: True, 15: True, 16: True, 17: True, 18: True}

def file_type(name):
    return con(FILE + "[" + repr(name) + "]")

def file_of(t):
    """The file name of a proto.FileDescriptor["name"] type, or None."""
    n = t["name"]
    if n.startswith(FILE + "[\"") and n.endswith("\"]"):
        return n[len(FILE) + 2:-2]
    return None

def kind(pool, t):
    """What the resolved type t is in the schema: "msg", "enum", or None."""
    if pool == None or t["k"] != "con" or t["args"]:
        return None
    if t["name"] in pool["msgs"]:
        return "msg"
    if t["name"] in pool["enums"]:
        return "enum"
    return None

def _scalar(pool, f):
    t = f["type"]
    if t == 0 and f["type_name"] != "":
        t = 11 if f["type_name"] in pool["msgs"] else 14
    if t == 1 or t == 2:
        return con("float")
    if t in INT_TYPES:
        return con("int")
    if t == 8:
        return con("bool")
    if t == 9:
        return con("str")
    if t == 12:
        return con("bytes")
    if t == 10 or t == 11 or t == 14:
        return con(f["type_name"])
    return T_ANY

def field_type(pool, f):
    """The type of the value read from field f."""
    if f["label"] == 3:
        m = pool["msgs"].get(f["type_name"])
        if m != None and m["map_entry"]:
            k = m["by_name"].get("key")
            v = m["by_name"].get("value")
            return con(MAP, [_scalar(pool, k) if k else T_ANY, _scalar(pool, v) if v else T_ANY])
        return con(REPEATED, [_scalar(pool, f)])
    return _scalar(pool, f)

def descriptor_type(pool, f):
    """The type of a field's descriptor (p.Msg.f)."""
    return con(FIELD, [con(f["containing"]) if f["containing"] else T_ANY, field_type(pool, f)])

def _member_type(pool, m):
    if m[0] == "ext":
        return descriptor_type(pool, m[1])
    return con(TYPE, [con(m[1])])

def members(pool, t):
    """[(name, type)] of what can follow "." after a value of the resolved
    type t (in dir() order), or None if t is not a proto type with known
    members."""
    if pool == None or t["k"] != "con":
        return None
    n = t["name"]
    if n == MODULE:
        return None  # (infer.star: from MEMBERS)
    fname = file_of(t)
    if fname != None:
        fd = pool["files"].get(fname)
        if fd == None:
            return None
        return sorted([(name, _member_type(pool, m)) for name, m in fd["members"].items()])
    if n == TYPE and len(t["args"]) == 1:
        a = resolve(t["args"][0])
        k = kind(pool, a)
        if k == "msg":
            m = pool["msgs"][a["name"]]
            out = [(name, _member_type(pool, x)) for name, x in m["members"].items()]
            out += [(f["name"], descriptor_type(pool, f)) for f in m["fields"] if f["name"] not in m["members"]]
            return sorted(out)
        if k == "enum":
            return sorted([(v, a) for v in pool["enums"][a["name"]]["values"]])
        return None
    k = kind(pool, t)
    if k == "msg":
        m = pool["msgs"][n]
        return sorted([("descriptor", con(TYPE, [t]))] + [(f["name"], field_type(pool, f)) for f in m["fields"]])
    if k == "enum":
        return [("index", con("int")), ("name", con("str")), ("number", con("int")), ("type", con(TYPE, [t]))]
    return None

def member(pool, t, name):
    """(the type of x.name for an x of resolved type t, None), or (None,
    the error), or (None, None) if t's members aren't known."""
    ms = members(pool, t)
    if ms == None:
        return None, None
    for n, mt in ms:
        if n == name:
            return mt, None
    from_ = show_proto(t)
    what = " field" if kind(pool, t) == "msg" else " member"
    h = nearest(name, [n for n, _ in ms])
    return None, from_ + " has no " + ("." + name + what) + (" (did you mean '" + h + "'?)" if h else "")

def message_field(pool, t, name):
    """The field `name` of the message type t, or None."""
    m = pool["msgs"].get(t["name"])
    return m["by_name"].get(name) if m != None else None

def show_proto(t):
    n = t["name"]
    if n == TYPE:
        return "type[" + resolve(t["args"][0])["name"] + "]"
    return n

def hint(name, cands):
    h = nearest(name, cands)
    return " (did you mean '" + h + "'?)" if h else ""

def as_struct(pool, t):
    """The message type t as the struct type of its fields (read-only):
    what a def that reads fields of a struct sees of a message."""
    m = pool["msgs"][t["name"]]
    items = [field(lit("descriptor"), con(TYPE, [t]))]
    items += [field(lit(f["name"]), field_type(pool, f)) for f in m["fields"]]
    return rec(row(items), t.get("at"))

# for the files that use all of it (stubs.star)
PB = struct(
    MODULE = MODULE,
    FILE = FILE,
    FIELD = FIELD,
    REPEATED = REPEATED,
    MAP = MAP,
    TYPE = TYPE,
    file_type = file_type,
    kind = kind,
    hint = hint,
)
