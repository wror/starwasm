# builtins.star — the types of Starlark's builtin functions and methods,
# written in the checker's own type language (typecheck/stubs.star).
#
# A method is declared as a function of its receiver, `self`. Builtins
# whose types don't fit one signature (struct, getattr, min, max, zip,
# dict, d.get(k, default), ...) are also handled where they are called
# (typecheck/infer.star, SPECIAL); the signatures here are what they have
# when used as values.

load("stubs.star", "declare_tparams", "new_scope", "parse_stubs", "to_params", "to_type")
load("types.star", "GENERIC", "fn")

FUNCTIONS = """
def len[X: Sized](x: X) -> int
def str(x: Any) -> str
def repr(x: Any) -> str
def type(x: Any) -> str
def bool(x: Any = ...) -> bool
def int(x: Any, base: int = ...) -> int
def float(x: Any = ...) -> float
def bytes(x: Any) -> bytes
def print(*args: Any, sep: str = ...) -> None
def fail(*args: Any, sep: str = ...) -> None
def list[X: Iterable[T], T](x: X = ...) -> list[T]
def tuple[X: Iterable[T], T](x: X = ...) -> tuple[T, ...]
def set[X: Iterable[T], T](x: X = ...) -> set[T]
def sorted[X: Iterable[T], T](x: X, *, key: (T) -> Any = ..., reverse: bool = ...) -> list[T]
def reversed[X: Iterable[T], T](x: X) -> list[T]
def enumerate[X: Iterable[T], T](x: X, start: int = ...) -> list[tuple[int, T]]
def any[X: Iterable[T], T](x: X) -> bool
def all[X: Iterable[T], T](x: X) -> bool
def range(start_or_stop: int, stop: int = ..., step: int = ...) -> range
def abs[T: (int, float)](x: T) -> T
def chr(i: int) -> str
def ord(c: Any) -> int
def hash(x: Any) -> int
def dir(x: Any = ...) -> list[str]
def hasattr(x: Any, name: str) -> bool
def getattr(x: Any, name: str, default: Any = ...) -> Any
def struct(**kwargs: Any) -> Any
def min(*args: Any, key: Any = ...) -> Any
def max(*args: Any, key: Any = ...) -> Any
def zip(*args: Any) -> list[Any]
def dict(*args: Any, **kwargs: Any) -> dict[Any, Any]
def read_file(path: str) -> str
def write_file(path: str, data: Any) -> None
argv: list[str]
proto: Any
"""

