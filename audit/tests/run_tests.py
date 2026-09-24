"""Compile the suite and run isolated offline regressions using system Lua 5.4.

Usage: python3 audit/tests/run_tests.py [test_filename.lua ...]
No game client, account or third-party Python package is required.
"""
import ctypes as C
import ctypes.util
import json
from pathlib import Path
import sys

TEST_DIR = Path(__file__).resolve().parent
SUITE_ROOT = TEST_DIR.parents[1]
library = ctypes.util.find_library("lua5.4")
if not library:
    raise SystemExit("Install the Lua 5.4 shared library to run these offline tests.")
lua = C.CDLL(library)


def bind(name, result, *args):
    function = getattr(lua, name)
    function.restype, function.argtypes = result, args
    return function


new = bind("luaL_newstate", C.c_void_p)
libs = bind("luaL_openlibs", None, C.c_void_p)
loadfile = bind("luaL_loadfilex", C.c_int, C.c_void_p, C.c_char_p, C.c_char_p)
loadstring = bind("luaL_loadstring", C.c_int, C.c_void_p, C.c_char_p)
call = bind("lua_pcallk", C.c_int, C.c_void_p, C.c_int, C.c_int, C.c_int, C.c_longlong, C.c_void_p)
string = bind("lua_tolstring", C.c_char_p, C.c_void_p, C.c_int, C.c_void_p)
settop = bind("lua_settop", None, C.c_void_p, C.c_int)
close = bind("lua_close", None, C.c_void_p)


def check(state, result):
    if result:
        message = string(state, -1, None)
        raise RuntimeError(message.decode("utf-8", "replace") if message else "Lua error")


def compile_suite():
    state = new()
    try:
        paths = sorted(path for path in SUITE_ROOT.rglob("*.lua") if "audit" not in path.relative_to(SUITE_ROOT).parts)
        for path in paths:
            check(state, loadfile(state, str(path).encode(), None))
            settop(state, 0)
        print(f"PASS: {len(paths)} runtime Lua files compile with Lua 5.4", flush=True)
    finally:
        close(state)


def run_test(path):
    state = new()
    try:
        libs(state)
        check(state, loadstring(state, ("SUITE_ROOT=" + json.dumps(str(SUITE_ROOT), ensure_ascii=False)).encode()))
        check(state, call(state, 0, 0, 0, 0, None))
        check(state, loadfile(state, str(path).encode(), None))
        check(state, call(state, 0, 0, 0, 0, None))
        print(f"PASS: {path.name}", flush=True)
    finally:
        close(state)


if __name__ == "__main__":
    compile_suite()
    tests = [Path(arg) if Path(arg).is_file() else TEST_DIR / arg for arg in sys.argv[1:]] if len(sys.argv) > 1 else sorted(TEST_DIR.glob("test_*.lua"))
    failures = []
    for test in tests:
        try:
            run_test(test)
        except Exception as exc:
            failures.append(test.name)
            print(f"FAIL: {test.name}: {exc}", file=sys.stderr, flush=True)
    print(f"Offline test files: {len(tests) - len(failures)} passed, {len(failures)} failed", flush=True)
    sys.exit(bool(failures))
