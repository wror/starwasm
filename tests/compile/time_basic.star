# The time module (lib/time.star), against starlark-go's lib/time.

def show(*args):
    print(*[repr(a) for a in args])

def main():
    t = time.parse_time("2000-01-02T03:04:05Z")
    show(time, type(time), dir(time), bool(time))
    show(t, str(t), type(t), dir(t), bool(t), t.format, type(t.format), time.now, type(time.now), time.time)
    show(time.second, time.nanosecond, time.microsecond, time.millisecond, time.minute, time.hour, type(time.hour), dir(time.hour))

    # durations
    ds = ["0", "1ns", "999ns", "1us", "1.5µs", "1μs", "1ms", "1.234567ms", "1s", "1.5s", "90s", "1m", "61m1.001s", "1h", "25h", "1h2m3.004005006s",
          "-1.5h", "+3m", "2540400h10m10.000000000s", "-2562047h47m16.854775808s", ".5s", "1.s", "0.000000001s", "1h1h", "3ns2us1ms"]
    for s in ds:
        d = time.parse_duration(s)
        show(s, d, d.hours, d.minutes, d.seconds, d.milliseconds, d.microseconds, d.nanoseconds, bool(d))
    show(time.parse_duration(time.minute), time.parse_duration("1m") == time.minute, time.minute != time.second, time.minute == 60)
    h = time.hour
    m = time.minute
    show(h + m, h - m, m - h, h * 3, 3 * h, h * -2, h / m, m / h, h / 7, h / -7, h / 2.5, h / -0.3, h // m, m // h, (time.second - h) // m, (m - h) // (m * 7), h // (m * -7))
    show(h < m, h > m, h <= h, h >= m, m < h, sorted([h, m, time.second, m - h]), max(h, m), min(h, m), {h: 1, m: 2}[time.minute * 60], h in {h: 1}, [h] == [m * 60])
    show(time.hour * (1 << 62), time.hour * (1 << 40) + time.hour * (1 << 40), time.nanosecond * ((1 << 63) - 1) + time.nanosecond, time.second / 1e-30, time.second / float("inf"))

    # times: fields
    ts = [
        time.time(),
        time.time(year = 1),
        time.time(year = 1, month = 1, day = 1),
        time.time(year = 2020, month = 2, day = 29, hour = 23, minute = 59, second = 59, nanosecond = 999999999),
        time.time(year = 2021, month = 14, day = 35, hour = 25, minute = 61, second = 61, nanosecond = 1000000001),
        time.time(year = 2021, month = -1, day = -1, hour = -1, minute = -1, second = -1, nanosecond = -1),
        time.time(year = 1969, month = 12, day = 31, hour = 23, minute = 59, second = 59, nanosecond = 5),
        time.time(year = -44, month = 3, day = 15),
        time.time(year = 12345, month = 6, day = 7, hour = 8),
        time.time(year = 1900, month = 2, day = 29),
        time.time(year = 2000, month = 2, day = 29),
        time.from_timestamp(0),
        time.from_timestamp(1593193116, 123456789),
        time.from_timestamp(-1, -1),
        time.from_timestamp(1, 3000000007),
        time.from_timestamp(1 << 40),
        time.from_timestamp(-(1 << 40)),
    ]
    for x in ts:
        show(x, x.year, x.month, x.day, x.hour, x.minute, x.second, x.nanosecond, x.unix, x.unix_nano, bool(x))
        show(x.format("Monday Mon January Jan 1 01 2 _2 02 __2 002 15 3 03 4 04 5 05 2006 06 PM pm MST Z0700 Z070000 Z07 Z07:00 Z07:00:00 -0700 -070000 -07 -07:00 -07:00:00"))
        show(x.format(".0 .00 .000 .000000 .000000000 .9 .99 .999999999 ,000 ,999 .0000000000 5.9x 5.999 05.0001 .12 .09a .90"))

    # layouts: what is an element and what is literal text
    for layout in ["", "plain text", "Jan Janu January Januaryx Mon Mond Monday MSTx Mx", "1 15 150 2 20 2006 200 _2 _2006 __2 ___2 _", "3 4 5 6 7 8 9 0 01 02 03 04 05 06 07 002 003",
                   "PM P pm p AM", "-07 -0 -070 -0700 -07000 -070000 -07:0 -07:00 -07:00:0 -07:00:00", "Z Z0 Z07 Z070 Z0700 Z07000 Z070000 Z07:00:00", "2006-01-02T15:04:05Z07:00",
                   "Mon Jan _2 15:04:05 2006", "Mon, 02 Jan 2006 15:04:05 -0700", "3:04PM", "Jan _2 15:04:05.000000", "02 Jan 06 15:04 MST", "Monday, 02-Jan-06 15:04:05 MST", "2006-01-02T15:04:05.999999999Z07:00", "é ünï 日本 2006"]:
        show(layout, ts[3].format(layout), ts[6].format(layout))

    # zones
    berlin = time.time(year = 2021, month = 3, day = 28, hour = 2, minute = 30, location = "Europe/Berlin")  # a skipped hour
    ny = time.time(year = 2021, month = 11, day = 7, hour = 1, minute = 30, location = "America/New_York")  # an hour twice
    show(berlin, berlin.unix, ny, ny.unix, ny + time.hour, ny - time.hour, berlin - time.hour, berlin + time.hour)
    for zone in ["UTC", "", "America/New_York", "America/Los_Angeles", "Europe/Berlin", "Europe/London", "Asia/Kolkata", "Asia/Tokyo", "Asia/Kathmandu", "Australia/Sydney", "America/Sao_Paulo", "Pacific/Auckland", "Africa/Cairo", "Etc/GMT+5", "America/St_Johns", "Asia/Tehran"]:
        for x in [time.time(year = 2024, month = 1, day = 15, hour = 12, location = zone), time.time(year = 2024, month = 7, day = 15, hour = 12, location = zone), time.time(year = 1975, month = 7, day = 4, location = zone), time.time(year = 2050, month = 7, day = 4, hour = 3, location = zone), time.time(year = 1890, month = 1, day = 1, location = zone), time.time(year = 2400, month = 12, day = 25, location = zone)]:
            show(zone, x, x.unix, x.hour, x.format("MST -07:00 Z07:00"), x.in_location("UTC"), x.in_location("Asia/Tokyo").format("2006-01-02 15:04 MST"))
    show([time.is_valid_timezone(z) for z in ["UTC", "", "Local", "Europe/Berlin", "Europe/Nowhere", "nope", "../etc", "/etc/passwd", "Europe/../Europe/Berlin"]])
    show(t == t.in_location("Asia/Tokyo"), t != t.in_location("Asia/Tokyo"), {t: 1}[t.in_location("Asia/Tokyo")], t < t.in_location("Asia/Tokyo"), t.in_location("Asia/Tokyo").hour, t.in_location("Asia/Tokyo").in_location("America/New_York"))

    # arithmetic and order
    u = t + time.hour * 25 + time.nanosecond * 7
    show(u, u - t, t - u, u - time.hour, time.hour + u, time.hour - u, u > t, u < t, u >= u, u <= t, sorted([u, t, t - time.second]), max(u, t), min(u, t), u == u, u != t, [u] == [u + time.nanosecond])
    show(time.time(year = 2300) - time.time(year = 1700), time.time(year = 1700) - time.time(year = 2300), time.time(year = 2000) - time.time(year = 1999), t + time.hour * (1 << 40))
    show(t.in_location("Europe/Berlin") + time.hour * 24 * 180, t.in_location("Europe/Berlin") - t.in_location("America/New_York"))

    # parsing
    def parse(x, *args, **kwargs):
        p = time.parse_time(x, *args, **kwargs)
        show(x, p, p.unix, p.nanosecond, p.format("2006-01-02T15:04:05.999999999Z07:00 MST"))

    parse("2020-06-26T17:38:36Z")
    parse("2020-06-26T17:38:36.5Z")
    parse("2020-06-26T17:38:36.123456789+05:30")
    parse("2020-06-26T17:38:36,25-08:00")
    parse("2020-06-26T17:38:36+00:00")
    parse("2020-06-26T17:38:36.123456789", format = "2006-01-02T15:04:05.999999999")
    parse("2020-06-26T17:38:36.1234567891234", format = "2006-01-02T15:04:05")
    parse("2020-06-26T17:38:36.120", format = "2006-01-02T15:04:05.000")
    parse("Mon Jan  2 15:04:05 2006", "Mon Jan _2 15:04:05 2006")
    parse("Tue jan 10 03:04:05 2006", "Mon Jan _2 15:04:05 2006")
    parse("Monday, 02-Jan-06 15:04:05 MST", "Monday, 02-Jan-06 15:04:05 MST")
    parse("Mon, 02 Jan 2006 15:04:05 -0700", "Mon, 02 Jan 2006 15:04:05 -0700")
    parse("Mon, 02 Jan 2006 15:04:05 +0000", "Mon, 02 Jan 2006 15:04:05 -0700")
    parse("FRIDAY, 31-DECEMBER-99 11:59PM", "Monday, 02-January-06 03:04PM")
    parse("12:00AM", "3:04PM")
    parse("12:00pm", "3:04pm")
    parse("7:05am", "3:04pm")
    parse("Feb  3 2013 at 7:54pm (PST)", "Jan _2 2006 at 3:04pm (MST)")
    parse("Feb  3 2013 at 7:54pm (PST)", "Jan _2 2006 at 3:04pm (MST)", "America/Los_Angeles")
    parse("Jul  3 2013 at 7:54pm (PDT)", "Jan _2 2006 at 3:04pm (MST)", "America/Los_Angeles")
    parse("Jul  3 2013 at 7:54pm (PST)", "Jan _2 2006 at 3:04pm (MST)", "America/Los_Angeles")
    parse("Jul  3 2013 at 7:54pm (CEST)", "Jan _2 2006 at 3:04pm (MST)", "America/Los_Angeles")
    parse("2013-02-03 19:54 UTC", "2006-01-02 15:04 MST", "Europe/Berlin")
    parse("2013-02-03 19:54 GMT+3", "2006-01-02 15:04 MST")
    parse("2013-02-03 19:54 GMT-11", "2006-01-02 15:04 MST")
    parse("2013-02-03 19:54 GMT", "2006-01-02 15:04 MST")
    parse("2013-02-03 19:54 +03", "2006-01-02 15:04 MST")
    parse("2013-02-03 19:54 ChST", "2006-01-02 15:04 MST")
    parse("2013-02-03 19:54 WITA", "2006-01-02 15:04 MST")
    parse("2013-02-03 19:54 AEDT", "2006-01-02 15:04 MST", "Australia/Sydney")
    parse("2013-02-03 19:54", "2006-01-02 15:04", "Europe/Berlin")
    parse("2013-07-03 19:54", "2006-01-02 15:04", "Europe/Berlin")
    parse("2013-07-03 19:54 +0200", "2006-01-02 15:04 -0700", "Europe/Berlin")
    parse("2013-07-03 19:54 +0100", "2006-01-02 15:04 -0700", "Europe/Berlin")
    parse("2013-07-03 19:54 -07", "2006-01-02 15:04 -07", "America/Los_Angeles")
    parse("2013-07-03 19:54 +053045", "2006-01-02 15:04 -070000")
    parse("2013-07-03 19:54 -05:30:45", "2006-01-02 15:04 -07:00:00")
    parse("2013-07-03 19:54 Z", "2006-01-02 15:04 Z07:00:00")
    parse("2013-07-03 19:54 +2460", "2006-01-02 15:04 Z0700")
    parse("2013 185", "2006 002")
    parse("2012 060", "2006 002")
    parse("2012 366", "2006 002")
    parse("2012   5", "2006 __2")
    parse("2012 185 July", "2006 002 January")
    parse("69 68", "06 06")
    parse("  7  ", " 2 ")
    parse("1/2/2006", "1/2/2006")
    parse("01:02:03.5", "15:04:05")
    parse("010203", "150405")
    parse("2006-01-02T15:04:05.999999999Z", "2006-01-02T15:04:05.999999999Z07:00")
    parse("x2020", "x2006", location = "Asia/Kolkata")
    parse(x = "20200102", format = "20060102", location = "UTC")
    show(time.parse_time("2020-06-26T17:38:36Z") == time.from_timestamp(1593193116), time.parse_time("0001-01-01T00:00:00Z"), bool(time.parse_time("0001-01-01T00:00:00Z")))

    # methods as values, attributes
    f = t.format
    g = time.parse_duration
    show(f("2006"), g("3s"), [fn("1m") for fn in [time.parse_duration]], f == t.format, f == u.format, hasattr(t, "year"), hasattr(t, "format"), hasattr(t, "nope"), hasattr(time, "now"), hasattr(time.second, "hours"), hasattr(time.second, "nope"))
    show(getattr(t, "unix"), getattr(time, "second"), getattr(time.minute, "seconds"), getattr(t, "nope", "default"), getattr(time.minute, "nope", None), type(t) + "/" + type(time.second), str(time.second) + repr(time.second), "%s %r" % (t, time.minute), [t, time.hour], {"k": t})

main()