METHODS = {
    "str": """
def capitalize(self: str) -> str
def codepoint_ords(self: str) -> list[int]
def codepoints(self: str) -> list[str]
def count(self: str, sub: str, start: int | None = ..., end: int | None = ...) -> int
def elem_ords(self: str) -> list[int]
def elems(self: str) -> list[str]
def endswith(self: str, suffix: Any, start: int | None = ..., end: int | None = ...) -> bool
def find(self: str, sub: str, start: int | None = ..., end: int | None = ...) -> int
def format(self: str, *args: Any, **kwargs: Any) -> str
def index(self: str, sub: str, start: int | None = ..., end: int | None = ...) -> int
def isalnum(self: str) -> bool
def isalpha(self: str) -> bool
def isdigit(self: str) -> bool
def islower(self: str) -> bool
def isspace(self: str) -> bool
def istitle(self: str) -> bool
def isupper(self: str) -> bool
def join[X: Iterable[str]](self: str, elements: X) -> str
def lower(self: str) -> str
def lstrip(self: str, chars: str | None = ...) -> str
def partition(self: str, sep: str) -> tuple[str, str, str]
def removeprefix(self: str, prefix: str) -> str
def removesuffix(self: str, suffix: str) -> str
def replace(self: str, old: str, new: str, count: int = ...) -> str
def rfind(self: str, sub: str, start: int | None = ..., end: int | None = ...) -> int
def rindex(self: str, sub: str, start: int | None = ..., end: int | None = ...) -> int
def rpartition(self: str, sep: str) -> tuple[str, str, str]
def rsplit(self: str, sep: str | None = ..., maxsplit: int = ...) -> list[str]
def rstrip(self: str, chars: str | None = ...) -> str
def split(self: str, sep: str | None = ..., maxsplit: int = ...) -> list[str]
def splitlines(self: str, keepends: bool = ...) -> list[str]
def startswith(self: str, prefix: Any, start: int | None = ..., end: int | None = ...) -> bool
def strip(self: str, chars: str | None = ...) -> str
def title(self: str) -> str
def upper(self: str) -> str
""",
    "list": """
def append[T](self: list[T], x: T) -> None
def clear[T](self: list[T]) -> None
def extend[T, X: Iterable[T]](self: list[T], x: X) -> None
def index[T](self: list[T], x: T, start: int | None = ..., end: int | None = ...) -> int
def insert[T](self: list[T], i: int, x: T) -> None
def pop[T](self: list[T], i: int = ...) -> T
def remove[T](self: list[T], x: T) -> None
""",
    "dict": """
def clear[K, V](self: dict[K, V]) -> None
def get[K, V](self: dict[K, V], key: K, default: V | None = ...) -> V | None
def items[K, V](self: dict[K, V]) -> list[tuple[K, V]]
def keys[K, V](self: dict[K, V]) -> list[K]
def pop[K, V](self: dict[K, V], key: K, default: V = ...) -> V
def popitem[K, V](self: dict[K, V]) -> tuple[K, V]
def setdefault[K, V](self: dict[K, V], key: K, default: V = ...) -> V
def update[K, V](self: dict[K, V], *args: Any, **kwargs: V) -> None
def values[K, V](self: dict[K, V]) -> list[V]
""",
    "set": """
def add[T](self: set[T], x: T) -> None
def clear[T](self: set[T]) -> None
def difference[T, X: Iterable[T]](self: set[T], other: X) -> set[T]
def discard[T](self: set[T], x: T) -> None
def intersection[T, X: Iterable[T]](self: set[T], other: X) -> set[T]
def issubset[T, X: Iterable[T]](self: set[T], other: X) -> bool
def issuperset[T, X: Iterable[T]](self: set[T], other: X) -> bool
def pop[T](self: set[T]) -> T
def remove[T](self: set[T], x: T) -> None
def symmetric_difference[T, X: Iterable[T]](self: set[T], other: X) -> set[T]
def union[T](self: set[T], *others: Any) -> set[T]
def update[T](self: set[T], *others: Any) -> None
""",
    "bytes": """
def elems(self: bytes) -> list[int]
""",
}

def _scheme(st, d, file):
    cv = new_scope(st, file, {}, GENERIC)
    declare_tparams(cv, d["tparams"], GENERIC)
    return fn(to_params(cv, d["params"], None), to_type(cv, d["ret"]), {"file": file, "pos": d["pos"], "role": "builtin " + d["name"]})

def load_builtins(st):
    """Fill st["methods"] and st["owners"], and return the builtin
    functions and values: name -> ("def" | "var", type)."""
    out = {}
    file = "<builtins>"
    for d in parse_stubs(FUNCTIONS, file):
        if d["d"] == "def":
            out[d["name"]] = ("def", _scheme(st, d, file))
        else:
            out[d["name"]] = ("var", to_type(new_scope(st, file, {}, GENERIC), d["type"]))
    methods = {}
    owners = {}
    for tyname, text in METHODS.items():
        ms = {}
        for d in parse_stubs(text, "<builtins:" + tyname + ">"):
            ms[d["name"]] = _scheme(st, d, "<builtins:" + tyname + ">")
            owners.setdefault(d["name"], []).append(tyname)
        methods[tyname] = ms
    st["methods"] = methods
    st["owners"] = owners
    return out
