TIME_PRELUDE = r'''# lib/time.star - starlark-go's lib/time module, written in Starlark.
#
# The compiler adds this to the prelude (lib/prelude.star) of programs that
# name `time`, the predeclared module (codegen's lookup: _time_module()).
# It behaves like go.starlark.net/lib/time, which bin/starhost predeclares:
# the same values, operations, outputs and error messages. Its parts:
#
#   values     Times, durations, the module and bound methods are library
#              objects (_obj_new; lib/builtins.star's _objects): the runtime
#              sends every operation on them to _obj_dispatch, which sends
#              those on these kinds here (_tm_dispatch).
#   calendar   Go's time.Date, Time.Add/Sub and the field accessors, on a
#              time's state (unix seconds, nanoseconds, location).
#   layouts    Go's Time.Format and time.Parse (src/time/format.go, ported:
#              nextStdChunk, appendFormat, parse and their helpers), and
#              Duration.String / time.ParseDuration.
#   zones      The host answers three questions (_time_host; "time_query"
#              in host/wasmhost.mjs): the current time, the offset and
#              abbreviation of a zone at an instant, and a zone's
#              abbreviations. Everything else about locations is here.
#
# A time's data is (sec, nsec, loc): seconds since 1970-01-01 UTC, 0 <=
# nsec < 1e9, and a location: "UTC", "Local", an IANA name the host knows,
# or ("fixed", name, offset) (Go's FixedZone, made by parsing). A
# duration's data is its nanoseconds, an int64 (arithmetic wraps, as Go's).

_TK_MODULE = 33
_TK_TIME = 34
_TK_DURATION = 35
_TK_METHOD = 36  # a bound builtin method: [name, receiver]

_TM_MODULE = _obj_new(_TK_MODULE, None)

def _time_module():
    return _TM_MODULE

_TM_NS = {"nanosecond": 1, "microsecond": 1000, "millisecond": 1000000, "second": 1000000000, "minute": 60000000000, "hour": 3600000000000}
_TM_FUNCS = ["from_timestamp", "is_valid_timezone", "now", "parse_duration", "parse_time", "time"]
_TM_TIME_ATTRS = ["day", "format", "hour", "in_location", "minute", "month", "nanosecond", "second", "unix", "unix_nano", "year"]
_TM_DURATION_ATTRS = ["hours", "microseconds", "milliseconds", "minutes", "nanoseconds", "seconds"]
_TM_MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
_TM_DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
_TM_DAYS_BEFORE = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365]
_TM_ZERO_SEC = -62135596800  # 0001-01-01 00:00:00 UTC
_TM_MAX64 = 9223372036854775807
_TM_RFC3339 = "2006-01-02T15:04:05Z07:00"
_TM_STRING = "2006-01-02 15:04:05.999999999 -0700 MST"

def _tm_w64(n):
    """n wrapped to an int64, as Go's arithmetic."""
    n = n & 0xffffffffffffffff
    return n - (1 << 64) if n > _TM_MAX64 else n

def _tm_tdiv(a, b):
    """a / b truncated toward zero (Go's integer division)."""
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q

def _tm_duration(ns):
    return _obj_new(_TK_DURATION, ns)

def _tm_time(sec, nsec, loc):
    return _obj_new(_TK_TIME, (sec, nsec, loc))

# ---------------------------------------------------------------- arguments

def _tm_want(fn, param, v, want):
    """starlark-go's UnpackArg for string and int (an int64)."""
    t = type(v)
    if t != want:
        _error(fn + ": for parameter " + param + ": got " + t + ", want " + want)
    if want == "int" and (v > _TM_MAX64 or v < -_TM_MAX64 - 1):
        _error(fn + ": for parameter " + param + ": " + str(v) + " out of range (want value in signed 64-bit range)")
    return v

def _tm_positional(fn, args, kwargs, lo, hi):
    """starlark-go's checkPositionalArgs."""
    if kwargs:
        _error(fn + ": unexpected keyword arguments")
    if len(args) < lo:
        _error(fn + ": got " + str(len(args)) + " arguments, want " + ("at least " if lo < hi else "") + str(lo))
    if len(args) > hi:
        _error(fn + ": got " + str(len(args)) + " arguments, want " + ("at most " if hi > lo else "") + str(hi))

def _tm_unpack(fn, args, kwargs, names, types, required):
    """starlark-go's UnpackArgs: the values of the parameters `names` (None
    for those not given), the first `required` of which must be."""
    n = len(names)
    if len(args) > n:
        _error(fn + ": got " + str(len(args)) + " arguments, want at most " + str(n))
    out = [None] * n
    seen = [False] * n
    for i, a in enumerate(args):
        seen[i] = True
        out[i] = _tm_want(fn, names[i], a, types[i])
    for name, a in kwargs.items():
        if name not in names:
            # (starlark-go offers only the first half of the names as hints)
            hint = _nearest(name, sorted(names[:(n + 1) // 2]))
            _error(fn + ": unexpected keyword argument " + repr(name) + ("" if hint == None else " (did you mean " + hint + "?)"))
        i = names.index(name)
        if seen[i]:
            _error(fn + ": got multiple values for keyword argument " + repr(name))
        seen[i] = True
        out[i] = _tm_want(fn, repr(name), a, types[i])
    for i in range(required):
        if not seen[i]:
            _error(fn + ": missing argument for " + names[i])
    return out

# ---------------------------------------------------------------- zones

def _tm_location(name):
    """Go's time.LoadLocation: (location, None) or (None, error)."""
    if name == "" or name == "UTC":
        return "UTC", None
    if name == "Local":
        return "Local", None
    if ".." in name or name[0] == "/" or name[0] == "\\":
        return None, "time: invalid location name"
    if _time_host("zone " + name + " 0") == None:
        return None, "unknown time zone " + name
    return name, None

def _tm_lookup(loc, sec):
    """The zone in use in loc at the instant sec: (abbreviation, offset)."""
    if loc == "UTC":
        return "UTC", 0
    if type(loc) == "tuple":
        return loc[1], loc[2]
    r = _time_host("zone " + loc + " " + str(sec))
    if r == None:
        return "UTC", 0
    i = r.index(" ")
    return r[i + 1:], int(r[:i])

def _tm_zones(loc, sec):
    """The zones of loc, as Go's Location.zone: [(abbreviation, offset)]."""
    if loc == "UTC":
        return []
    if type(loc) == "tuple":
        return [(loc[1], loc[2])]
    r = _time_host("names " + loc + " " + str(sec))
    out = []
    for z in (r or "").split(" "):
        if z:
            i = z.rindex(":")
            out.append((z[:i], int(z[i + 1:])))
    return out

def _tm_lookup_name(loc, name, sec):
    """Go's Location.lookupName: the offset of the zone called name in loc,
    preferably one in effect at sec (a local time); None if there is none."""
    zones = _tm_zones(loc, sec)
    for zname, off in zones:
        if zname == name:
            nam, offset = _tm_lookup(loc, sec - off)
            if nam == zname:
                return offset
    for zname, off in zones:
        if zname == name:
            return off
    return None

# ---------------------------------------------------------------- calendar

def _tm_days_from_civil(y, m, d):
    """Days from 1970-01-01 to y-m-d (proleptic Gregorian; any d)."""
    if m <= 2:
        y -= 1
    era = y // 400
    yoe = y - era * 400
    doy = (153 * ((m + 9) % 12) + 2) // 5 + d - 1
    return era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468

def _tm_civil(days):
    """(year, month, day) of the day `days` after 1970-01-01."""
    z = days + 719468
    era = z // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    m = mp + 3 if mp < 10 else mp - 9
    return yoe + era * 400 + (1 if m <= 2 else 0), m, doy - (153 * mp + 2) // 5 + 1

def _tm_is_leap(y):
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)

def _tm_days_in(m, y):
    if m == 2 and _tm_is_leap(y):
        return 29
    return _TM_DAYS_BEFORE[m] - _TM_DAYS_BEFORE[m - 1]

def _tm_date(year, month, day, hour, mi, sec, nsec, loc):
    """Go's time.Date: values out of range are normalized."""
    m = month - 1
    year += m // 12
    month = m % 12 + 1
    sec += nsec // 1000000000
    nsec = nsec % 1000000000
    mi += sec // 60
    sec = sec % 60
    hour += mi // 60
    mi = mi % 60
    day += hour // 24
    hour = hour % 24
    unix = (_tm_days_from_civil(year, month, 1) + day - 1) * 86400 + hour * 3600 + mi * 60 + sec
    if loc != "UTC":
        # the offset in effect at this local time: as Go, guess with the
        # one of the instant `unix`, then look again at the instant it gives
        _, offset = _tm_lookup(loc, unix)
        if offset != 0:
            _, offset = _tm_lookup(loc, unix - offset)
            unix -= offset
    return _tm_time(unix, nsec, loc)

def _tm_fields(d):
    """What formatting needs of a time: a dict of its local fields."""
    sec, nsec, loc = d
    name, offset = _tm_lookup(loc, sec)
    local = sec + offset
    days = local // 86400
    rem = local % 86400
    y, m, dd = _tm_civil(days)
    return {
        "name": name,
        "offset": offset,
        "year": y,
        "month": m,
        "day": dd,
        "yday": days - _tm_days_from_civil(y, 1, 1) + 1,
        "weekday": (days + 4) % 7,
        "hour": rem // 3600,
        "minute": rem % 3600 // 60,
        "second": rem % 60,
        "nanosecond": nsec,
    }

def _tm_add(d, ns):
    """Go's Time.Add."""
    sec, nsec, loc = d
    total = nsec + ns
    return _tm_time(sec + total // 1000000000, total % 1000000000, loc)

def _tm_sub(a, b):
    """Go's Time.Sub: a duration's nanoseconds, saturating."""
    ns = (a[0] - b[0]) * 1000000000 + a[1] - b[1]
    if ns > _TM_MAX64:
        return _TM_MAX64
    if ns < -_TM_MAX64 - 1:
        return -_TM_MAX64 - 1
    return ns

def _tm_cmp(a, b):
    if a < b:
        return -1
    return 1 if a > b else 0

# ---------------------------------------------------------------- layouts

def _tm_digit(s, i):
    return i < len(s) and s[i] >= "0" and s[i] <= "9"

def _tm_lower(s):
    return len(s) > 0 and s[0] >= "a" and s[0] <= "z"

_TM_STD0X = ["01", "02", "03", "04", "05", "06"]
_TM_NUM_TZ = ["-070000", "-07:00:00", "-0700", "-07:00", "-07"]
_TM_ISO_TZ = ["Z070000", "Z07:00:00", "Z0700", "Z07:00", "Z07"]

def _tm_chunk(layout):
    """Go's nextStdChunk: (prefix, std, suffix). std is None at the end,
    else (code, digits, separator): code is the layout element's canonical
    spelling ("2006", "Jan", "_2", ...), or "frac0" / "frac9" for
    fractional seconds, which have the other two."""
    n = len(layout)
    for i in range(n):
        c = layout[i]
        if c == "J":
            if layout[i:i + 3] == "Jan":
                if layout[i:i + 7] == "January":
                    return layout[:i], ("January", 0, ""), layout[i + 7:]
                if not _tm_lower(layout[i + 3:]):
                    return layout[:i], ("Jan", 0, ""), layout[i + 3:]
        elif c == "M":
            if n >= i + 3:
                if layout[i:i + 3] == "Mon":
                    if layout[i:i + 6] == "Monday":
                        return layout[:i], ("Monday", 0, ""), layout[i + 6:]
                    if not _tm_lower(layout[i + 3:]):
                        return layout[:i], ("Mon", 0, ""), layout[i + 3:]
                if layout[i:i + 3] == "MST":
                    return layout[:i], ("MST", 0, ""), layout[i + 3:]
        elif c == "0":
            if n >= i + 2 and layout[i + 1] >= "1" and layout[i + 1] <= "6":
                return layout[:i], (_TM_STD0X[int(layout[i + 1]) - 1], 0, ""), layout[i + 2:]
            if layout[i + 1:i + 3] == "02":
                return layout[:i], ("002", 0, ""), layout[i + 3:]
        elif c == "1":
            if layout[i + 1:i + 2] == "5":
                return layout[:i], ("15", 0, ""), layout[i + 2:]
            return layout[:i], ("1", 0, ""), layout[i + 1:]
        elif c == "2":
            if layout[i:i + 4] == "2006":
                return layout[:i], ("2006", 0, ""), layout[i + 4:]
            return layout[:i], ("2", 0, ""), layout[i + 1:]
        elif c == "_":
            if layout[i + 1:i + 2] == "2":
                # _2006 is really a literal _, followed by the year
                if layout[i + 1:i + 5] == "2006":
                    return layout[:i + 1], ("2006", 0, ""), layout[i + 5:]
                return layout[:i], ("_2", 0, ""), layout[i + 2:]
            if layout[i + 1:i + 3] == "_2":
                return layout[:i], ("__2", 0, ""), layout[i + 3:]
        elif c == "3" or c == "4" or c == "5":
            return layout[:i], (c, 0, ""), layout[i + 1:]
        elif c == "P":
            if layout[i + 1:i + 2] == "M":
                return layout[:i], ("PM", 0, ""), layout[i + 2:]
        elif c == "p":
            if layout[i + 1:i + 2] == "m":
                return layout[:i], ("pm", 0, ""), layout[i + 2:]
        elif c == "-" or c == "Z":
            for z in _TM_NUM_TZ if c == "-" else _TM_ISO_TZ:
                if layout[i:i + len(z)] == z:
                    return layout[:i], (z, 0, ""), layout[i + len(z):]
        elif c == "." or c == ",":
            # ,000 or .000 or ,999 or .999: fractional seconds
            if i + 1 < n and (layout[i + 1] == "0" or layout[i + 1] == "9"):
                ch = layout[i + 1]
                j = i + 1
                while j < n and layout[j] == ch:
                    j += 1
                if not _tm_digit(layout, j):  # all digits: only then
                    return layout[:i], ("frac0" if ch == "0" else "frac9", j - (i + 1), c), layout[j:]
    return layout, None, ""

def _tm_int(x, width):
    """Go's appendInt."""
    s = str(abs(x))
    s = "0" * (width - len(s)) + s
    return "-" + s if x < 0 else s

def _tm_offset(offset, code):
    """A numeric zone offset in the form of layout element `code`."""
    zone = _tm_tdiv(offset, 60)
    absoffset = abs(offset)
    out = "-" if zone < 0 else "+"
    zone = abs(zone)
    out += _tm_int(zone // 60, 2)
    colon = ":" in code
    if colon:
        out += ":"
    if len(code) > 3:
        out += _tm_int(zone % 60, 2)
    if code[1:] == "070000" or code[1:] == "07:00:00":
        if colon:
            out += ":"
        out += _tm_int(absoffset % 60, 2)
    return out

def _tm_format(d, layout):
    """Go's Time.Format."""
    f = _tm_fields(d)
    out = []
    for _ in range(len(layout) + 1):
        prefix, std, suffix = _tm_chunk(layout)
        out.append(prefix)
        if std == None:
            break
        layout = suffix
        code = std[0]
        hour = f["hour"]
        if code == "06":
            out.append(_tm_int(abs(f["year"]) % 100, 2))
        elif code == "2006":
            out.append(_tm_int(f["year"], 4))
        elif code == "Jan":
            out.append(_TM_MONTHS[f["month"] - 1][:3])
        elif code == "January":
            out.append(_TM_MONTHS[f["month"] - 1])
        elif code == "1":
            out.append(str(f["month"]))
        elif code == "01":
            out.append(_tm_int(f["month"], 2))
        elif code == "Mon":
            out.append(_TM_DAYS[f["weekday"]][:3])
        elif code == "Monday":
            out.append(_TM_DAYS[f["weekday"]])
        elif code == "2":
            out.append(str(f["day"]))
        elif code == "_2":
            out.append((" " if f["day"] < 10 else "") + str(f["day"]))
        elif code == "02":
            out.append(_tm_int(f["day"], 2))
        elif code == "__2":
            out.append(" " * (3 - len(str(f["yday"]))) + str(f["yday"]))
        elif code == "002":
            out.append(_tm_int(f["yday"], 3))
        elif code == "15":
            out.append(_tm_int(hour, 2))
        elif code == "3":
            out.append(str(hour % 12 or 12))
        elif code == "03":
            out.append(_tm_int(hour % 12 or 12, 2))
        elif code == "4":
            out.append(str(f["minute"]))
        elif code == "04":
            out.append(_tm_int(f["minute"], 2))
        elif code == "5":
            out.append(str(f["second"]))
        elif code == "05":
            out.append(_tm_int(f["second"], 2))
        elif code == "PM":
            out.append("PM" if hour >= 12 else "AM")
        elif code == "pm":
            out.append("pm" if hour >= 12 else "am")
        elif code == "MST":
            # a zone without a name is printed as -0700
            out.append(f["name"] if f["name"] != "" else _tm_offset(f["offset"], "-0700"))
        elif code[0] == "Z" and f["offset"] == 0:
            out.append("Z")
        elif code[0] == "Z" or code[0] == "-":
            out.append(_tm_offset(f["offset"], code))
        else:
            # fractional seconds (Go's appendNano)
            trim = code == "frac9"
            n = std[1]
            if not (trim and (n == 0 or f["nanosecond"] == 0)):
                s = std[2] + _tm_int(f["nanosecond"], 9)[:n]
                if trim:
                    s = s.rstrip("0")
                    if s == std[2]:
                        s = ""
                out.append(s)
    return "".join(out)

def _tm_quote(s):
    """Go's time.quote."""
    out = ["\""]
    for b in bytes(s).elems():
        if b >= 128 or b < 32:
            out.append("\\x" + "0123456789abcdef"[b >> 4] + "0123456789abcdef"[b & 15])
        elif b == 34 or b == 92:
            out.append("\\" + chr(b))
        else:
            out.append(chr(b))
    out.append("\"")
    return "".join(out)

def _tm_parse_error(layout, value, layout_elem, value_elem, message):
    if message == "":
        return "parsing time " + _tm_quote(value) + " as " + _tm_quote(layout) + ": cannot parse " + _tm_quote(value_elem) + " as " + _tm_quote(layout_elem)
    return "parsing time " + _tm_quote(value) + message

def _tm_leading_int(s):
    """Go's leadingInt: (value, rest, ok)."""
    i = 0
    x = 0
    while i < len(s) and s[i] >= "0" and s[i] <= "9":
        if x > (1 << 63) // 10:
            return 0, "", False
        x = x * 10 + int(s[i])
        if x > 1 << 63:
            return 0, "", False
        i += 1
    return x, s[i:], True

def _tm_atoi(s):
    """Go's time.atoi: (value, ok)."""
    neg = False
    if s and (s[0] == "-" or s[0] == "+"):
        neg = s[0] == "-"
        s = s[1:]
    q, rem, ok = _tm_leading_int(s)
    if not ok or rem:
        return 0, False
    return -q if neg else q, True

def _tm_getnum(s, fixed):
    """Go's getnum: (value, rest, ok)."""
    if not _tm_digit(s, 0):
        return 0, s, False
    if not _tm_digit(s, 1):
        if fixed:
            return 0, s, False
        return int(s[0]), s[1:], True
    return int(s[:2]), s[2:], True

def _tm_getnum3(s, fixed):
    n = 0
    i = 0
    while i < 3 and _tm_digit(s, i):
        n = n * 10 + int(s[i])
        i += 1
    if i == 0 or fixed and i != 3:
        return 0, s, False
    return n, s[i:], True

def _tm_match(s1, s2):
    """Go's match: equal, letters without regard to case."""
    b1 = list(bytes(s1).elems())
    b2 = list(bytes(s2).elems())
    for i in range(len(b1)):
        if b1[i] != b2[i]:
            c = b1[i] | 32
            if c != b2[i] | 32 or c < 97 or c > 122:
                return False
    return True

def _tm_name_lookup(tab, val, short):
    """Go's lookup: (index, rest, ok)."""
    for i, v in enumerate(tab):
        if short:
            v = v[:3]
        if len(val) >= len(v) and _tm_match(val[:len(v)], v):
            return i, val[len(v):], True
    return -1, val, False

def _tm_nanoseconds(value, nbytes):
    """Go's parseNanoseconds: (ns, range error, ok)."""
    if value[0] != "." and value[0] != ",":
        return 0, "", False
    if nbytes > 10:
        value = value[:10]
        nbytes = 10
    ns, ok = _tm_atoi(value[1:nbytes])
    if not ok:
        return 0, "", False
    if ns < 0:
        return 0, "fractional second", True
    for _ in range(10 - nbytes):
        ns *= 10
    return ns, "", True

def _tm_signed_offset(value):
    """Go's parseSignedOffset: the length of a +hh, or 0."""
    if value[0] != "-" and value[0] != "+":
        return 0
    x, rem, ok = _tm_leading_int(value[1:])
    if not ok or value[1:] == rem or x > 23:
        return 0
    return len(value) - len(rem)

def _tm_zone_len(value):
    """Go's parseTimeZone: the length of a zone abbreviation, or -1."""
    if len(value) < 3:
        return -1
    if value[:4] == "ChST" or value[:4] == "MeST":
        return 4
    if value[:3] == "GMT":
        return 3 if len(value) == 3 else 3 + _tm_signed_offset(value[3:])
    if value[0] == "+" or value[0] == "-":
        n = _tm_signed_offset(value)
        return n if n > 0 else -1
    upper = 0
    while upper < 6 and upper < len(value) and value[upper] >= "A" and value[upper] <= "Z":
        upper += 1
    if upper == 5 and value[4] == "T":
        return 5
    if upper == 4 and (value[3] == "T" or value[:4] == "WITA"):
        return 4
    if upper == 3:
        return 3
    return -1

def _tm_skip(value, prefix):
    """Go's skip: (rest of value, ok)."""
    while prefix:
        if prefix[0] == " ":
            if value and value[0] != " ":
                return value, False
            prefix = prefix.lstrip(" ")
            value = value.lstrip(" ")
            continue
        if not value or value[0] != prefix[0]:
            return value, False
        prefix = prefix[1:]
        value = value[1:]
    return value, True

def _tm_parse(layout, value, default_loc, local):
    """Go's time.parse: (time, None) or (None, error message)."""
    alayout = layout
    avalue = value
    range_err = ""
    am = False
    pm = False
    year = 0
    month = -1
    day = -1
    yday = -1
    hour = 0
    mi = 0
    sec = 0
    nsec = 0
    utc = False
    zone_offset = None
    zone_name = ""
    for _ in range(len(layout) + 2):
        prefix, std, suffix = _tm_chunk(layout)
        stdstr = layout[len(prefix):len(layout) - len(suffix)]
        value, ok = _tm_skip(value, prefix)
        if not ok:
            return None, _tm_parse_error(alayout, avalue, prefix, value, "")
        if std == None:
            if value:
                return None, _tm_parse_error(alayout, avalue, "", value, ": extra text: " + _tm_quote(value))
            break
        layout = suffix
        hold = value
        code = std[0]
        ok = True
        if code == "06":
            if len(value) < 2:
                ok = False
            else:
                year, ok = _tm_atoi(value[:2])
                value = value[2:]
                if ok:
                    year += 1900 if year >= 69 else 2000
        elif code == "2006":
            if len(value) < 4 or not _tm_digit(value, 0):
                ok = False
            else:
                year, ok = _tm_atoi(value[:4])
                value = value[4:]
        elif code == "Jan" or code == "January":
            month, value, ok = _tm_name_lookup(_TM_MONTHS, value, code == "Jan")
            month += 1
        elif code == "1" or code == "01":
            month, value, ok = _tm_getnum(value, code == "01")
            if ok and (month <= 0 or 12 < month):
                range_err = "month"
        elif code == "Mon" or code == "Monday":
            _, value, ok = _tm_name_lookup(_TM_DAYS, value, code == "Mon")
        elif code == "2" or code == "_2" or code == "02":
            if code == "_2" and value and value[0] == " ":
                value = value[1:]
            day, value, ok = _tm_getnum(value, code == "02")
        elif code == "__2" or code == "002":
            for _ in range(2):
                if code == "__2" and value and value[0] == " ":
                    value = value[1:]
            yday, value, ok = _tm_getnum3(value, code == "002")
        elif code == "15":
            hour, value, ok = _tm_getnum(value, False)
            if hour < 0 or 24 <= hour:
                range_err = "hour"
        elif code == "3" or code == "03":
            hour, value, ok = _tm_getnum(value, code == "03")
            if hour < 0 or 12 < hour:
                range_err = "hour"
        elif code == "4" or code == "04":
            mi, value, ok = _tm_getnum(value, code == "04")
            if mi < 0 or 60 <= mi:
                range_err = "minute"
        elif code == "5" or code == "05":
            sec, value, ok = _tm_getnum(value, code == "05")
            if ok:
                if sec < 0 or 60 <= sec:
                    range_err = "second"
                elif len(value) >= 2 and (value[0] == "." or value[0] == ",") and _tm_digit(value, 1):
                    # a fractional second, with none in the layout?
                    _, nxt, _ = _tm_chunk(layout)
                    if nxt == None or (nxt[0] != "frac0" and nxt[0] != "frac9"):
                        n = 2
                        while n < len(value) and _tm_digit(value, n):
                            n += 1
                        nsec, range_err, ok = _tm_nanoseconds(value, n)
                        value = value[n:]
        elif code == "PM" or code == "pm":
            if len(value) < 2:
                ok = False
            else:
                p = value[:2]
                value = value[2:]
                if p == code:
                    pm = True
                elif p == ("AM" if code == "PM" else "am"):
                    am = True
                else:
                    ok = False
        elif code == "MST":
            if value[:3] == "UTC":
                utc = True
                value = value[3:]
            else:
                n = _tm_zone_len(value)
                if n < 0:
                    ok = False
                else:
                    zone_name = value[:n]
                    value = value[n:]
        elif code[0] == "Z" and value[:1] == "Z":
            value = value[1:]
            utc = True
        elif code[0] == "Z" or code[0] == "-":
            form = code[1:]
            hh = ""
            mm = "00"
            ss = "00"
            sign = ""
            if form == "07:00":
                if len(value) < 6 or value[3] != ":":
                    ok = False
                else:
                    sign, hh, mm, value = value[0], value[1:3], value[4:6], value[6:]
            elif form == "07":
                if len(value) < 3:
                    ok = False
                else:
                    sign, hh, value = value[0], value[1:3], value[3:]
            elif form == "07:00:00":
                if len(value) < 9 or value[3] != ":" or value[6] != ":":
                    ok = False
                else:
                    sign, hh, mm, ss, value = value[0], value[1:3], value[4:6], value[7:9], value[9:]
            elif form == "070000":
                if len(value) < 7:
                    ok = False
                else:
                    sign, hh, mm, ss, value = value[0], value[1:3], value[3:5], value[5:7], value[7:]
            elif len(value) < 5:
                ok = False
            else:
                sign, hh, mm, value = value[0], value[1:3], value[3:5], value[5:]
            if ok:
                hr, _, ok = _tm_getnum(hh, True)
                mn = 0
                sc = 0
                if ok:
                    mn, _, ok = _tm_getnum(mm, True)
                    if ok:
                        sc, _, ok = _tm_getnum(ss, True)

                # > rather than >=: some people do write offsets of 24
                # hours, or 60 minutes or seconds
                if hr > 24:
                    range_err = "time zone offset hour"
                if mn > 60:
                    range_err = "time zone offset minute"
                if sc > 60:
                    range_err = "time zone offset second"
                zone_offset = (hr * 60 + mn) * 60 + sc
                if sign == "-":
                    zone_offset = -zone_offset
                elif sign != "+":
                    ok = False
        elif code == "frac0":
            # exactly the number of digits of the layout
            ndigit = 1 + std[1]
            if len(value) < ndigit:
                ok = False
            else:
                nsec, range_err, ok = _tm_nanoseconds(value, ndigit)
                value = value[ndigit:]
        elif len(value) >= 2 and (value[0] == "." or value[0] == ",") and _tm_digit(value, 1):
            # frac9: any number of digits, if there is a fraction at all
            i = 0
            while _tm_digit(value, i + 1):
                i += 1
            nsec, range_err, ok = _tm_nanoseconds(value, 1 + i)
            value = value[1 + i:]
        if range_err != "":
            return None, _tm_parse_error(alayout, avalue, stdstr, value, ": " + range_err + " out of range")
        if not ok:
            return None, _tm_parse_error(alayout, avalue, stdstr, hold, "")
    if pm and hour < 12:
        hour += 12
    elif am and hour == 12:
        hour = 0

    if yday >= 0:
        # the day of the year gives the month and day
        d = 0
        m = 0
        if _tm_is_leap(year):
            if yday == 31 + 29:
                m = 2
                d = 29
            elif yday > 31 + 29:
                yday -= 1
        if yday < 1 or yday > 365:
            return None, _tm_parse_error(alayout, avalue, "", value, ": day-of-year out of range")
        if m == 0:
            m = (yday - 1) // 31 + 1
            if _TM_DAYS_BEFORE[m] < yday:
                m += 1
            d = yday - _TM_DAYS_BEFORE[m - 1]
        if month >= 0 and month != m:
            return None, _tm_parse_error(alayout, avalue, "", value, ": day-of-year does not match month")
        month = m
        if day >= 0 and day != d:
            return None, _tm_parse_error(alayout, avalue, "", value, ": day-of-year does not match day")
        day = d
    else:
        if month < 0:
            month = 1
        if day < 0:
            day = 1
    if day < 1 or day > _tm_days_in(month, year):
        return None, _tm_parse_error(alayout, avalue, "", value, ": day out of range")

    if utc:
        return _tm_date(year, month, day, hour, mi, sec, nsec, "UTC"), None
    t = _obj_data(_tm_date(year, month, day, hour, mi, sec, nsec, "UTC"))
    if zone_offset != None:
        # the local zone, if it had this offset then; else a zone made up
        # to record the offset
        unix = t[0] - zone_offset
        name, offset = _tm_lookup(local, unix)
        if offset == zone_offset and (zone_name == "" or name == zone_name):
            return _tm_time(unix, nsec, local), None
        return _tm_time(unix, nsec, ("fixed", zone_name, zone_offset)), None
    if zone_name != "":
        # the local zone, if it has a zone of this name; else a zone made
        # up, of unknown offset
        offset = _tm_lookup_name(local, zone_name, t[0])
        if offset != None:
            return _tm_time(t[0] - offset, nsec, local), None
        offset = 0
        if len(zone_name) > 3 and zone_name[:3] == "GMT":
            offset = _tm_atoi(zone_name[3:])[0] * 3600
        return _tm_time(t[0], nsec, ("fixed", zone_name, offset)), None
    return _tm_date(year, month, day, hour, mi, sec, nsec, default_loc), None

# ---------------------------------------------------------------- durations

_TM_UNITS = {"ns": 1, "us": 1000, "µs": 1000, "μs": 1000, "ms": 1000000, "s": 1000000000, "m": 60000000000, "h": 3600000000000}

def _tm_parse_duration(s):
    """Go's time.ParseDuration: (nanoseconds, None) or (None, error)."""
    orig = s
    invalid = "time: invalid duration " + _tm_quote(orig)
    d = 0
    neg = False
    if s != "" and (s[0] == "-" or s[0] == "+"):
        neg = s[0] == "-"
        s = s[1:]
    if s == "0":
        return 0, None
    if s == "":
        return None, invalid
    while s != "":
        f = 0
        scale = 1.0
        if not (s[0] == "." or _tm_digit(s, 0)):
            return None, invalid
        pl = len(s)
        v, s, ok = _tm_leading_int(s)
        if not ok:
            return None, invalid
        pre = pl != len(s)
        post = False
        if s != "" and s[0] == ".":
            s = s[1:]
            pl = len(s)

            # Go's leadingFraction
            i = 0
            overflow = False
            while _tm_digit(s, i):
                if not overflow:
                    if f > _TM_MAX64 // 10:
                        overflow = True
                    else:
                        y = f * 10 + int(s[i])
                        if y > 1 << 63:
                            overflow = True
                        else:
                            f = y
                            scale *= 10
                i += 1
            s = s[i:]
            post = pl != len(s)
        if not pre and not post:
            return None, invalid
        i = 0
        while i < len(s) and s[i] != "." and not _tm_digit(s, i):
            i += 1
        if i == 0:
            return None, "time: missing unit in duration " + _tm_quote(orig)
        u = s[:i]
        s = s[i:]
        unit = _TM_UNITS.get(u)
        if unit == None:
            return None, "time: unknown unit " + _tm_quote(u) + " in duration " + _tm_quote(orig)
        if v > (1 << 63) // unit:
            return None, invalid
        v *= unit
        if f > 0:
            v += int(float(f) * (float(unit) / scale))
            if v > 1 << 63:
                return None, invalid
        d += v
        if d > 1 << 63:
            return None, invalid
    if neg:
        return -d, None
    if d > _TM_MAX64:
        return None, invalid
    return d, None

def _tm_frac(v, prec):
    """Go's fmtFrac: (text, v // 10**prec)."""
    out = ""
    show = False
    for _ in range(prec):
        digit = v % 10
        show = show or digit != 0
        if show:
            out = str(digit) + out
        v //= 10
    return ("." + out if show else ""), v

def _tm_duration_str(d):
    """Go's Duration.String."""
    u = abs(d)
    if u < 1000000000:
        if u == 0:
            return "0s"
        if u < 1000:
            prec, unit = 0, "ns"
        elif u < 1000000:
            prec, unit = 3, "µs"
        else:
            prec, unit = 6, "ms"
        frac, u = _tm_frac(u, prec)
        out = str(u) + frac + unit
    else:
        frac, u = _tm_frac(u, 9)
        out = str(u % 60) + frac + "s"
        u //= 60
        if u > 0:
            out = str(u % 60) + "m" + out
            u //= 60
            if u > 0:
                out = str(u) + "h" + out
    return "-" + out if d < 0 else out

def _tm_to_duration(fn, v):
    """starlark-go's Duration.Unpack, for parameter 1 of fn."""
    if _obj_kind(v) == _TK_DURATION:
        return _obj_data(v)
    if type(v) == "string":
        ns, err = _tm_parse_duration(v)
        if err != None:
            _error(fn + ": for parameter 1: " + err)
        return ns
    _error(fn + ": for parameter 1: got " + type(v) + ", want a duration, string, or int")

# ---------------------------------------------------------------- values

def _tm_duration_attr(d, name):
    if name == "hours" or name == "minutes" or name == "seconds":
        unit = 3600000000000 if name == "hours" else 60000000000 if name == "minutes" else 1000000000
        whole = _tm_tdiv(d, unit)
        return float(whole) + float(d - whole * unit) / float(unit)
    if name == "milliseconds":
        return _tm_tdiv(d, 1000000)
    if name == "microseconds":
        return _tm_tdiv(d, 1000)
    if name == "nanoseconds":
        return d
    return None

def _tm_attr(x, k, d, name):
    """(value, None) or (None, error message)."""
    if k == _TK_MODULE:
        ns = _TM_NS.get(name)
        if ns != None:
            return _tm_duration(ns), None
        if name in _TM_FUNCS:
            return _obj_new(_TK_METHOD, [name, None]), None
        return None, "module has no ." + name + " field or method"
    if k == _TK_DURATION:
        v = _tm_duration_attr(d, name)
        if v != None:
            return v, None
        return None, "unrecognized time.duration attribute " + repr(name)
    if k == _TK_TIME:
        if name == "unix":
            return d[0], None
        if name == "unix_nano":
            return _tm_w64(d[0] * 1000000000 + d[1]), None
        if name == "format" or name == "in_location":
            return _obj_new(_TK_METHOD, [name, x]), None
        if name in _TM_TIME_ATTRS:
            return _tm_fields(d)[name], None
        return None, "time.time has no ." + name + " field or method" + _attr_hint(_TM_TIME_ATTRS, name)
    return None, "builtin_function_or_method has no ." + name + " field or method"

def _tm_binary(k, d, y, op):
    """x op y (op "+"), or y op x (op "r+"), for x of kind k with data d:
    the result, or None if there is none (starlark-go's Binary methods)."""
    ky = _obj_kind(y)
    right = op[0] == "r"
    if right:
        op = op[1:]
    if k == _TK_TIME:
        # (whichever side the time is on, as starlark-go's: duration -
        # time is time - duration)
        if op == "+" and ky == _TK_DURATION:
            return _tm_add(d, _obj_data(y))
        if op == "-" and ky == _TK_DURATION:
            return _tm_add(d, -_obj_data(y))
        if op == "-" and ky == _TK_TIME:
            return _tm_duration(_tm_sub(d, _obj_data(y)))
        return None
    if k != _TK_DURATION:
        return None
    ty = type(y)
    if op == "+":
        if ky == _TK_DURATION:
            return _tm_duration(_tm_w64(d + _obj_data(y)))
        if ky == _TK_TIME:
            return _tm_add(_obj_data(y), d)
    elif op == "-":
        # (duration - duration; the left operand answers first)
        if ky == _TK_DURATION:
            return _tm_duration(_tm_w64(d - _obj_data(y)))
    elif op == "/":
        if ky == _TK_DURATION:
            if _obj_data(y) == 0:
                _error_plain("time.duration division by zero")
            return float(d) / float(_obj_data(y))
        if ty == "int":
            if right:
                _error_plain("unsupported operation")
            if y > _TM_MAX64 or y < -_TM_MAX64 - 1:
                _error_plain("int value out of range (want signed 64-bit value)")
            if y == 0:
                _error_plain("time.duration division by zero")
            return _tm_duration(_tm_w64(_tm_tdiv(d, y)))
        if ty == "float":
            if y == 0.0:
                _error_plain("time.duration division by zero")
            return _tm_duration(_tm_float_ns(float(d) / y))
    elif op == "//":
        if ky == _TK_DURATION:
            if _obj_data(y) == 0:
                _error_plain("time.duration division by zero")
            return _tm_w64(_tm_tdiv(d, _obj_data(y)))
    elif op == "*":
        if ty == "int":
            if y > _TM_MAX64 or y < -_TM_MAX64 - 1:
                _error_plain("int value out of range (want signed 64-bit value)")
            return _tm_duration(_tm_w64(d * y))
    return None

def _tm_float_ns(f):
    """A float as an int64, as Go converts (on amd64) one out of range."""
    if f != f or f >= 9223372036854775808.0 or f < -9223372036854775808.0:
        return -_TM_MAX64 - 1
    return int(f)

def _tm_call(x, d, args, kwargs):
    name, recv = d
    kwargs = kwargs or {}
    if recv == None:
        return _TM_IMPLS[name](*args, **kwargs)
    _tm_positional(name, args, kwargs, 1, 1)
    arg = _tm_want(name, "1", args[0], "string")
    t = _obj_data(recv)
    if name == "format":
        return _tm_format(t, arg)
    loc, err = _tm_location(arg)
    if err != None:
        _error(err)
    return _tm_time(t[0], t[1], loc)

def _tm_dispatch(op, x, a, b):
    """Every operation on a value of the time module (see _objects in
    lib/builtins.star)."""
    k = _obj_kind(x)
    d = _obj_data(x)
    if op == _OBJ_ATTR:
        v, err = _tm_attr(x, k, d, a)
        if b != None:
            return (err == None, v if err == None else err)
        if err != None:
            _error_plain(err)
        return v
    if op == 0:  # type
        if k == _TK_TIME:
            return "time.time"
        if k == _TK_DURATION:
            return "time.duration"
        return "module" if k == _TK_MODULE else "builtin_function_or_method"
    if op == 1:  # str
        if k == _TK_TIME:
            return _tm_format(d, _TM_STRING)
        if k == _TK_DURATION:
            return _tm_duration_str(d)
        if k == _TK_MODULE:
            return "<module \"time\">"
        if d[1] == None:
            return "<built-in function " + d[0] + ">"
        return "<built-in method " + d[0] + " of time.time value>"
    if op == 2:  # truth
        if k == _TK_TIME:
            return d[0] != _TM_ZERO_SEC or d[1] != 0
        if k == _TK_DURATION:
            return d != 0
        return True
    if op == 10:  # ==
        if _obj_kind(a) != k:
            return False
        if k == _TK_TIME:
            return d[0] == _obj_data(a)[0] and d[1] == _obj_data(a)[1]
        if k == _TK_DURATION:
            return d == _obj_data(a)
        return _identical(x, a)  # a method, each time it is taken, is another value
    if op == _OBJ_CMP:
        if _obj_kind(a) != k:
            return None
        if k == _TK_TIME:
            return _tm_cmp((d[0], d[1]), (_obj_data(a)[0], _obj_data(a)[1]))
        if k == _TK_DURATION:
            return _tm_cmp(d, _obj_data(a))
        return None
    if op == _OBJ_BINARY:
        return _tm_binary(k, d, a, b)
    if op == 9:  # hash
        if k == _TK_TIME:
            ns = _tm_w64(d[0] * 1000000000 + d[1])
            return (ns & 0xffffffff) ^ ((ns >> 32) & 0xffffffff)
        if k == _TK_DURATION:
            return (d & 0xffffffff) ^ ((d >> 32) & 0xffffffff)
        if k == _TK_METHOD:
            return hash(d[0]) ^ 5521
        _error_plain("unhashable: module")
    if op == 14:  # unhashable: the type's name
        return "module" if k == _TK_MODULE else None
    if op == 11:  # call
        if k == _TK_METHOD:
            return _tm_call(x, d, a, b)
        _error_plain("invalid call of non-function (" + type(x) + ")")
    if op == 12:  # the name it is called by
        return d[0] if k == _TK_METHOD else None
    if op == _OBJ_SETATTR:
        _error_plain("can't assign to ." + a + " field of " + type(x))
    if op == _OBJ_DIR:
        if k == _TK_TIME:
            return _TM_TIME_ATTRS
        if k == _TK_DURATION:
            return _TM_DURATION_ATTRS
        if k == _TK_MODULE:
            return sorted(_TM_FUNCS + _TM_NS.keys())
        return []
    if op == _OBJ_HASATTR:
        _, err = _tm_attr(x, k, d, a)
        return err == None
    if op == 4:  # x[a]
        _error_plain("unhandled index operation " + type(x) + "[" + type(a) + "]")
    if op == 5:  # x[a] = b
        _error_plain(type(x) + " value does not support item assignment")
    if op == 6:  # a in x
        _error_plain("unknown binary op: " + type(a) + " in " + type(x))
    return None  # no len, no iteration; nothing to freeze

# ---------------------------------------------------------------- the module

def _mod_time__now(*args, **kwargs):
    # (as starlark-go's: it takes anything)
    r = _time_host("now")
    if r == None:
        _error("time.now() is not available")
    i = r.index(" ")
    return _tm_time(int(r[:i]), int(r[i + 1:]), "Local")

def _mod_time__from_timestamp(*args, **kwargs):
    _tm_positional("from_timestamp", args, kwargs, 1, 2)
    sec = _tm_want("from_timestamp", "1", args[0], "int")
    nsec = _tm_want("from_timestamp", "2", args[1], "int") if len(args) > 1 else 0
    return _tm_time(sec + nsec // 1000000000, nsec % 1000000000, "Local")

def _mod_time__is_valid_timezone(*args, **kwargs):
    _tm_positional("is_valid_timezone", args, kwargs, 1, 1)
    _, err = _tm_location(_tm_want("is_valid_timezone", "1", args[0], "string"))
    return err == None

def _mod_time__parse_duration(*args, **kwargs):
    _tm_positional("parse_duration", args, kwargs, 1, 1)
    return _tm_duration(_tm_to_duration("parse_duration", args[0]))

def _mod_time__parse_time(*args, **kwargs):
    x, layout, location = _tm_unpack("parse_time", args, kwargs, ["x", "format", "location"], ["string", "string", "string"], 1)
    if layout == None:
        layout = _TM_RFC3339
    if location == None or location == "UTC":
        # Go's time.Parse: UTC unless the text says otherwise, and the
        # local zone if the text has its offset
        t, err = _tm_parse(layout, x, "UTC", "Local")
    else:
        loc, err = _tm_location(location)
        if err != None:
            _error(err)
        t, err = _tm_parse(layout, x, loc, loc)
    if err != None:
        _error(err)
    return t

def _mod_time__time(*args, **kwargs):
    names = ["year", "month", "day", "hour", "minute", "second", "nanosecond", "location"]
    v = _tm_unpack("time", args, kwargs, names, ["int"] * 7 + ["string"], 0)
    if args:
        _error("time: unexpected positional arguments")
    loc, err = _tm_location(v[7] or "")
    if err != None:
        _error(err)
    return _tm_date(v[0] or 0, v[1] or 0, v[2] or 0, v[3] or 0, v[4] or 0, v[5] or 0, v[6] or 0, loc)

_TM_IMPLS = {
    "from_timestamp": _mod_time__from_timestamp,
    "is_valid_timezone": _mod_time__is_valid_timezone,
    "now": _mod_time__now,
    "parse_duration": _mod_time__parse_duration,
    "parse_time": _mod_time__parse_time,
    "time": _mod_time__time,
}
'''
