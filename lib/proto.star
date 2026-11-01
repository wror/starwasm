PROTO_PRELUDE = r'''# lib/proto.star - starlark-go's lib/proto module, written in Starlark.
#
# The compiler adds this to the prelude (lib/prelude.star) of programs that
# name `proto`, the predeclared module (codegen's lookup: _proto_module()).
# It behaves like go.starlark.net/lib/proto, which bin/starhost predeclares:
# the same values, operations, outputs and error messages. Its parts:
#
#   descriptors   The pool is the binary FileDescriptorSet given to the
#                 compiler (--descriptor_set; _pb_descriptor_set()), decoded
#                 here on the first proto.file() call: files, messages,
#                 fields, enums as plain dicts, with editions features
#                 resolved (presence, packed, delimited, UTF-8 checks).
#   values        Messages, repeated and map fields, and the descriptors are
#                 library objects (_obj_new; lib/builtins.star's _objects):
#                 the runtime sends every operation on them (type, str,
#                 x.f, x[i], x(...), len, iteration, ...) to _obj_dispatch.
#   wire format   proto.marshal / proto.unmarshal, on the byte-level
#                 primitives of lib/builtins.star (_wire): varints, fixed
#                 ints, floats.
#   text format   proto.marshal_text / proto.unmarshal_text, as protobuf-go's
#                 prototext (its tokenizer, ported).
#
# A message's state ("msg") is a list [descriptor, values, unknown, exts]:
# values maps field numbers to stored values (ints, floats, strings, bytes,
# bools, enum numbers, msgs, lists and dicts of those), unknown is a list of
# the raw bytes of unknown fields, exts maps the numbers of extension fields
# set to their descriptors. A Message value wraps a msg and a "frozen" cell
# ([bool]) shared by everything read through it, as in starlark-go, where
# several wrappers may share one underlying message.

_K_MODULE = 1
_K_FILE = 2
_K_MSGDESC = 3
_K_FIELDDESC = 4
_K_ENUMDESC = 5
_K_ENUMVAL = 6
_K_MESSAGE = 7
_K_METHOD = 8  # a bound builtin method (append): [name, receiver]
_K_STATE = 9
_K_REPEATED = 257  # _OBJ_ITERABLE: [field, list, frozen cell, iteration count cell]
_K_MAP = 769  # _OBJ_ITERABLE | _OBJ_MAPPING: [field, dict, frozen cell, iteration count cell]

# Operations of the dispatcher (OBJ_* in lib/runtime.star; _OBJ_* in lib/prelude.star)
_O_TYPE = 0
_O_STR = 1
_O_TRUTH = 2
_O_LEN = 3
_O_INDEX = 4
_O_SETINDEX = 5
_O_IN = 6
_O_ITER = 7
_O_ITRACK = 8
_O_HASH = 9
_O_EQ = 10
_O_CALL = 11
_O_CALLNAME = 12
_O_FREEZE = 13
_O_UNHASHABLE = 14
_O_ITEMS = 15
_O_ATTR = 16
_O_SETATTR = 17
_O_DIR = 18
_O_HASATTR = 19

# Mutable state lives in a library object: the prelude's own globals are
# frozen once it has run.
_PR_STATE = _obj_new(_K_STATE, {"pool": None})
_PR_MODULE = _obj_new(_K_MODULE, None)

def _proto_module():
    return _PR_MODULE

# FieldDescriptorProto.Type
_T_DOUBLE = 1
_T_FLOAT = 2
_T_INT64 = 3
_T_UINT64 = 4
_T_INT32 = 5
_T_FIXED64 = 6
_T_FIXED32 = 7
_T_BOOL = 8
_T_STRING = 9
_T_GROUP = 10
_T_MESSAGE = 11
_T_BYTES = 12
_T_UINT32 = 13
_T_ENUM = 14
_T_SFIXED32 = 15
_T_SFIXED64 = 16
_T_SINT32 = 17
_T_SINT64 = 18

_PR_TYPE_NAMES = [
    "", "double", "float", "int64", "uint64", "int32", "fixed64", "fixed32", "bool", "string",
    "group", "message", "bytes", "uint32", "enum", "sfixed32", "sfixed64", "sint32", "sint64",
]

# wire type of each type (unpacked)
_PR_WIRE = [0, 1, 5, 0, 0, 0, 1, 5, 0, 2, 3, 2, 2, 0, 0, 5, 1, 0, 0]

_PR_ERR_DECODE = "cannot parse invalid wire-format data"

# ---------------------------------------------------------------- descriptors

def _pr_raw(data):
    """The fields of an encoded message, as (number, wire type, value):
    an int for varint and fixed fields, bytes for length-delimited ones."""
    out = []
    i = 0
    n = len(data)
    for _ in range(n + 1):
        if i >= n:
            break
        tag, i = _pb_varint(data, i)
        if i < 0:
            fail("proto: invalid descriptor set")
        wt = tag & 7
        if wt == 0:
            v, i = _pb_varint(data, i)
        elif wt == 1:
            v, i = _pb_fixed64(data, i)
        elif wt == 2:
            ln, i = _pb_varint(data, i)
            if i < 0 or i + ln > n:
                fail("proto: invalid descriptor set")
            v = data[i:i + ln]
            i += ln
        elif wt == 5:
            v, i = _pb_fixed32(data, i)
        else:
            fail("proto: invalid descriptor set")
        if i < 0:
            fail("proto: invalid descriptor set")
        out.append((tag >> 3, wt, v))
    return out

def _pr_str(v):
    return _pb_bytes_str(v)

# Editions (FileDescriptorProto.edition) and their default features:
# [field presence, enum type, repeated field encoding, utf8 validation,
# message encoding] with the values of FeatureSet's enums.
_ED_PROTO2 = 998
_ED_PROTO3 = 999
_PR_PRESENCE_EXPLICIT = 1
_PR_PRESENCE_IMPLICIT = 2
_PR_PRESENCE_REQUIRED = 3

def _pr_edition_features(edition):
    if edition == _ED_PROTO2:
        return [1, 2, 2, 3, 1]
    if edition == _ED_PROTO3:
        return [2, 1, 1, 2, 1]
    return [1, 1, 1, 2, 1]

def _pr_features(parent, data):
    """parent's features, overridden by FeatureSet bytes data (or None)."""
    if data == None:
        return parent
    f = list(parent)
    for num, wt, v in _pr_raw(data):
        if num >= 1 and num <= 5 and wt == 0 and v != 0:
            f[num - 1] = v
    return f

def _pr_option(opts, num):
    """The last value of field num of options (a raw field list), or None."""
    r = None
    if opts != None:
        for n, _, v in opts:
            if n == num:
                r = v
    return r

def _pr_join(prefix, name):
    return name if prefix == "" else prefix + "." + name

def _pr_pool():
    st = _obj_data(_PR_STATE)
    if st["pool"] == None:
        st["pool"] = _pr_load(_pb_descriptor_set())
    return st["pool"]

def _pr_load(data):
    pool = {"files": {}, "types": {}, "fields": []}
    files = []
    for num, wt, v in _pr_raw(data):
        if num == 1 and wt == 2:
            files.append(_pr_file(pool, v))
    for f in pool["fields"]:
        _pr_link_field(pool, f)
    for f in pool["fields"]:
        _pr_finish_field(f)
    return pool

def _pr_file(pool, data):
    raw = _pr_raw(data)
    fd = {"k": "file", "name": "", "package": "", "syntax": "", "edition": 0, "messages": [], "enums": [], "exts": [],
          "msgs_by_name": {}, "enums_by_name": {}, "exts_by_name": {}}
    opts = None
    for num, wt, v in raw:
        if num == 1:
            fd["name"] = _pr_str(v)
        elif num == 2:
            fd["package"] = _pr_str(v)
        elif num == 12:
            fd["syntax"] = _pr_str(v)
        elif num == 14:
            fd["edition"] = v
        elif num == 8:
            opts = _pr_raw(v)
    if fd["syntax"] == "proto3":
        fd["edition"] = _ED_PROTO3
    elif fd["syntax"] != "editions":
        fd["syntax"] = "proto2"
        fd["edition"] = _ED_PROTO2
    fd["features"] = _pr_features(_pr_edition_features(fd["edition"]), _pr_option(opts, 50))
    for num, wt, v in raw:
        if num == 4:
            md = _pr_message(pool, fd, None, fd["package"], fd["features"], v)
            fd["messages"].append(md)
            fd["msgs_by_name"].setdefault(md["name"], md)
        elif num == 5:
            ed = _pr_enum(pool, fd, fd["package"], fd["features"], v)
            fd["enums"].append(ed)
            fd["enums_by_name"].setdefault(ed["name"], ed)
        elif num == 7:
            f = _pr_field(pool, fd, None, fd["package"], fd["features"], v, True, len(fd["exts"]))
            fd["exts"].append(f)
            fd["exts_by_name"].setdefault(f["name"], f)
    if fd["name"] not in pool["files"]:
        pool["files"][fd["name"]] = fd
    return fd

def _pr_message(pool, fd, parent, prefix, features, data):
    raw = _pr_raw(data)
    md = {"k": "msg", "name": "", "file": fd, "parent": parent, "fields": [], "by_name": {}, "by_num": {},
          "messages": [], "enums": [], "exts": [], "oneofs": [], "map_entry": False, "required": [],
          "reserved": {}, "ranges": [], "msgs_by_name": {}, "enums_by_name": {}, "exts_by_name": {}}
    opts = None
    for num, wt, v in raw:
        if num == 1:
            md["name"] = _pr_str(v)
        elif num == 7:
            opts = _pr_raw(v)
        elif num == 10:
            md["reserved"][_pr_str(v)] = True
        elif num == 5:
            r = _pr_raw(v)
            md["ranges"].append((_pr_option(r, 1), _pr_option(r, 2)))
    md["full"] = _pr_join(prefix, md["name"])
    md["map_entry"] = _pr_option(opts, 7) == 1
    md["features"] = _pr_features(features, _pr_option(opts, 12))
    pool["types"].setdefault(md["full"], md)
    for num, wt, v in raw:
        if num == 8:
            o = _pr_raw(v)
            oo = _pr_option(o, 2)
            od = {"name": _pr_str(_pr_option(o, 1)), "fields": [], "index": len(md["oneofs"]),
                  "features": _pr_features(md["features"], None if oo == None else _pr_option(_pr_raw(oo), 1))}
            od["full"] = md["full"] + "." + od["name"]
            md["oneofs"].append(od)
    for num, wt, v in raw:
        if num == 2:
            f = _pr_field(pool, fd, md, md["full"], md["features"], v, False, len(md["fields"]))
            md["fields"].append(f)
            md["by_name"].setdefault(f["name"], f)
            md["by_num"].setdefault(f["num"], f)
        elif num == 3:
            sub = _pr_message(pool, fd, md, md["full"], md["features"], v)
            md["messages"].append(sub)
            md["msgs_by_name"].setdefault(sub["name"], sub)
        elif num == 4:
            ed = _pr_enum(pool, fd, md["full"], md["features"], v)
            md["enums"].append(ed)
            md["enums_by_name"].setdefault(ed["name"], ed)
        elif num == 6:
            f = _pr_field(pool, fd, md, md["full"], md["features"], v, True, len(md["exts"]))
            md["exts"].append(f)
            md["exts_by_name"].setdefault(f["name"], f)
    return md

def _pr_enum(pool, fd, prefix, features, data):
    raw = _pr_raw(data)
    ed = {"k": "enum", "name": "", "file": fd, "values": [], "by_name": {}, "by_num": {}}
    opts = None
    for num, wt, v in raw:
        if num == 1:
            ed["name"] = _pr_str(v)
        elif num == 3:
            opts = _pr_raw(v)
    ed["full"] = _pr_join(prefix, ed["name"])
    ed["features"] = _pr_features(features, _pr_option(opts, 7))
    ed["closed"] = ed["features"][1] == 2
    for num, wt, v in raw:
        if num == 2:
            r = _pr_raw(v)
            n = _pr_option(r, 2)
            ev = {"k": "enumval", "name": _pr_str(_pr_option(r, 1) or b""), "num": 0 if n == None else _pb_int(n, 1),
                  "index": len(ed["values"]), "enum": ed}
            ed["values"].append(ev)
            ed["by_name"].setdefault(ev["name"], ev)
            ed["by_num"].setdefault(ev["num"], ev)
    pool["types"].setdefault(ed["full"], ed)
    return ed

def _pr_field(pool, fd, md, prefix, features, data, is_ext, index):
    raw = _pr_raw(data)
    f = {"k": "field", "name": "", "num": 0, "label": 1, "type": 0, "type_name": "", "extendee": "",
         "default_str": None, "oneof": None, "p3opt": False, "packed_opt": None, "is_ext": is_ext,
         "file": fd, "scope": md, "index": index, "msg": None, "enum": None, "containing": md}
    opts = None
    for num, wt, v in raw:
        if num == 1:
            f["name"] = _pr_str(v)
        elif num == 2:
            f["extendee"] = _pr_str(v)
        elif num == 3:
            f["num"] = v
        elif num == 4:
            f["label"] = v
        elif num == 5:
            f["type"] = v
        elif num == 6:
            f["type_name"] = _pr_str(v)
        elif num == 7:
            f["default_str"] = _pr_str(v)
        elif num == 8:
            opts = _pr_raw(v)
        elif num == 9:
            f["oneof"] = v
        elif num == 17:
            f["p3opt"] = v != 0
    f["full"] = _pr_join(prefix, f["name"])
    p = _pr_option(opts, 2)
    f["packed_opt"] = None if p == None else p != 0
    if f["oneof"] != None and md != None:
        od = md["oneofs"][f["oneof"]]
        f["oneof"] = od
        od["fields"].append(f)
        features = od["features"]
    f["features"] = _pr_features(features, _pr_option(opts, 21))
    pool["fields"].append(f)
    return f

def _pr_link_field(pool, f):
    """Resolve the field's types (all files are read by now)."""
    if f["type_name"] != "":
        t = pool["types"].get(f["type_name"][1:] if f["type_name"].startswith(".") else f["type_name"])
        if t != None and t["k"] == "msg":
            f["msg"] = t
            if f["type"] == 0:
                f["type"] = _T_MESSAGE
        elif t != None:
            f["enum"] = t
            if f["type"] == 0:
                f["type"] = _T_ENUM
    if f["is_ext"]:
        x = pool["types"].get(f["extendee"][1:] if f["extendee"].startswith(".") else f["extendee"])
        f["containing"] = x

def _pr_finish_field(f):
    """The derived properties of a field (after linking)."""
    t = f["type"]
    feat = f["features"]
    ed = f["file"]["edition"]
    md = f["msg"]
    f["repeated"] = f["label"] == 3
    f["is_map"] = f["repeated"] and md != None and md["map_entry"]
    f["is_list"] = f["repeated"] and not f["is_map"]
    if f["is_map"]:
        f["key"] = md["by_num"].get(1)
        f["value"] = md["by_num"].get(2)
    # delimited (group) encoding: proto2 groups, or the editions feature
    # (never for maps or map entries)
    group = t == _T_GROUP or (t == _T_MESSAGE and feat[4] == 2)
    if group and (f["is_map"] or (f["containing"] != None and f["containing"]["map_entry"])):
        group = False
    f["group"] = group
    f["is_msg"] = md != None
    if t == _T_GROUP:
        f["type"] = _T_MESSAGE
        t = _T_MESSAGE
    if f["label"] == 2 or (ed != _ED_PROTO2 and ed != _ED_PROTO3 and feat[0] == _PR_PRESENCE_REQUIRED):
        f["presence"] = "required"
    elif f["repeated"]:
        f["presence"] = None
    elif f["is_ext"] or f["is_msg"] or f["oneof"] != None:
        f["presence"] = "explicit"
    elif ed == _ED_PROTO3:
        f["presence"] = "explicit" if f["p3opt"] else "implicit"
    elif ed == _ED_PROTO2:
        f["presence"] = "explicit"
    else:
        f["presence"] = "implicit" if feat[0] == _PR_PRESENCE_IMPLICIT else "explicit"
    if f["presence"] == "required" and f["containing"] != None and not f["is_ext"]:
        f["containing"]["required"].append(f)
    scalar = t != _T_STRING and t != _T_BYTES and t != _T_MESSAGE
    if not f["repeated"] or not scalar:
        f["packed"] = False
    elif ed == _ED_PROTO2:
        f["packed"] = f["packed_opt"] == True
    elif ed == _ED_PROTO3:
        f["packed"] = f["packed_opt"] != False
    else:
        f["packed"] = feat[2] == 1 if f["packed_opt"] == None else f["packed_opt"]
    if t != _T_STRING:
        f["utf8"] = False
    elif ed == _ED_PROTO3:
        f["utf8"] = True
    elif ed == _ED_PROTO2:
        f["utf8"] = False
    else:
        f["utf8"] = feat[3] == 2
    f["default"] = _pr_default(f)
    # the text format's name: the group's type name for a group-like field
    name = f["name"]
    if f["is_ext"]:
        name = "[" + f["full"] + "]"
    elif group and md != None and md["name"].lower() == f["name"] and _identical(md["file"], f["file"]) and \
         _identical(md["parent"], f["containing"]):
        name = md["name"]
    f["text_name"] = name

def _pr_default(f):
    """The stored form of a field's default value."""
    t = f["type"]
    s = f["default_str"]
    if f["repeated"] or f["is_msg"]:
        return None
    if t == _T_ENUM:
        ed = f["enum"]
        if s != None and ed["by_name"].get(s) != None:
            return ed["by_name"][s]["num"]
        return ed["values"][0]["num"] if ed["values"] else 0
    if t == _T_BOOL:
        return s == "true"
    if t == _T_STRING:
        return "" if s == None else s
    if t == _T_BYTES:
        return b"" if s == None else _pr_unescape_bytes(s)
    if t == _T_DOUBLE or t == _T_FLOAT:
        if s == None:
            v = 0.0
        elif s == "inf":
            v = float("inf")
        elif s == "-inf":
            v = float("-inf")
        elif s == "nan":
            v = float("nan")
        else:
            v = float(s)
        return _f32(v) if t == _T_FLOAT else v
    return 0 if s == None else int(s)

_PR_ESCAPES = {"n": 10, "r": 13, "t": 9, "a": 7, "b": 8, "f": 12, "v": 11, "\\": 92, "'": 39, "\"": 34, "?": 63}

def _pr_unescape_bytes(s):
    """A default value of a bytes field: C escapes, as protoc writes them."""
    out = []
    b = list(s.elem_ords())
    i = 0
    n = len(b)
    for _ in range(n + 1):
        if i >= n:
            break
        c = b[i]
        if c != 92 or i + 1 >= n:
            out.append(c)
            i += 1
            continue
        e = b[i + 1]
        if e >= 48 and e <= 55:
            v = 0
            k = i + 1
            for _ in range(3):
                if k < n and b[k] >= 48 and b[k] <= 55:
                    v = v * 8 + b[k] - 48
                    k += 1
            out.append(v & 255)
            i = k
        elif e == 120:  # x
            v = 0
            k = i + 2
            for _ in range(2):
                if k < n and _pr_hexval(b[k]) >= 0:
                    v = v * 16 + _pr_hexval(b[k])
                    k += 1
            out.append(v)
            i = k
        else:
            out.append(_PR_ESCAPES.get(chr(e), e))
            i += 2
    return bytes(out)

def _pr_hexval(c):
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 97 and c <= 102:
        return c - 87
    if c >= 65 and c <= 70:
        return c - 55
    return -1

def _pr_typestr(f):
    """starlark-go's typeString: what a field holds."""
    if f["is_msg"]:
        return f["msg"]["full"]
    if f["type"] == _T_ENUM:
        return f["enum"]["full"]
    return _PR_TYPE_NAMES[f["type"]]

def _pr_is_group_kind(f):
    return f["group"]

# ---------------------------------------------------------------- messages

def _pr_new_msg(md):
    return [md, {}, [], {}]

def _pr_message_obj(msg, frozen):
    return _obj_new(_K_MESSAGE, [msg, frozen])

def _pr_field_of(msg, num):
    """The descriptor of populated field num of msg."""
    f = msg[3].get(num)
    return f if f != None else msg[0]["by_num"].get(num)

def _pr_zero(f, v):
    """v is the zero value of implicit-presence field f."""
    t = f["type"]
    if t == _T_DOUBLE or t == _T_FLOAT:
        return v == 0 and _float_text(v, 64) != "-0"
    if t == _T_STRING or t == _T_BYTES:
        return len(v) == 0
    if t == _T_BOOL:
        return not v
    return v == 0

def _pr_is_set(f, v):
    """dynamicpb's isSet: a populated field's value counts as present."""
    if f["repeated"]:
        return len(v) > 0
    if f["presence"] == "implicit":
        return not _pr_zero(f, v)
    return True

def _pr_has(msg, f):
    num = f["num"]
    if f["is_ext"]:
        if not _identical(msg[3].get(num), f):
            return False
    elif num in msg[3]:
        return False
    v = msg[1].get(num)
    if v == None:
        return False
    return _pr_is_set(f, v)

def _pr_populated(msg):
    """The present fields of msg, sorted by number: [(number, field)]."""
    out = []
    for num in sorted(msg[1].keys()):
        f = _pr_field_of(msg, num)
        if f != None and _pr_is_set(f, msg[1][num]):
            out.append((num, f))
    return out

def _pr_clear(msg, f):
    num = f["num"]
    msg[1].pop(num, None)
    msg[3].pop(num, None)

def _pr_clear_oneof(msg, f):
    od = f["oneof"]
    if od != None:
        for g in od["fields"]:
            if g["num"] != f["num"]:
                msg[1].pop(g["num"], None)

def _pr_set(msg, f, v):
    _pr_clear_oneof(msg, f)
    msg[1][f["num"]] = v
    if f["is_ext"]:
        msg[3][f["num"]] = f

def _pr_mutable(msg, f, make):
    """The stored list, dict or msg of field f, made by make() if absent."""
    num = f["num"]
    v = msg[1].get(num)
    if v != None and (not f["is_ext"] or _identical(msg[3].get(num), f)):
        return v
    _pr_clear_oneof(msg, f)
    v = make()
    msg[1][num] = v
    if f["is_ext"]:
        msg[3][num] = f
    return v

def _pr_to_value(f, v, frozen):
    """The Starlark value of stored value v of field f (toStarlark)."""
    if f["is_map"]:
        return _obj_new(_K_MAP, [f, v, frozen, [0]])
    if f["is_list"]:
        return _obj_new(_K_REPEATED, [f, v, frozen, [0]])
    return _pr_to_value1(f, v, frozen)

def _pr_to_value1(f, v, frozen):
    """The Starlark value of a stored scalar or element (toStarlark1)."""
    if f["is_msg"]:
        return _pr_message_obj(v, frozen)
    if f["type"] == _T_ENUM:
        return _pr_enumval_obj(f["enum"], v)
    return v

def _pr_enumval_obj(ed, num):
    ev = ed["by_num"].get(num)
    if ev == None:
        ev = {"k": "enumval", "name": str(num), "num": num, "index": -1, "enum": ed}
    return _obj_new(_K_ENUMVAL, ev)

def _pr_default_value(f):
    """The (frozen) value of field f when it is not set."""
    frozen = [True]
    if f["is_map"]:
        return _obj_new(_K_MAP, [f, {}, frozen, [0]])
    if f["is_list"]:
        return _obj_new(_K_REPEATED, [f, [], frozen, [0]])
    if f["is_msg"]:
        return _pr_message_obj(_pr_new_msg(f["msg"]), frozen)
    return _pr_to_value1(f, f["default"], frozen)

def _pr_get(msg, f, frozen):
    if _pr_has(msg, f):
        return _pr_to_value(f, msg[1][f["num"]], frozen)
    return _pr_default_value(f)

def _pr_enum_value_of(ed, x):
    """(enum value descriptor, None) for an int, string or enum value x, or (None, error)."""
    t = type(x)
    if t == "int":
        if x < -2147483648 or x > 2147483647:
            return None, "invalid number " + str(x) + " for " + ed["name"] + " enum"
        ev = ed["by_num"].get(x)
        if ev == None:
            return None, "invalid number " + str(x) + " for " + ed["name"] + " enum"
        return ev, None
    if t == "string":
        ev = ed["by_name"].get(x)
        if ev == None:
            return None, "invalid name " + repr(x) + " for " + ed["name"] + " enum"
        return ev, None
    if _obj_kind(x) == _K_ENUMVAL:
        ev = _obj_data(x)
        if not _identical(ev["enum"], ed):
            return None, "invalid value " + ev["enum"]["name"] + "." + ev["name"] + " for " + ed["name"] + " enum"
        return ev, None
    return None, "cannot convert " + t + " to " + ed["name"] + " enum"

_PR_INT32 = {_T_INT32: True, _T_SFIXED32: True, _T_SINT32: True}
_PR_INT64 = {_T_INT64: True, _T_SFIXED64: True, _T_SINT64: True}

def _pr_to_proto(f, v):
    """(stored value, None) for Starlark value v of field f (one element of
    a repeated field), or (None, error): toProto."""
    t = f["type"]
    tv = type(v)
    if t == _T_BOOL:
        if tv == "bool":
            return v, None
    elif t == _T_UINT32 or t == _T_FIXED32:
        if tv == "int":
            if v >= 0 and v <= 4294967295:
                return v, None
            return None, "invalid " + _pr_typestr(f) + ": " + str(v)
    elif t in _PR_INT32:
        if tv == "int":
            if v >= -2147483648 and v <= 2147483647:
                return v, None
            return None, "invalid " + _pr_typestr(f) + ": " + str(v)
    elif t == _T_UINT64 or t == _T_FIXED64:
        if tv == "int":
            if v >= 0 and v <= 18446744073709551615:
                return v, None
            return None, "invalid " + _pr_typestr(f) + ": " + str(v)
    elif t in _PR_INT64:
        if tv == "int":
            if v >= -9223372036854775808 and v <= 9223372036854775807:
                return v, None
            return None, "invalid " + _pr_typestr(f) + ": " + str(v)
    elif t == _T_STRING:
        if tv == "string":
            return v, None
        if tv == "bytes":
            return _pb_bytes_str(v), None
    elif t == _T_BYTES:
        if tv == "string":
            return _pb_str_bytes(v), None
        if tv == "bytes":
            return v, None
    elif t == _T_DOUBLE:
        if tv == "float":
            return v, None
        if tv == "int":
            return float(v), None
    elif t == _T_FLOAT:
        if tv == "float" or tv == "int":
            return _f32(v), None
    elif f["is_msg"]:
        md = f["msg"]
        if _obj_kind(v) == _K_MESSAGE:
            src = _obj_data(v)[0]
            if not _identical(src[0], md):
                return None, "got " + src[0]["full"] + ", want " + md["full"]
            return src, None  # alias it directly
        if tv == "dict":
            dest = _pr_new_msg(md)
            err = _pr_set_fields(dest, v.items())
            if err != None:
                return None, err
            return dest, None
    elif t == _T_ENUM:
        ev, err = _pr_enum_value_of(f["enum"], v)
        if err != None:
            return None, err
        return ev["num"], None
    return None, "got " + tv + ", want " + _pr_typestr(f)

def _pr_set_fields(msg, items):
    """msg.name = value for each (name, value) item: None, or an error."""
    md = msg[0]
    for item in items:
        name = item[0]
        if type(name) != "string":
            return "got " + type(name) + ", want string"
        f = md["by_name"].get(name)
        if f == None:
            return md["full"] + " has no ." + name + " field"
        err = _pr_set_field(msg, f, item[1])
        if err != None:
            return err
    return None

def _pr_mappable(v):
    return type(v) == "dict" or _obj_kind(v) == _K_MAP

def _pr_set_field(msg, f, v):
    """Assign Starlark value v to field f of msg (None clears it): None, or an error."""
    if v == None:
        _pr_clear(msg, f)
        return None
    if f["is_list"]:
        if not _is_iterable(v):
            return "got " + type(v) + " for ." + f["name"] + " field, want iterable"
        lst = _pr_mutable(msg, f, list)
        lst.clear()
        items = list(v)  # after the truncation, as starlark-go's iterator reads v live (r.x = r.x empties it)
        for i, x in enumerate(items):
            pv, err = _pr_to_proto(f, x)
            if err != None:
                return "index " + str(i) + ": " + err
            lst.append(pv)
        return None
    if f["is_map"]:
        if not _pr_mappable(v):
            return "in map field " + f["name"] + ": expected mappable type, but got " + type(v)
        keys = list(v)
        vals = [v[k] for k in keys]
        _pr_clear(msg, f)
        mp = _pr_mutable(msg, f, dict)
        for i, k in enumerate(keys):
            kp, err = _pr_to_proto(f["key"], k)
            if err != None:
                return "in key of map field " + f["name"] + ": " + err
            vp, err = _pr_to_proto(f["value"], vals[i])
            if err != None:
                return "in map field " + f["name"] + ", at key " + repr(k) + ": " + err
            mp[kp] = vp
        return None
    pv, err = _pr_to_proto(f, v)
    if err != None:
        return "in field " + f["name"] + ": " + err
    _pr_set(msg, f, pv)
    return None

def _pr_new(md, args, kwargs):
    """Calling a message descriptor: MessageDescriptor.CallInternal."""
    name = md["name"]
    dest = _pr_new_msg(md)
    items = [] if kwargs == None else kwargs.items()
    if args:
        if items:
            _error(name + ": got both positional and named arguments")
        if len(args) > 1:
            _error(name + ": got " + str(len(args)) + " positional arguments, want at most 1")
        src = args[0]
        if _obj_kind(src) == _K_MESSAGE:
            sm = _obj_data(src)[0]
            if not _identical(sm[0], md):
                _error(name + ": got message of type " + sm[0]["full"] + ", want type " + md["full"])
            for num, f in _pr_populated(sm):
                _pr_set(dest, f, sm[1][num])  # a shallow copy
            return _pr_message_obj(dest, [False])
        if type(src) != "dict":
            _error(name + ": got " + type(src) + ", want dict or message")
        items = src.items()
    err = _pr_set_fields(dest, items)
    if err != None:
        _error(err)
    return _pr_message_obj(dest, [False])

def _pr_value_str(f, v):
    """How starlark-go prints stored value v of field f."""
    if f["is_map"]:
        return "{" + ", ".join([_pr_value_str1(f["key"], k) + ": " + _pr_value_str1(f["value"], v[k]) for k in sorted(v.keys())]) + "}"
    if f["is_list"]:
        return "[" + ", ".join([_pr_value_str1(f, x) for x in v]) + "]"
    return _pr_value_str1(f, v)

def _pr_value_str1(f, v):
    if f["is_msg"]:
        return _pr_msg_str(v)
    if f["type"] == _T_ENUM:
        ev = f["enum"]["by_num"].get(v)
        return f["enum"]["name"] + "." + (str(v) if ev == None else ev["name"])
    return repr(v)

def _pr_msg_str(msg):
    parts = []
    for num, f in _pr_populated(msg):
        if f["is_ext"]:
            name = f["full"]
        elif f["group"]:
            name = f["msg"]["name"]
        else:
            name = f["name"]
        parts.append(name + "=" + _pr_value_str(f, msg[1][num]))
    return msg[0]["full"] + "(" + ", ".join(parts) + ")"

def _pr_check_initialized(msg):
    """None, or the error for a missing required field (proto.CheckInitialized)."""
    for f in msg[0]["required"]:
        if not _pr_has(msg, f):
            return "required field " + f["full"] + " not set"
    for num, f in _pr_populated(msg):
        v = msg[1][num]
        if f["is_map"]:
            if f["value"]["is_msg"]:
                for k in sorted(v.keys()):
                    err = _pr_check_initialized(v[k])
                    if err != None:
                        return err
        elif f["is_msg"]:
            for x in (v if f["is_list"] else [v]):
                err = _pr_check_initialized(x)
                if err != None:
                    return err
    return None

# ---------------------------------------------------------------- the dispatcher

def _pr_kind_type(k, d):
    if k == _K_MESSAGE:
        return "proto.Message"
    if k == _K_REPEATED:
        return "proto.repeated<" + _pr_typestr(d[0]) + ">"
    if k == _K_MAP:
        return "proto.map<" + _pr_typestr(d[0]["key"]) + ", " + _pr_typestr(d[0]["value"]) + ">"
    if k == _K_FILE:
        return "proto.FileDescriptor"
    if k == _K_MSGDESC:
        return "proto.MessageDescriptor"
    if k == _K_FIELDDESC:
        return "proto.FieldDescriptor"
    if k == _K_ENUMDESC:
        return "proto.EnumDescriptor"
    if k == _K_ENUMVAL:
        return "proto.EnumValueDescriptor"
    if k == _K_METHOD:
        return "builtin_function_or_method"
    if k == _K_MODULE:
        return "module"
    return "proto.state"

def _pr_kind_str(k, d):
    if k == _K_MESSAGE:
        return _pr_msg_str(d[0])
    if k == _K_REPEATED or k == _K_MAP:
        return _pr_value_str(d[0], d[1])
    if k == _K_FILE:
        return d["name"]
    if k == _K_MSGDESC or k == _K_FIELDDESC or k == _K_ENUMDESC:
        return d["full"]
    if k == _K_ENUMVAL:
        return d["enum"]["name"] + "." + d["name"]
    if k == _K_METHOD:
        return "<built-in method " + d[0] + " of " + type(d[1]) + " value>"
    if k == _K_MODULE:
        return "<module \"proto\">"
    return "<proto state>"

def _pr_check_mutable(d, verb, what):
    """None, or the error for changing a repeated or map field (verb: "append to")."""
    if d[2][0]:
        return "cannot " + verb + " frozen " + what + " field"
    if d[3][0] > 0:
        return "cannot " + verb + " " + what + " field during iteration"
    return None

def _pr_out_of_range(i, n, x):
    if n == 0:
        return "index " + str(i) + " out of range: empty " + type(x)
    return type(x) + " index " + str(i) + " out of range [" + str(-n) + ":" + str(n - 1) + "]"

def _pr_int32_err(i):
    """AsInt32's error for i, or None."""
    if type(i) != "int":
        return "got " + type(i) + ", want int"
    if i < -2147483648 or i > 2147483647:
        return str(i) + " out of range"
    return None

def _pr_map_get(d, key):
    """(found, value or error) for MapField.Get."""
    f = d[0]
    kp, err = _pr_to_proto(f["key"], key)
    if err != None:
        return False, "converting map key: " + err
    if kp not in d[1]:
        return False, None
    return True, _pr_to_value1(f["value"], d[1][kp], d[2])

def _pr_index(x, k, d, i):
    if k == _K_REPEATED:
        err = _pr_int32_err(i)
        if err != None:
            _error_plain(type(x) + " index: " + err)
        n = len(d[1])
        j = i + n if i < 0 else i
        if j < 0 or j >= n:
            _error_plain(_pr_out_of_range(i, n, x))
        return _pr_to_value1(d[0], d[1][j], d[2])
    if k == _K_MAP:
        found, v = _pr_map_get(d, i)
        if not found:
            if v != None:
                _error_plain(v)
            _error_plain("key " + repr(i) + " not in " + type(x))
        return v
    _error_plain("unhandled index operation " + type(x) + "[" + type(i) + "]")

def _pr_setindex(x, k, d, i, v):
    if k == _K_MAP:
        err = _pr_check_mutable(d, "insert into", "map")
        if err != None:
            _error_plain(err)
        f = d[0]
        kp, err = _pr_to_proto(f["key"], i)
        if err != None:
            _error_plain("converting map key: " + err)
        vp, err = _pr_to_proto(f["value"], v)
        if err != None:
            _error_plain("converting map value: " + err)
        d[1][kp] = vp
        return None
    if k == _K_REPEATED:
        err = _pr_int32_err(i)
        if err != None:
            _error_plain(err)
        n = len(d[1])
        j = i + n if i < 0 else i
        if j < 0 or j >= n:
            _error_plain(_pr_out_of_range(i, n, x))
        err = _pr_check_mutable(d, "insert into", "repeated")
        if err != None:
            _error_plain(err)
        pv, err = _pr_to_proto(d[0], v)
        if err != None:
            _error_plain("setting element of repeated field: " + err)
        d[1][j] = pv
        return None
    _error_plain(type(x) + " value does not support item assignment")

def _pr_attrs(k, d):
    """AttrNames of a value of kind k (sorted)."""
    if k == _K_MESSAGE:
        md = d[0][0]
        return sorted(["descriptor"] + [f["name"] for f in md["fields"]])
    if k == _K_FILE:
        return sorted([m["name"] for m in d["messages"]] + [f["name"] for f in d["exts"]] + [e["name"] for e in d["enums"]])
    if k == _K_MSGDESC:
        return sorted([m["name"] for m in d["messages"]] + [e["name"] for e in d["enums"]])
    if k == _K_ENUMDESC:
        return sorted([v["name"] for v in d["values"]])
    if k == _K_ENUMVAL:
        return ["index", "name", "number", "type"]
    if k == _K_REPEATED:
        return ["append"]
    if k == _K_MODULE:
        return sorted(_PR_MEMBERS.keys())
    return []

def _pr_attr(x, k, d, name):
    """(value, None) for x.name, or (None, error)."""
    if k == _K_MESSAGE:
        md = d[0][0]
        if name == "descriptor":
            return _obj_new(_K_MSGDESC, md), None
        f = md["by_name"].get(name)
        if f == None:
            return None, md["full"] + " has no ." + name + " field" + _attr_hint(_pr_attrs(k, d), name)
        return _pr_get(d[0], f, d[1]), None
    v = None
    if k == _K_FILE:
        if name in d["msgs_by_name"]:
            v = _obj_new(_K_MSGDESC, d["msgs_by_name"][name])
        elif name in d["exts_by_name"]:
            v = _obj_new(_K_FIELDDESC, d["exts_by_name"][name])
        elif name in d["enums_by_name"]:
            v = _obj_new(_K_ENUMDESC, d["enums_by_name"][name])
    elif k == _K_MSGDESC:
        if name in d["msgs_by_name"]:
            v = _obj_new(_K_MSGDESC, d["msgs_by_name"][name])
        elif name in d["exts_by_name"]:
            v = _obj_new(_K_FIELDDESC, d["exts_by_name"][name])
        elif name in d["by_name"]:
            v = _obj_new(_K_FIELDDESC, d["by_name"][name])
        elif name in d["enums_by_name"]:
            v = _obj_new(_K_ENUMDESC, d["enums_by_name"][name])
    elif k == _K_ENUMDESC:
        if name in d["by_name"]:
            v = _obj_new(_K_ENUMVAL, d["by_name"][name])
    elif k == _K_ENUMVAL:
        if name == "index":
            v = d["index"]
        elif name == "name":
            v = d["name"]
        elif name == "number":
            v = d["num"]
        elif name == "type":
            v = _obj_new(_K_ENUMDESC, d["enum"])
    elif k == _K_REPEATED:
        if name == "append":
            v = _obj_new(_K_METHOD, ["append", x])
    elif k == _K_MODULE:
        v = _PR_MEMBERS.get(name)
    if v != None:
        return v, None
    return None, type(x) + " has no ." + name + " field or method" + _attr_hint(_pr_attrs(k, d), name)

def _pr_setattr(x, k, d, name, v):
    if k != _K_MESSAGE:
        _error_plain("can't assign to ." + name + " field of " + type(x))
    msg = d[0]
    md = msg[0]
    f = md["by_name"].get(name)
    if f == None:
        _error_plain(md["full"] + " has no ." + name + " field" + _attr_hint(_pr_attrs(k, d), name))
    if d[1][0]:
        _error_plain("cannot set ." + name + " field of frozen " + md["full"] + " message")
    err = _pr_set_field(msg, f, v)
    if err != None:
        _error_plain(err)
    return None

def _pr_call(x, k, d, args, kwargs):
    if k == _K_MSGDESC:
        return _pr_new(d, args, kwargs)
    if k == _K_ENUMDESC:
        name = d["name"]
        if kwargs:
            _error(name + ": unexpected keyword arguments")
        if len(args) != 1:
            _error(name + ": got " + str(len(args)) + " arguments, want 1")
        ev, err = _pr_enum_value_of(d, args[0])
        if err != None:
            _error(name + ": " + err)
        return _obj_new(_K_ENUMVAL, ev)
    if k == _K_METHOD:  # append
        if kwargs:
            _error("append: unexpected keyword arguments")
        if len(args) != 1:
            _error("append: got " + str(len(args)) + " arguments, want 1")
        rd = _obj_data(d[1])
        err = _pr_check_mutable(rd, "append to", "repeated")
        if err != None:
            _error(err)
        pv, err = _pr_to_proto(rd[0], args[0])
        if err != None:
            _error("appending to repeated field: " + err)
        rd[1].append(pv)
        return None
    _error_plain("invalid call of non-function (" + type(x) + ")")

def _pr_eq(k, d, y):
    if _obj_kind(y) != k:
        return False
    if k == _K_FILE or k == _K_MSGDESC or k == _K_FIELDDESC or k == _K_ENUMDESC or k == _K_ENUMVAL:
        return _identical(d, _obj_data(y))
    return False

def _pr_hash(x, k, d):
    if k == _K_MESSAGE:
        return _obj_id(x)
    if k == _K_FILE:
        return hash(d["name"])
    if k == _K_MSGDESC or k == _K_FIELDDESC:
        return hash(d["full"])
    if k == _K_ENUMDESC:
        return 0
    if k == _K_ENUMVAL:
        return d["num"]
    if k == _K_METHOD:
        return hash(d[0]) ^ 5521
    _error_plain("unhashable: " + type(x))

def _obj_dispatch(op, x, a, b):
    """Every operation on a proto value (see _objects in lib/builtins.star)."""
    k = _obj_kind(x)
    d = _obj_data(x)
    if op == _O_ATTR:
        v, err = _pr_attr(x, k, d, a)
        if b != None:
            return (err == None, v if err == None else err)
        if err != None:
            _error_plain(err)
        return v
    if op == _O_TYPE:
        return _pr_kind_type(k, d)
    if op == _O_STR:
        return _pr_kind_str(k, d)
    if op == _O_CALL:
        return _pr_call(x, k, d, a, b)
    if op == _O_CALLNAME:
        if k == _K_MSGDESC or k == _K_ENUMDESC:
            return d["name"]
        if k == _K_METHOD:
            return d[0]
        return None
    if op == _O_SETATTR:
        return _pr_setattr(x, k, d, a, b)
    if op == _O_TRUTH:
        if k == _K_REPEATED or k == _K_MAP:
            return len(d[1]) > 0
        return True
    if op == _O_LEN:
        if k == _K_REPEATED or k == _K_MAP:
            return len(d[1])
        return None
    if op == _O_INDEX:
        return _pr_index(x, k, d, a)
    if op == _O_SETINDEX:
        return _pr_setindex(x, k, d, a, b)
    if op == _O_ITER:
        if k == _K_REPEATED:
            return tuple([_pr_to_value1(d[0], v, d[2]) for v in d[1]])
        if k == _K_MAP:
            return tuple([_pr_to_value1(d[0]["key"], v, d[2]) for v in sorted(d[1].keys())])
        return None
    if op == _O_ITRACK:
        if (k == _K_REPEATED or k == _K_MAP) and not d[2][0]:
            d[3][0] += a // 2
        return None
    if op == _O_IN:
        if k == _K_MAP:
            found, _ = _pr_map_get(d, a)
            return found
        _error_plain("unknown binary op: " + type(a) + " in " + type(x))
    if op == _O_EQ:
        return _pr_eq(k, d, a)
    if op == _O_HASH:
        return _pr_hash(x, k, d)
    if op == _O_UNHASHABLE:
        if k == _K_REPEATED or k == _K_MAP or k == _K_MODULE:
            return type(x)
        return None
    if op == _O_FREEZE:
        if k == _K_MESSAGE:
            d[1][0] = True
        elif k == _K_REPEATED or k == _K_MAP:
            d[2][0] = True
        return None
    if op == _O_ITEMS:
        f = d[0]
        return [(_pr_to_value1(f["key"], kk, d[2]), _pr_to_value1(f["value"], d[1][kk], d[2])) for kk in sorted(d[1].keys())]
    if op == _O_DIR:
        return _pr_attrs(k, d)
    if op == _O_HASATTR:
        if k == _K_MAP or k == _K_METHOD:
            return False
        v, err = _pr_attr(x, k, d, a)
        return err == None or a in _pr_attrs(k, d)
    _error_plain("internal error: proto operation " + str(op))

# ---------------------------------------------------------------- the module

def _pr_want_message(fn, i, x):
    if _obj_kind(x) != _K_MESSAGE:
        _error(fn + ": for parameter " + str(i) + ": got " + type(x) + ", want proto.Message")
    return _obj_data(x)

def _pr_want_kind(fn, i, x, k, what):
    if _obj_kind(x) != k:
        _error(fn + ": for parameter " + str(i) + ": got " + type(x) + ", want " + what)
    return _obj_data(x)

def _mod_proto__file(filename):
    if type(filename) != "string":
        _error("proto.file: for parameter 1: got " + type(filename) + ", want string")
    fd = _pr_pool()["files"].get(filename)
    if fd == None:
        _error("proto: not found")
    return _obj_new(_K_FILE, fd)

def _mod_proto__has(msg, field):
    if _obj_kind(msg) != _K_MESSAGE:
        _error("proto.has: got " + type(msg) + ", want proto.Message")
    m = _obj_data(msg)[0]
    md = m[0]
    if type(field) == "string":
        f = md["by_name"].get(field)
        if f == None:
            _error(md["full"] + " has no ." + field + " field")
    elif _obj_kind(field) == _K_FIELDDESC:
        f = _obj_data(field)
        if not _identical(f["containing"], md):
            _error("proto.has: " + md["full"] + " does not have field " + f["full"])
    else:
        _error("proto.has: for field argument, got " + type(field) + ", want string or proto.FieldDescriptor")
    return _pr_has(m, f)

def _mod_proto__get_field(msg, field):
    d = _pr_want_message("proto.get_field", 1, msg)
    f = _pr_want_kind("proto.get_field", 2, field, _K_FIELDDESC, "proto.FieldDescriptor")
    md = d[0][0]
    if not _identical(f["containing"], md):
        _error("proto.get_field: " + md["full"] + " does not have field " + f["full"])
    return _pr_get(d[0], f, d[1])

def _mod_proto__set_field(msg, field, v):
    d = _pr_want_message("proto.set_field", 1, msg)
    f = _pr_want_kind("proto.set_field", 2, field, _K_FIELDDESC, "proto.FieldDescriptor")
    md = d[0][0]
    if d[1][0]:
        _error("proto.set_field: cannot set " + f["full"] + " field of frozen " + md["full"] + " message")
    if not _identical(f["containing"], md):
        _error("proto.set_field: " + md["full"] + " does not have field " + f["full"])
    err = _pr_set_field(d[0], f, v)
    if err != None:
        _error(err)
    return None

def _mod_proto__marshal(msg):
    d = _pr_want_message("proto.marshal", 1, msg)
    buf = _pb_buf()
    err = _pr_encode(buf, d[0])
    if err == None:
        err = _pr_check_initialized(d[0])
    if err != None:
        _error("proto.marshal: proto: " + err)
    return _pb_buf_bytes(buf)

def _mod_proto__marshal_text(msg):
    d = _pr_want_message("proto.marshal_text", 1, msg)
    e = {"out": [], "last": 0, "indent": ""}
    err = _px_message(e, d[0])
    if err == None:
        err = _pr_check_initialized(d[0])
    if err != None:
        _error("proto.marshal_text: proto: " + err)
    if e["out"]:
        e["out"].append("\n")
    return "".join(e["out"])

def _mod_proto__unmarshal(desc, data):
    md = _pr_want_kind("proto.unmarshal", 1, desc, _K_MSGDESC, "proto.MessageDescriptor")
    if type(data) != "bytes":
        _error("proto.unmarshal: for parameter 2: got " + type(data) + ", want bytes")
    msg = _pr_new_msg(md)
    err = _pr_decode(msg, data, 0, len(data), 0)
    if err == None:
        err = _pr_check_initialized(msg)
    if err != None:
        _error("unmarshalling " + md["full"] + " failed: proto: " + err)
    return _pr_message_obj(msg, [False])

def _mod_proto__unmarshal_text(desc, data):
    md = _pr_want_kind("proto.unmarshal_text", 1, desc, _K_MSGDESC, "proto.MessageDescriptor")
    if type(data) != "string":
        _error("proto.unmarshal_text: for parameter 2: got " + type(data) + ", want string")
    msg = _pr_new_msg(md)
    err = _pt_unmarshal(msg, data)
    if err == None:
        err = _pr_check_initialized(msg)
    if err != None:
        _error("unmarshalling " + md["full"] + " failed: proto: " + err)
    return _pr_message_obj(msg, [False])

_PR_MEMBERS = {
    "file": _mod_proto__file,
    "get_field": _mod_proto__get_field,
    "has": _mod_proto__has,
    "marshal": _mod_proto__marshal,
    "marshal_text": _mod_proto__marshal_text,
    "set_field": _mod_proto__set_field,
    "unmarshal": _mod_proto__unmarshal,
    "unmarshal_text": _mod_proto__unmarshal_text,
}

# ---------------------------------------------------------------- the wire format

def _pr_tag(buf, num, wt):
    _pb_put_varint(buf, (num << 3) | wt, False)

def _pr_encode(buf, msg):
    """Append msg's encoding to buf (fields in number order, then unknown
    fields): None, or an error."""
    for num, f in _pr_populated(msg):
        err = _pr_encode_field(buf, f, msg[1][num])
        if err != None:
            return err
    for u in msg[2]:
        _pb_put_bytes(buf, u)
    return None

def _pr_encode_field(buf, f, v):
    num = f["num"]
    if f["is_map"]:
        kf = f["key"]
        vf = f["value"]
        for k in sorted(v.keys()):  # deterministic (protobuf-go's order is random)
            sub = _pb_buf()
            err = _pr_encode_one(sub, kf, k)
            if err == None:
                err = _pr_encode_one(sub, vf, v[k])
            if err != None:
                return err
            _pr_tag(buf, num, 2)
            _pb_put_varint(buf, _pb_buf_len(sub), False)
            _pb_put_buf(buf, sub)
        return None
    if f["is_list"]:
        if f["packed"]:
            sub = _pb_buf()
            for x in v:
                _pr_encode_value(sub, f, x)
            _pr_tag(buf, num, 2)
            _pb_put_varint(buf, _pb_buf_len(sub), False)
            _pb_put_buf(buf, sub)
            return None
        for x in v:
            err = _pr_encode_one(buf, f, x)
            if err != None:
                return err
        return None
    return _pr_encode_one(buf, f, v)

def _pr_encode_one(buf, f, v):
    """Tag and value of one value of field f."""
    num = f["num"]
    if f["is_msg"]:
        if f["group"]:
            _pr_tag(buf, num, 3)
            err = _pr_encode(buf, v)
            _pr_tag(buf, num, 4)
            return err
        sub = _pb_buf()
        err = _pr_encode(sub, v)
        if err != None:
            return err
        _pr_tag(buf, num, 2)
        _pb_put_varint(buf, _pb_buf_len(sub), False)
        _pb_put_buf(buf, sub)
        return None
    t = f["type"]
    _pr_tag(buf, num, _PR_WIRE[t])
    if t == _T_STRING or t == _T_BYTES:
        if f["utf8"] and not _pb_utf8_ok(v):
            return "field " + f["full"] + " contains invalid UTF-8"
        _pb_put_varint(buf, len(v), False)
        _pb_put_bytes(buf, v)
        return None
    _pr_encode_value(buf, f, v)
    return None

def _pr_encode_value(buf, f, v):
    """The value of a scalar (no tag)."""
    t = f["type"]
    if t == _T_INT32 or t == _T_INT64 or t == _T_UINT32 or t == _T_UINT64 or t == _T_ENUM:
        _pb_put_varint(buf, v, False)
    elif t == _T_SINT32 or t == _T_SINT64:
        _pb_put_varint(buf, v, True)
    elif t == _T_BOOL:
        _pb_put_varint(buf, 1 if v else 0, False)
    elif t == _T_FIXED32 or t == _T_SFIXED32:
        _pb_put_fixed32(buf, v)
    elif t == _T_FIXED64 or t == _T_SFIXED64:
        _pb_put_fixed64(buf, v)
    elif t == _T_FLOAT:
        _pb_put_float(buf, v)
    elif t == _T_DOUBLE:
        _pb_put_double(buf, v)

def _pr_skip(num, wt, data, i, end, depth):
    """The end of the field value starting at data[i] (ConsumeFieldValue), or -1."""
    if wt == 0:
        _, j = _pb_varint(data, i)
        return j if j <= end else -1
    if wt == 1:
        return i + 8 if i + 8 <= end else -1
    if wt == 5:
        return i + 4 if i + 4 <= end else -1
    if wt == 2:
        n, j = _pb_varint(data, i)
        if j < 0 or j + n > end:
            return -1
        return j + n
    if wt == 3:
        if depth > 10000:
            return -1
        for _ in range(end - i + 1):
            if i >= end:
                return -1
            tag, j = _pb_varint(data, i)
            if j < 0 or j > end or tag >> 3 == 0:
                return -1
            if tag & 7 == 4:
                return j if tag >> 3 == num else -1
            i = _pr_skip(tag >> 3, tag & 7, data, j, end, depth + 1)
            if i < 0:
                return -1
        return -1
    return -1

def _pr_decode_scalar(f, wt, data, i, end):
    """(stored value, next position, error) of a scalar of field f at
    data[i]; error "unknown" if the wire type doesn't fit."""
    t = f["type"]
    want = _PR_WIRE[t]
    if wt != want:
        return None, i, "unknown"
    if want == 0:
        u, j = _pb_varint(data, i)
        if j < 0 or j > end:
            return None, i, _PR_ERR_DECODE
        if t == _T_BOOL:
            return u != 0, j, None
        if t == _T_INT32 or t == _T_ENUM:
            return _pb_int(u, 1), j, None
        if t == _T_INT64:
            return _pb_int(u, 0), j, None
        if t == _T_UINT32:
            return _pb_int(u, 2), j, None
        if t == _T_SINT32:
            return _pb_int(u & 4294967295, 3), j, None
        if t == _T_SINT64:
            return _pb_int(u, 3), j, None
        return u, j, None  # uint64
    if want == 5:
        if t == _T_FLOAT:
            v, j = _pb_float(data, i)
        else:
            v, j = _pb_fixed32(data, i)
            if t == _T_SFIXED32 and j >= 0:
                v = _pb_int(v, 1)
        if j < 0 or j > end:
            return None, i, _PR_ERR_DECODE
        return v, j, None
    if want == 1:
        if t == _T_DOUBLE:
            v, j = _pb_double(data, i)
        else:
            v, j = _pb_fixed64(data, i)
            if t == _T_SFIXED64 and j >= 0:
                v = _pb_int(v, 0)
        if j < 0 or j > end:
            return None, i, _PR_ERR_DECODE
        return v, j, None
    # strings and bytes
    n, j = _pb_varint(data, i)
    if j < 0 or j + n > end:
        return None, i, _PR_ERR_DECODE
    v = data[j:j + n]
    if t == _T_STRING:
        if f["utf8"] and not _pb_utf8_ok(v):
            return None, i, "field " + f["full"] + " contains invalid UTF-8"
        v = _pb_bytes_str(v)
    return v, j + n, None

def _pr_decode_msgbytes(f, wt, data, i, end):
    """(start, end, next position, error) of the encoded message of field f at data[i]."""
    if f["group"]:
        if wt != 3:
            return 0, 0, i, "unknown"
        k = _pr_skip(f["num"], 3, data, i, end, 0)
        if k < 0:
            return 0, 0, i, _PR_ERR_DECODE
        # the content ends before the END_GROUP tag
        tl = 1
        for _ in range(10):
            if (f["num"] << 3 | 4) < (1 << (7 * tl)):
                break
            tl += 1
        return i, k - tl, k, None
    if wt != 2:
        return 0, 0, i, "unknown"
    n, j = _pb_varint(data, i)
    if j < 0 or j + n > end:
        return 0, 0, i, _PR_ERR_DECODE
    return j, j + n, j + n, None

def _pr_decode(msg, data, start, end, depth):
    """Merge the encoded message data[start:end] into msg: None, or an error."""
    md = msg[0]
    i = start
    for _ in range(end - start + 1):
        if i >= end:
            break
        tag, j = _pb_varint(data, i)
        if j < 0 or j > end:
            return _PR_ERR_DECODE
        num = tag >> 3
        wt = tag & 7
        if num == 0 or num > 536870911:
            return _PR_ERR_DECODE
        f = md["by_num"].get(num)  # extensions aren't found (as with protobuf-go's global registry)
        err = "unknown"
        k = j
        if f != None:
            k, err = _pr_decode_field(msg, f, wt, data, j, end, depth)
        if err == "unknown":
            k = _pr_skip(num, wt, data, j, end, depth)
            if k < 0:
                return _PR_ERR_DECODE
            msg[2].append(data[i:k])
        elif err != None:
            return err
        i = k
    return None

def _pr_decode_field(msg, f, wt, data, i, end, depth):
    """(next position, error) for a value of field f at data[i]."""
    if depth > 10000:
        return i, "exceeded maximum recursion depth"
    if f["is_map"]:
        if wt != 2:
            return i, "unknown"
        n, j = _pb_varint(data, i)
        if j < 0 or j + n > end:
            return i, _PR_ERR_DECODE
        e = j + n
        kf = f["key"]
        vf = f["value"]
        key = None
        val = None
        if vf["is_msg"]:
            val = _pr_new_msg(vf["msg"])
        for _ in range(e - j + 1):
            if j >= e:
                break
            tag, j2 = _pb_varint(data, j)
            if j2 < 0 or j2 > e:
                return i, _PR_ERR_DECODE
            num = tag >> 3
            ewt = tag & 7
            if num == 0 or num > 536870911:
                return i, _PR_ERR_DECODE
            err = "unknown"
            k = j2
            if num == 1:
                v, k, err = _pr_decode_scalar(kf, ewt, data, j2, e)
                if err == None:
                    key = v
            elif num == 2:
                if vf["is_msg"]:
                    s, se, k, err = _pr_decode_msgbytes(vf, ewt, data, j2, e)
                    if err == None:
                        err = _pr_decode(val, data, s, se, depth + 1)
                else:
                    v, k, err = _pr_decode_scalar(vf, ewt, data, j2, e)
                    if err == None:
                        val = v
            if err == "unknown":
                k = _pr_skip(num, ewt, data, j2, e, depth)
                if k < 0:
                    return i, _PR_ERR_DECODE
            elif err != None:
                return i, err
            j = k
        if key == None:
            key = kf["default"]
        if val == None:
            val = vf["default"]
        _pr_mutable(msg, f, dict)[key] = val
        return e, None
    if f["is_msg"]:
        s, se, k, err = _pr_decode_msgbytes(f, wt, data, i, end)
        if err != None:
            return i, err
        if f["is_list"]:
            m = _pr_new_msg(f["msg"])
            err = _pr_decode(m, data, s, se, depth + 1)
            _pr_mutable(msg, f, list).append(m)
        else:
            m = _pr_mutable(msg, f, lambda: _pr_new_msg(f["msg"]))
            err = _pr_decode(m, data, s, se, depth + 1)
        return k, err
    if f["is_list"]:
        t = f["type"]
        if wt == 2 and t != _T_STRING and t != _T_BYTES:
            # packed
            n, j = _pb_varint(data, i)
            if j < 0 or j + n > end:
                return i, _PR_ERR_DECODE
            e = j + n
            lst = _pr_mutable(msg, f, list)
            ewt = _PR_WIRE[t]
            for _ in range(e - j + 1):
                if j >= e:
                    break
                v, j, err = _pr_decode_scalar(f, ewt, data, j, e)
                if err != None:
                    return i, err
                lst.append(v)
            return e, None
        v, k, err = _pr_decode_scalar(f, wt, data, i, end)
        if err != None:
            return i, err
        _pr_mutable(msg, f, list).append(v)
        return k, None
    v, k, err = _pr_decode_scalar(f, wt, data, i, end)
    if err != None:
        return i, err
    _pr_set(msg, f, v)
    return k, None

# ---------------------------------------------------------------- the text format: output
#
# protobuf-go's prototext.MarshalOptions{Indent: "  "} (internal/encoding/text's
# Encoder): fields in declaration order, extensions by name, map entries by key.

_PX_NAME = 1
_PX_SCALAR = 2
_PX_OPEN = 3
_PX_CLOSE = 4

def _px_prep(e, nxt):
    last = e["last"]
    if last == _PX_NAME:
        e["out"].append(" ")
    elif last == _PX_OPEN and nxt != _PX_CLOSE:
        e["indent"] += "  "
        e["out"].append("\n" + e["indent"])
    elif last == _PX_SCALAR or last == _PX_CLOSE:
        if nxt == _PX_CLOSE:
            e["indent"] = e["indent"][:-2]
        e["out"].append("\n" + e["indent"])
    e["last"] = nxt

def _px_name(e, s):
    _px_prep(e, _PX_NAME)
    e["out"].append(s + ":")

def _px_scalar(e, s):
    _px_prep(e, _PX_SCALAR)
    e["out"].append(s)

def _px_message(e, msg):
    regular = []
    exts = []
    for num, f in _pr_populated(msg):
        if f["is_ext"]:
            exts.append((f["full"], f))
        else:
            regular.append((f["index"], f))
    for _, f in sorted(regular) + sorted(exts):
        err = _px_field(e, f, msg[1][f["num"]])
        if err != None:
            return err
    return None

def _px_field(e, f, v):
    name = f["text_name"]
    if f["is_map"]:
        for k in sorted(v.keys()):
            _px_name(e, name)
            _px_prep(e, _PX_OPEN)
            e["out"].append("{")
            _px_name(e, "key")
            err = _px_singular(e, f["key"], k)
            if err == None:
                _px_name(e, "value")
                err = _px_singular(e, f["value"], v[k])
            _px_prep(e, _PX_CLOSE)
            e["out"].append("}")
            if err != None:
                return err
        return None
    if f["is_list"]:
        for x in v:
            _px_name(e, name)
            err = _px_singular(e, f, x)
            if err != None:
                return err
        return None
    _px_name(e, name)
    return _px_singular(e, f, v)

def _px_singular(e, f, v):
    t = f["type"]
    if f["is_msg"]:
        _px_prep(e, _PX_OPEN)
        e["out"].append("{")
        err = _px_message(e, v)
        _px_prep(e, _PX_CLOSE)
        e["out"].append("}")
        return err
    if t == _T_BOOL:
        _px_scalar(e, "true" if v else "false")
    elif t == _T_STRING:
        if f["utf8"] and not _pb_utf8_ok(v):
            return "field " + f["full"] + " contains invalid UTF-8"
        _px_scalar(e, _px_quote(v))
    elif t == _T_BYTES:
        _px_scalar(e, _px_quote(_pb_bytes_str(v)))
    elif t == _T_FLOAT:
        _px_scalar(e, _float_text(v, 32))
    elif t == _T_DOUBLE:
        _px_scalar(e, _float_text(v, 64))
    elif t == _T_ENUM:
        ev = f["enum"]["by_num"].get(v)
        _px_scalar(e, str(v) if ev == None else ev["name"])
    else:
        _px_scalar(e, str(v))
    return None

_PX_HEX = "0123456789abcdef"

def _px_quote(s):
    """A string in the text format's quotes (appendString)."""
    out = ["\""]
    n = len(s)
    i = 0
    for _ in range(n + 1):
        if i >= n:
            break
        k = _pt_rune_len(s, i, n)
        if k <= 1:
            c = s[i]
            b = list(c.elem_ords())[0]
            if b >= 128 or b < 32 or b == 127:
                if b == 10:
                    out.append("\\n")
                elif b == 13:
                    out.append("\\r")
                elif b == 9:
                    out.append("\\t")
                else:
                    out.append("\\x" + _PX_HEX[b >> 4] + _PX_HEX[b & 15])
            elif c == "\"" or c == "\\":
                out.append("\\" + c)
            else:
                out.append(c)
            i += 1
        else:
            c = s[i:i + k]
            r = ord(c)
            if r <= 0x9f:
                out.append("\\u00" + _PX_HEX[r >> 4] + _PX_HEX[r & 15])
            else:
                out.append(c)
            i += k
    out.append("\"")
    return "".join(out)

# ---------------------------------------------------------------- the text format: input
#
# protobuf-go's prototext.Unmarshal, with internal/encoding/text's Decoder
# ported: the same tokens, the same acceptance and the same error messages.
# Errors are returned (without the "proto: " prefix), never raised.

_PT_BOF = 0
_PT_EOF = 1
_PT_NAME = 2
_PT_SCALAR = 3
_PT_MOPEN = 4
_PT_MCLOSE = 5
_PT_LOPEN = 6
_PT_LCLOSE = 7
_PT_COMMA = 8
_PT_SEMI = 9

_PT_IDENT = 1
_PT_TYPENAME = 2
_PT_FIELDNUM = 3

_PT_NUMBER = 1
_PT_STRING = 2
_PT_LITERAL = 3

_PT_DEC = 1
_PT_HEXN = 2
_PT_OCT = 4
_PT_FLOATN = 8

_PT_EOF_ERR = "unexpected EOF"

def _pt_unmarshal(msg, s):
    d = {"s": s, "n": len(s), "i": 0, "stack": [], "peeked": False, "last": {"kind": _PT_BOF}, "lasterr": None}
    return _pt_message(d, msg, False)

def _pt_position(d, idx):
    b = d["s"][:idx]
    line = b.count("\n") + 1
    k = b.rfind("\n")
    if k >= 0:
        b = b[k + 1:]
    return "(line " + str(line) + ":" + str(len(list(b.codepoints())) + 1) + ")"

def _pt_new_error(d, pos, msg):
    return _pt_position(d, pos) + ": " + msg

def _pt_syntax_error(d, pos, msg):
    return "syntax error " + _pt_position(d, pos) + ": " + msg

def _pt_unexpected(d, tok):
    return _pt_syntax_error(d, tok["pos"], "unexpected token: " + tok["raw"])

def _pt_consume(d, n):
    s = d["s"]
    i = d["i"] + n
    end = d["n"]
    for _ in range(end - i + 1):
        if i >= end:
            break
        c = s[i]
        if c == " " or c == "\n" or c == "\r" or c == "\t":
            i += 1
        elif c == "#":
            k = s.find("\n", i)
            i = end if k < 0 else k + 1
        else:
            break
    d["i"] = i

def _pt_skip_ws(s, i, end):
    for _ in range(end - i + 1):
        if i >= end:
            break
        c = s[i]
        if c == " " or c == "\n" or c == "\r" or c == "\t":
            i += 1
        elif c == "#":
            k = s.find("\n", i)
            i = end if k < 0 else k + 1
        else:
            break
    return i

def _pt_tok(d, kind, size, attrs = 0):
    i = d["i"]
    tok = {"kind": kind, "pos": i, "raw": d["s"][i:i + size], "attrs": attrs, "sep": False, "str": ""}
    _pt_consume(d, size)
    return tok

def _pt_peek(d):
    if not d["peeked"]:
        d["last"], d["lasterr"] = _pt_read_next(d)
        d["peeked"] = True
    return d["last"], d["lasterr"]

def _pt_read(d):
    if d["peeked"]:
        d["peeked"] = False
        return d["last"], d["lasterr"]
    tok, err = _pt_read_next(d)
    if err == None:
        d["last"] = tok
    return tok, err

def _pt_read_next(d):
    tok, err = _pt_parse_next(d, d["last"]["kind"])
    if err != None:
        return {"kind": _PT_BOF}, err
    if tok["kind"] == _PT_COMMA or tok["kind"] == _PT_SEMI:
        tok, err = _pt_parse_next(d, tok["kind"])
        if err != None:
            return {"kind": _PT_BOF}, err
    return tok, None

def _pt_open_kind(d):
    if not d["stack"]:
        return _PT_BOF, ""
    c = d["stack"][-1]
    if c == "{":
        return _PT_MOPEN, "}"
    if c == "<":
        return _PT_MOPEN, ">"
    return _PT_LOPEN, "]"

_PT_OTHER_CLOSE = {"}": ">", ">": "}"}

def _pt_char_err(fmt, c):
    return fmt + " " + repr(c).replace("\"", "'") if len(c) == 1 and c != "'" else fmt + " '\\''"

def _pt_parse_next(d, last):
    _pt_consume(d, 0)
    eof = d["i"] >= d["n"]
    c = "" if eof else d["s"][d["i"]]
    if last == _PT_EOF:
        return _pt_tok(d, _PT_EOF, 0), None
    if last == _PT_BOF:
        if eof:
            return _pt_tok(d, _PT_EOF, 0), None
        return _pt_parse_field_name(d)
    if last == _PT_NAME:
        if eof:
            return None, _PT_EOF_ERR
        if c == "{" or c == "<":
            d["stack"].append(c)
            return _pt_tok(d, _PT_MOPEN, 1), None
        if c == "[":
            d["stack"].append(c)
            return _pt_tok(d, _PT_LOPEN, 1), None
        return _pt_parse_scalar(d)
    if last == _PT_MOPEN:
        if eof:
            return None, _PT_EOF_ERR
        _, close = _pt_open_kind(d)
        if c == close:
            d["stack"].pop()
            return _pt_tok(d, _PT_MCLOSE, 1), None
        if c == _PT_OTHER_CLOSE.get(close):
            return None, _pt_syntax_error(d, d["i"], _pt_char_err("mismatched close character", c))
        return _pt_parse_field_name(d)
    if last == _PT_LOPEN:
        if eof:
            return None, _PT_EOF_ERR
        if c == "]":
            d["stack"].pop()
            return _pt_tok(d, _PT_LCLOSE, 1), None
        if c == "{" or c == "<":
            d["stack"].append(c)
            return _pt_tok(d, _PT_MOPEN, 1), None
        return _pt_parse_scalar(d)
    ok, close = _pt_open_kind(d)
    if last == _PT_COMMA or last == _PT_SEMI:
        if ok == _PT_BOF:
            if eof:
                return _pt_tok(d, _PT_EOF, 0), None
            return _pt_parse_field_name(d)
        if ok == _PT_MOPEN:
            if eof:
                return None, _PT_EOF_ERR
            if c == close:
                d["stack"].pop()
                return _pt_tok(d, _PT_MCLOSE, 1), None
            if c == _PT_OTHER_CLOSE.get(close):
                return None, _pt_syntax_error(d, d["i"], _pt_char_err("mismatched close character", c))
            return _pt_parse_field_name(d)
        if last == _PT_COMMA:  # in a list
            if eof:
                return None, _PT_EOF_ERR
            if c == "{" or c == "<":
                d["stack"].append(c)
                return _pt_tok(d, _PT_MOPEN, 1), None
            return _pt_parse_scalar(d)
        return None, _pt_syntax_error(d, d["i"], _pt_char_err("unexpected character", c))
    # after a scalar, a message's or a list's end
    if ok == _PT_BOF:
        if eof:
            return _pt_tok(d, _PT_EOF, 0), None
        if c == ",":
            return _pt_tok(d, _PT_COMMA, 1), None
        if c == ";":
            return _pt_tok(d, _PT_SEMI, 1), None
        return _pt_parse_field_name(d)
    if ok == _PT_MOPEN:
        if eof:
            return None, _PT_EOF_ERR
        if c == close:
            d["stack"].pop()
            return _pt_tok(d, _PT_MCLOSE, 1), None
        if c == _PT_OTHER_CLOSE.get(close):
            return None, _pt_syntax_error(d, d["i"], _pt_char_err("mismatched close character", c))
        if c == ",":
            return _pt_tok(d, _PT_COMMA, 1), None
        if c == ";":
            return _pt_tok(d, _PT_SEMI, 1), None
        return _pt_parse_field_name(d)
    # in a list
    if eof:
        return None, _PT_EOF_ERR
    if c == "]":
        d["stack"].pop()
        return _pt_tok(d, _PT_LCLOSE, 1), None
    if c == ",":
        return _pt_tok(d, _PT_COMMA, 1), None
    return None, _pt_syntax_error(d, d["i"], _pt_char_err("unexpected character", c))

def _pt_is_delim(c):
    return not (c == "-" or c == "+" or c == "." or c == "_" or (c >= "a" and c <= "z") or
                (c >= "A" and c <= "Z") or (c >= "0" and c <= "9"))

def _pt_ident(s, i, end, allow_neg):
    """parseIdent: the size of the identifier at s[i], or 0."""
    size = 0
    if i >= end:
        return 0
    if allow_neg and s[i] == "-":
        i += 1
        size += 1
        if i >= end:
            return 0
    c = s[i]
    if not (c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z")):
        return 0
    i += 1
    size += 1
    for _ in range(end - i + 1):
        if i >= end:
            break
        c = s[i]
        if not (c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9")):
            break
        i += 1
        size += 1
    if i < end and not _pt_is_delim(s[i]):
        return 0
    return size

def _pt_digits(s, i, end, chars):
    k = i
    for _ in range(end - i + 1):
        if k >= end or s[k] not in chars:
            break
        k += 1
    return k - i

def _pt_number(s, i, end):
    """parseNumber: {kind, neg, size, sep} of the number at s[i]; size 0 if none."""
    none = {"size": 0}
    kind = _PT_DEC
    size = 0
    neg = False
    sep = 0
    if i >= end:
        return none
    if s[i] == "-":
        neg = True
        i += 1
        size += 1
        j = _pt_skip_ws(s, i, end)
        sep = j - i
        size += sep
        i = j
        if i >= end:
            return none
    c = s[i]
    if c == "0":
        if i + 1 < end:
            c1 = s[i + 1]
            if c1 == "x" or c1 == "X":
                n = 2 + _pt_digits(s, i + 2, end, "0123456789abcdefABCDEF")
                if n == 2:
                    return none
                if i + n < end and not _pt_is_delim(s[i + n]):
                    return none
                return {"kind": _PT_HEXN, "neg": neg, "size": size + n, "sep": sep}
            if c1 >= "0" and c1 <= "7":
                n = 2 + _pt_digits(s, i + 2, end, "01234567")
                if i + n < end and not _pt_is_delim(s[i + n]):
                    return none
                return {"kind": _PT_OCT, "neg": neg, "size": size + n, "sep": sep}
        i += 1
        size += 1
    elif c >= "1" and c <= "9":
        n = 1 + _pt_digits(s, i + 1, end, "0123456789")
        i += n
        size += n
    elif c == ".":
        kind = _PT_FLOATN
    else:
        return none
    if i < end and s[i] == ".":
        i += 1
        if i >= end and kind == _PT_FLOATN:
            return none
        n = 1 + _pt_digits(s, i, end, "0123456789")
        i += n - 1
        size += n
        kind = _PT_FLOATN
    if i + 1 < end and (s[i] == "e" or s[i] == "E"):
        kind = _PT_FLOATN
        i += 1
        n = 1
        if s[i] == "+" or s[i] == "-":
            i += 1
            n += 1
            if i >= end:
                return none
        k = _pt_digits(s, i, end, "0123456789")
        i += k
        n += k
        size += n
    if i < end and (s[i] == "f" or s[i] == "F"):
        kind = _PT_FLOATN
        i += 1
        size += 1
    if i < end and not _pt_is_delim(s[i]):
        return none
    return {"kind": kind, "neg": neg, "size": size, "sep": sep}

def _pt_number_str(s, i, num):
    """number.string: the number's text, without an f suffix or the space after "-"."""
    size = num["size"]
    t = s[i:i + size]
    if num["kind"] == _PT_FLOATN and (t.endswith("f") or t.endswith("F")):
        t = t[:-1]
    if num["neg"] and num["sep"] > 0:
        t = "-" + t[1 + num["sep"]:]
    return t

def _pt_err_id(s):
    """errId: the start of s, for messages."""
    i = 0
    cps = list(s.codepoints())
    out = []
    for c in cps:
        if i > 32:
            return "".join(out) + "…"
        if len(c) > 1 or (c != "/" and _pt_is_delim(c)):
            if i == 0:
                return c
            return "".join(out)
        out.append(c)
        i += len(c)
    return s

def _pt_parse_field_name(d):
    tok, err = _pt_parse_field_name1(d)
    if err == None and d["i"] < d["n"] and d["s"][d["i"]] == ":":
        _pt_consume(d, 1)
        tok["sep"] = True
    return tok, err

def _pt_parse_field_name1(d):
    s = d["s"]
    i = d["i"]
    if s[i] == "[":
        return _pt_parse_type_name(d)
    size = _pt_ident(s, i, d["n"], False)
    if size > 0:
        return _pt_tok(d, _PT_NAME, size, _PT_IDENT), None
    num = _pt_number(s, i, d["n"])
    if num["size"] > 0:
        t = _pt_number_str(s, i, num)
        if not num["neg"] and num["kind"] == _PT_DEC and len(t) <= 10 and int(t) <= 2147483647:
            return _pt_tok(d, _PT_NAME, num["size"], _PT_FIELDNUM), None
        return None, _pt_syntax_error(d, i, "invalid field number: " + t)
    return None, _pt_syntax_error(d, i, "invalid field name: " + _pt_err_id(s[i:]))

def _pt_url_extra(c):
    return c in ".~!$&()*+,;="

def _pt_type_name_char(c):
    return c == "-" or c == "_" or (c >= "0" and c <= "9") or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z")

def _pt_parse_type_name(d):
    s = d["s"]
    end = d["n"]
    start = d["i"]
    i = _pt_skip_ws(s, start + 1, end)
    if i >= end:
        return None, _PT_EOF_ERR
    name = []
    closed = False
    for _ in range(end - i + 1):
        if i >= end or closed:
            break
        c = s[i]
        if c == "]":
            i += 1
            closed = True
        elif c == "/" or _pt_type_name_char(c) or _pt_url_extra(c):
            name.append(c)
            i = _pt_skip_ws(s, i + 1, end)
        elif c == "%":
            if i + 2 >= end or _pr_hexval(ord(s[i + 1])) < 0 or _pr_hexval(ord(s[i + 2])) < 0:
                return None, _pt_syntax_error(d, start, "invalid type URL/extension field name: " + s[start:min(i + 3, end)])
            name.append(s[i:i + 3])
            i = _pt_skip_ws(s, i + 3, end)
        else:
            return None, _pt_syntax_error(d, start, "invalid type URL/extension field name: " + s[start:i + 1])
    if not closed:
        return None, _PT_EOF_ERR
    full = "".join(name)
    tname = full
    k = full.rfind("/")
    if k >= 0:
        if full.startswith("/"):
            return None, _pt_syntax_error(d, start, "invalid type URL/extension field name: " + s[start:i])
        tname = full[k + 1:]
    for part in tname.split("."):
        if part == "":
            return None, _pt_syntax_error(d, start, "invalid type URL/extension field name: " + s[start:i])
    for c in tname.elems():
        if c == "%" or (c != "." and _pt_url_extra(c)):
            return None, _pt_syntax_error(d, start, "invalid type URL/extension field name: " + s[start:i])
    tok = {"kind": _PT_NAME, "pos": start, "raw": s[start:i], "attrs": _PT_TYPENAME, "sep": False, "str": full}
    d["i"] = i
    _pt_consume(d, 0)
    return tok, None

def _pt_parse_scalar(d):
    s = d["s"]
    i = d["i"]
    if s[i] == "\"" or s[i] == "'":
        return _pt_parse_strings(d)
    size = _pt_ident(s, i, d["n"], True)
    if size > 0:
        return _pt_tok(d, _PT_SCALAR, size, _PT_LITERAL), None
    num = _pt_number(s, i, d["n"])
    if num["size"] > 0:
        tok = {"kind": _PT_SCALAR, "pos": i, "raw": s[i:i + num["size"]], "attrs": _PT_NUMBER, "sep": False,
               "str": _pt_number_str(s, i, num), "neg": num["neg"], "numkind": num["kind"]}
        _pt_consume(d, num["size"])
        return tok, None
    return None, _pt_syntax_error(d, i, "invalid scalar value: " + _pt_err_id(s[i:]))

def _pt_parse_strings(d):
    s = d["s"]
    start = d["i"]
    parts = []
    for _ in range(d["n"] + 1):
        i = d["i"]
        if i >= d["n"] or (s[i] != "\"" and s[i] != "'"):
            break
        v, err = _pt_parse_string(d)
        if err != None:
            return None, err
        parts.append(v)
    return {"kind": _PT_SCALAR, "pos": start, "raw": s[start:d["i"]], "attrs": _PT_STRING, "sep": False,
            "str": "".join(parts)}, None

_PT_SIMPLE_ESC = {"\"": "\"", "'": "'", "\\": "\\", "?": "?", "a": "\x07", "b": "\x08", "n": "\n", "r": "\r",
                  "t": "\t", "v": "\x0b", "f": "\x0c"}

def _pt_byte(v):
    return _pb_bytes_str(bytes([v]))

def _pt_parse_string(d):
    s = d["s"]
    end = d["n"]
    i = d["i"]
    quote = s[i]
    i += 1
    out = []
    for _ in range(end - i + 2):
        if i >= end:
            break
        c = s[i]
        # one code point (or an invalid byte)
        n = _pt_rune_len(s, i, end)
        if n == 0:
            return None, _pt_syntax_error(d, d["i"], "invalid UTF-8 detected")
        if c == "\x00" or c == "\n":
            return None, _pt_syntax_error(d, d["i"], "invalid character " + ("'\\x00'" if c == "\x00" else "'\\n'") + " in string")
        if c == quote:
            d["i"] = i
            _pt_consume(d, 1)
            return "".join(out), None
        if c == "\\":
            if i + 1 >= end:
                return None, _PT_EOF_ERR
            e = s[i + 1]
            if e in _PT_SIMPLE_ESC:
                out.append(_PT_SIMPLE_ESC[e])
                i += 2
            elif e >= "0" and e <= "7":
                m = _pt_digits(s, i + 1, end, "01234567")
                if m > 3:
                    m = 3
                v = int(s[i + 1:i + 1 + m], 8)
                if v > 255:
                    return None, _pt_syntax_error(d, d["i"], "invalid octal escape code " + repr(s[i:i + 1 + m]) + " in string")
                out.append(_pt_byte(v))
                i += 1 + m
            elif e == "x":
                m = _pt_digits(s, i + 2, end, "0123456789abcdefABCDEF")
                if m > 2:
                    m = 2
                if m == 0:
                    return None, _pt_syntax_error(d, d["i"], "invalid hex escape code " + repr(s[i:i + 2]) + " in string")
                out.append(_pt_byte(int(s[i + 2:i + 2 + m], 16)))
                i += 2 + m
            elif e == "u" or e == "U":
                m = 6 if e == "u" else 10
                if i + m > end:
                    return None, _PT_EOF_ERR
                h = s[i + 2:i + m]
                v = _parse_int(h, 16) if _pt_digits(h, 0, len(h), "0123456789abcdefABCDEF") == len(h) else None
                if v == None or v > 0x10ffff:
                    return None, _pt_syntax_error(d, d["i"], "invalid Unicode escape code " + repr(s[i:i + m]) + " in string")
                i += m
                if v >= 0xd800 and v < 0xe000:
                    if i + 6 > end:
                        return None, _PT_EOF_ERR
                    h2 = s[i + 2:i + 6]
                    v2 = _parse_int(h2, 16) if _pt_digits(h2, 0, 4, "0123456789abcdefABCDEF") == 4 else None
                    if s[i:i + 2] != "\\u" or v2 == None or v >= 0xdc00 or v2 < 0xdc00 or v2 >= 0xe000:
                        return None, _pt_syntax_error(d, d["i"], "invalid Unicode escape code " + repr(s[i:i + 6]) + " in string")
                    v = 0x10000 + ((v - 0xd800) << 10) + (v2 - 0xdc00)
                    i += 6
                out.append(chr(v))
            else:
                return None, _pt_syntax_error(d, d["i"], "invalid escape code " + repr(s[i:i + 2]) + " in string")
        else:
            out.append(s[i:i + n])
            i += n
    return None, _PT_EOF_ERR

def _pt_rune_len(s, i, end):
    """The length of the UTF-8 sequence at s[i], or 0 if it is invalid."""
    b = list(s[i:min(i + 4, end)].elem_ords())
    c = b[0]
    if c < 0x80:
        return 1
    n = 0
    if c >= 0xc2 and c <= 0xdf:
        n = 2
    elif c >= 0xe0 and c <= 0xef:
        n = 3
    elif c >= 0xf0 and c <= 0xf4:
        n = 4
    else:
        return 0
    if len(b) < n:
        return 0
    return n if _pb_utf8_ok(s[i:i + n]) else 0

# Token values (Token.Bool, Int32, ...): the value, or None.

def _pt_tok_bool(tok):
    if tok["kind"] != _PT_SCALAR:
        return None
    if tok["attrs"] == _PT_LITERAL:
        return {"t": True, "true": True, "True": True, "f": False, "false": False, "False": False}.get(tok["raw"])
    if tok["attrs"] == _PT_NUMBER:
        n = _pt_parse_int_str(tok["str"])
        if n == 0:
            return False
        if n == 1:
            return True
    return None

def _pt_parse_int_str(t):
    """strconv.ParseInt(t, 0, 64)'s value (any size), or None."""
    neg = t.startswith("-")
    if neg or t.startswith("+"):
        t = t[1:]
    if t.startswith("0x") or t.startswith("0X"):
        v = _parse_int(t[2:], 16)
    elif len(t) > 1 and t.startswith("0"):
        v = _parse_int(t[1:], 8)
    else:
        v = _parse_int(t, 10)
    if v == None:
        return None
    return -v if neg else v

def _pt_tok_int(tok, lo, hi):
    if tok["kind"] != _PT_SCALAR or tok["attrs"] != _PT_NUMBER or tok["numkind"] == _PT_FLOATN:
        return None
    if lo == 0 and tok["neg"]:
        return None
    v = _pt_parse_int_str(tok["str"])
    if v == None or v < lo or v > hi:
        return None
    return v

def _pt_tok_float(tok, bits):
    if tok["kind"] != _PT_SCALAR:
        return None
    v = None
    if tok["attrs"] == _PT_LITERAL:
        v = {"nan": float("nan"), "inf": float("inf"), "infinity": float("inf"), "-inf": float("-inf"),
             "-infinity": float("-inf")}.get(tok["raw"].lower())
    elif tok["attrs"] == _PT_NUMBER:
        t = tok["str"]
        if tok["numkind"] == _PT_HEXN:
            return None
        if tok["numkind"] == _PT_OCT:
            t = t.replace("-0", "-", 1) if t.startswith("-") else t
        v = float(t)
    if v == None:
        return None
    return _f32(v) if bits == 32 else v

def _pt_scalar(d, f):
    """(stored value, error) of the next scalar of field f (unmarshalScalar)."""
    tok, err = _pt_read(d)
    if err != None:
        return None, err
    if tok["kind"] != _PT_SCALAR:
        return None, _pt_unexpected(d, tok)
    t = f["type"]
    v = None
    if t == _T_BOOL:
        v = _pt_tok_bool(tok)
    elif t in _PR_INT32:
        v = _pt_tok_int(tok, -2147483648, 2147483647)
    elif t in _PR_INT64:
        v = _pt_tok_int(tok, -9223372036854775808, 9223372036854775807)
    elif t == _T_UINT32 or t == _T_FIXED32:
        v = _pt_tok_int(tok, 0, 4294967295)
    elif t == _T_UINT64 or t == _T_FIXED64:
        v = _pt_tok_int(tok, 0, 18446744073709551615)
    elif t == _T_FLOAT:
        v = _pt_tok_float(tok, 32)
    elif t == _T_DOUBLE:
        v = _pt_tok_float(tok, 64)
    elif t == _T_STRING:
        if tok["attrs"] == _PT_STRING:
            if f["utf8"] and not _pb_utf8_ok(tok["str"]):
                return None, _pt_new_error(d, tok["pos"], "contains invalid UTF-8")
            v = tok["str"]
    elif t == _T_BYTES:
        if tok["attrs"] == _PT_STRING:
            v = _pb_str_bytes(tok["str"])
    elif t == _T_ENUM:
        if tok["attrs"] == _PT_LITERAL and not tok["raw"].startswith("-"):
            ev = f["enum"]["by_name"].get(tok["raw"])
            if ev != None:
                v = ev["num"]
        if v == None:
            v = _pt_tok_int(tok, -2147483648, 2147483647)
    if v == None:
        return None, _pt_new_error(d, tok["pos"], "invalid value for " + _PR_TYPE_NAMES[t] + " type: " + tok["raw"])
    return v, None

def _pt_message(d, msg, delims):
    """unmarshalMessage: read fields into msg (delims: inside { })."""
    md = msg[0]
    if delims:
        tok, err = _pt_read(d)
        if err != None:
            return err
        if tok["kind"] != _PT_MOPEN:
            return _pt_unexpected(d, tok)
    seen = {}
    seen_oneofs = {}
    for _ in range(d["n"] + 2):
        tok, err = _pt_read(d)
        if err != None:
            return err
        k = tok["kind"]
        if k == _PT_EOF:
            if delims:
                return _PT_EOF_ERR
            return None
        if k != _PT_NAME:
            if delims and k == _PT_MCLOSE:
                return None
            return _pt_unexpected(d, tok)
        f = None
        name = ""
        by_number = False
        if tok["attrs"] == _PT_IDENT:
            name = tok["raw"]
            f = _pt_by_text_name(md, name)
        elif tok["attrs"] == _PT_FIELDNUM:
            by_number = True
            num = int(tok["raw"])
            if num < 1 or num > 536870911:
                return _pt_new_error(d, tok["pos"], "invalid field number: " + str(num))
            f = md["by_num"].get(num)
        # extensions ([name]) aren't found (as with protobuf-go's global registry)
        if f == None:
            if name in md["reserved"]:
                _pt_skip_value(d)
                continue
            return _pt_new_error(d, tok["pos"], "unknown field: " + tok["raw"])
        if by_number:
            return _pt_new_error(d, tok["pos"], "cannot specify field by number: " + tok["raw"])
        if f["is_list"]:
            if not f["is_msg"] and not tok["sep"]:
                return _pt_syntax_error(d, tok["pos"], "missing field separator :")
            err = _pt_list(d, f, _pr_mutable(msg, f, list))
        elif f["is_map"]:
            err = _pt_map(d, f, _pr_mutable(msg, f, dict))
        else:
            if not f["is_msg"] and not tok["sep"]:
                return _pt_syntax_error(d, tok["pos"], "missing field separator :")
            od = f["oneof"]
            if od != None:
                if od["index"] in seen_oneofs:
                    return _pt_new_error(d, tok["pos"], "error parsing " + repr(tok["raw"]) + ", oneof " + od["full"] + " is already set")
                seen_oneofs[od["index"]] = True
            if f["num"] in seen:
                return _pt_new_error(d, tok["pos"], "non-repeated field " + repr(tok["raw"]) + " is repeated")
            if f["is_msg"]:
                v = _pr_new_msg(f["msg"])
                err = _pt_message(d, v, True)
            else:
                v, err = _pt_scalar(d, f)
            if err == None:
                _pr_set(msg, f, v)
                seen[f["num"]] = True
        if err != None:
            return err
    return _PT_EOF_ERR

def _pt_by_text_name(md, name):
    """Fields.ByTextName: by the text name, and a group-like field's in lower case too."""
    bt = md.get("by_text")
    if bt == None:
        bt = {}
        for f in md["fields"]:
            bt.setdefault(f["text_name"], f)
            if f["text_name"] != f["name"]:  # group-like
                bt.setdefault(f["text_name"].lower(), f)
        md["by_text"] = bt
    return bt.get(name)

def _pt_list(d, f, lst):
    tok, err = _pt_peek(d)
    if err != None:
        return err
    k = tok["kind"]
    if f["is_msg"]:
        if k == _PT_LOPEN:
            _pt_read(d)
            for _ in range(d["n"] + 2):
                tok, err = _pt_peek(d)
                if err != None:
                    return err
                if tok["kind"] == _PT_LCLOSE:
                    _pt_read(d)
                    return None
                if tok["kind"] != _PT_MOPEN:
                    return _pt_unexpected(d, tok)
                m = _pr_new_msg(f["msg"])
                err = _pt_message(d, m, True)
                if err != None:
                    return err
                lst.append(m)
        elif k == _PT_MOPEN:
            m = _pr_new_msg(f["msg"])
            err = _pt_message(d, m, True)
            if err != None:
                return err
            lst.append(m)
            return None
    else:
        if k == _PT_LOPEN:
            _pt_read(d)
            for _ in range(d["n"] + 2):
                tok, err = _pt_peek(d)
                if err != None:
                    return err
                if tok["kind"] == _PT_LCLOSE:
                    _pt_read(d)
                    return None
                if tok["kind"] != _PT_SCALAR:
                    return _pt_unexpected(d, tok)
                v, err = _pt_scalar(d, f)
                if err != None:
                    return err
                lst.append(v)
        elif k == _PT_SCALAR:
            v, err = _pt_scalar(d, f)
            if err != None:
                return err
            lst.append(v)
            return None
    return _pt_unexpected(d, tok)

def _pt_map(d, f, mp):
    tok, err = _pt_read(d)
    if err != None:
        return err
    if tok["kind"] == _PT_MOPEN:
        return _pt_map_entry(d, f, mp)
    if tok["kind"] == _PT_LOPEN:
        for _ in range(d["n"] + 2):
            tok, err = _pt_read(d)
            if err != None:
                return err
            if tok["kind"] == _PT_LCLOSE:
                return None
            if tok["kind"] != _PT_MOPEN:
                return _pt_unexpected(d, tok)
            err = _pt_map_entry(d, f, mp)
            if err != None:
                return err
    return _pt_unexpected(d, tok)

def _pt_map_entry(d, f, mp):
    kf = f["key"]
    vf = f["value"]
    key = None
    val = None
    for _ in range(d["n"] + 2):
        tok, err = _pt_read(d)
        if err != None:
            return err
        if tok["kind"] == _PT_MCLOSE:
            break
        if tok["kind"] != _PT_NAME:
            return _pt_unexpected(d, tok)
        if tok["attrs"] != _PT_IDENT:
            return _pt_new_error(d, tok["pos"], "unknown map entry field " + repr(tok["raw"]))
        name = tok["raw"]
        if name == "key":
            if not tok["sep"]:
                return _pt_syntax_error(d, tok["pos"], "missing field separator :")
            if key != None:
                return _pt_new_error(d, tok["pos"], "map entry \"key\" cannot be repeated")
            key, err = _pt_scalar(d, kf)
            if err != None:
                return err
        elif name == "value":
            if not vf["is_msg"] and not tok["sep"]:
                return _pt_syntax_error(d, tok["pos"], "missing field separator :")
            if val != None:
                return _pt_new_error(d, tok["pos"], "map entry \"value\" cannot be repeated")
            if vf["is_msg"]:
                val = _pr_new_msg(vf["msg"])
                err = _pt_message(d, val, True)
            else:
                val, err = _pt_scalar(d, vf)
            if err != None:
                return err
        else:
            return _pt_new_error(d, tok["pos"], "unknown map entry field " + repr(name))
    if key == None:
        key = kf["default"]
    if val == None:
        val = _pr_new_msg(vf["msg"]) if vf["is_msg"] else vf["default"]
    mp[key] = val
    return None

def _pt_skip_value(d):
    tok, err = _pt_read(d)
    if err != None:
        return err
    if tok["kind"] == _PT_MOPEN:
        return _pt_skip_message(d)
    if tok["kind"] == _PT_LOPEN:
        for _ in range(d["n"] + 2):
            tok, err = _pt_read(d)
            if err != None:
                return err
            if tok["kind"] == _PT_LCLOSE:
                return None
            if tok["kind"] == _PT_MOPEN:
                err = _pt_skip_message(d)
                if err != None:
                    return err
    return None

def _pt_skip_message(d):
    for _ in range(d["n"] + 2):
        tok, err = _pt_read(d)
        if err != None:
            return err
        if tok["kind"] == _PT_MCLOSE:
            return None
        if tok["kind"] == _PT_NAME:
            err = _pt_skip_value(d)
            if err != None:
                return err
    return None
'''
