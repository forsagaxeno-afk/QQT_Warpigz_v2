"""Compile the suite and run isolated offline regressions.

QQT executes plugins with LuaJIT (Lua 5.1 rules: 60 upvalues per function,
no table.unpack/table.pack/math.type/utf8). Every test therefore runs twice
when possible: in-process with the Lua 5.4 shared library and, as the
host-compatible check, with the `luajit` executable.

Usage: python3 audit/tests/run_tests.py [--luajit auto|require|off] [test_filename.lua ...]
No game client, account or third-party Python package is required.
"""
import argparse
import ctypes as C
import ctypes.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

TEST_DIR = Path(__file__).resolve().parent
SUITE_ROOT = TEST_DIR.parents[1]
# LuaJIT/Lua 5.1 hard limit is 60. Warn early so later edits keep a margin.
UPVALUE_LIMIT, UPVALUE_WARN = 60, 50
# Lua 5.1/LuaJIT also allow at most 200 locals in one function.
LOCALS_WARN = 190
# Lua 5.2+ library functions absent from the QQT (LuaJIT) runtime. A use is
# accepted only with an explicit 5.1 fallback such as `table.unpack or unpack`.
HOST_MISSING = re.compile(r"\b(table\.unpack|table\.pack|math\.type|math\.tointeger|math\.ult|utf8\.|string\.pack|string\.unpack|string\.packsize|coroutine\.isyieldable|coroutine\.close|rawlen)\b")
FALLBACK = re.compile(r"table\.unpack\s+or\s+unpack")

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


def runtime_sources():
    return sorted(path for path in SUITE_ROOT.rglob("*.lua") if "audit" not in path.relative_to(SUITE_ROOT).parts)


def compile_suite():
    state = new()
    try:
        paths = runtime_sources()
        for path in paths:
            check(state, loadfile(state, str(path).encode(), None))
            settop(state, 0)
        print(f"PASS: {len(paths)} runtime Lua files compile with Lua 5.4", flush=True)
    finally:
        close(state)


def scan_host_library():
    problems = []
    for path in runtime_sources():
        for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            code = line.split("--", 1)[0]
            for match in HOST_MISSING.finditer(code):
                if match.group(1) == "table.unpack" and FALLBACK.search(code):
                    continue
                problems.append(f"{path.relative_to(SUITE_ROOT)}:{number}: {match.group(1)} is unavailable in QQT's LuaJIT runtime")
    if problems:
        raise RuntimeError("\n".join(problems))
    print("PASS: runtime code uses no Lua 5.2+ library function without a LuaJIT fallback", flush=True)


def report_upvalues():
    """Lua 5.4 listings include _ENV, which LuaJIT does not capture."""
    luac = shutil.which("luac5.4")
    if not luac:
        print("SKIP: upvalue margin report (luac5.4 not installed)", flush=True)
        return
    worst, warnings, errors = 0, [], []
    for path in runtime_sources():
        listing = subprocess.run([luac, "-l", "-l", "-p", str(path)], capture_output=True, text=True).stdout
        functions, section = [], None
        for line in listing.splitlines():
            if line.startswith(("main <", "function <")):
                functions.append([line.split()[1].replace(str(SUITE_ROOT) + "/", ""), []])
                section = None
            elif " params, " in line and functions and functions[-1][0].endswith(":0,0>"):
                # File-level locals stay active to the end of the chunk.
                declared = re.search(r"(\d+) locals?", line)
                if declared and int(declared.group(1)) > LOCALS_WARN:
                    warnings.append(f"{functions[-1][0]} declares {declared.group(1)} file-level locals (LuaJIT limit 200)")
            elif line.startswith(("constants (", "locals (", "upvalues (")):
                section = line.split()[0]
            elif section == "upvalues" and functions:
                parts = line.split()
                if len(parts) > 1 and parts[0].isdigit():
                    functions[-1][1].append(parts[1])
        for function, names in functions:
            count = len([name for name in names if name != "_ENV"])
            worst = max(worst, count)
            where = f"{function} has {count} upvalues (limit {UPVALUE_LIMIT}, keep <= {UPVALUE_WARN})"
            if count > UPVALUE_LIMIT:
                errors.append(where)
            elif count > UPVALUE_WARN:
                warnings.append(where)
    for where in warnings:
        print(f"WARN: {where}; keep a margin below the LuaJIT limits", flush=True)
    if errors:
        raise RuntimeError("Functions exceed the LuaJIT upvalue limit:\n" + "\n".join(errors))
    print(f"PASS: largest function captures {worst} upvalues (LuaJIT limit {UPVALUE_LIMIT})", flush=True)


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


LUAJIT_COMPILE = r"""
local bad = 0
for path in io.lines() do
    local chunk, err = loadfile(path)
    if not chunk then bad = bad + 1; io.stderr:write(err, '\n') end
end
os.exit(bad == 0 and 0 or 1)
"""


def luajit_compile(luajit):
    paths = runtime_sources()
    result = subprocess.run([luajit, "-e", LUAJIT_COMPILE], input="\n".join(map(str, paths)) + "\n",
                            capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "LuaJIT compile failed")
    print(f"PASS: {len(paths)} runtime Lua files compile with LuaJIT (QQT runtime)", flush=True)


def luajit_test(luajit, path):
    prelude = "SUITE_ROOT=" + json.dumps(str(SUITE_ROOT), ensure_ascii=False)
    result = subprocess.run([luajit, "-e", prelude, str(path)], capture_output=True, text=True, cwd=SUITE_ROOT)
    if result.returncode:
        lines = [line for line in (result.stderr or result.stdout).splitlines() if line.strip()]
        raise RuntimeError("\n".join(lines[:6]) or "LuaJIT test failed")
    print(f"PASS (LuaJIT): {path.name}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run the offline suite")
    parser.add_argument("--luajit", choices=["auto", "require", "off"], default="auto",
                        help="host-compatible LuaJIT pass (default: run when installed)")
    parser.add_argument("tests", nargs="*")
    options = parser.parse_args()
    failures = []
    for label, step in (("Lua 5.4 compile", compile_suite), ("host library scan", scan_host_library),
                        ("upvalue limit", report_upvalues)):
        try:
            step()
        except Exception as exc:
            failures.append(label)
            print(f"FAIL: {label}: {exc}", file=sys.stderr, flush=True)
    luajit = shutil.which("luajit") if options.luajit != "off" else None
    if options.luajit == "require" and not luajit:
        raise SystemExit("LuaJIT is required (--luajit require) but `luajit` is not installed.")
    if luajit:
        try:
            luajit_compile(luajit)
        except Exception as exc:
            failures.append("LuaJIT compile")
            print(f"FAIL: LuaJIT compile: {exc}", file=sys.stderr, flush=True)
    elif options.luajit == "auto":
        print("WARN: `luajit` not installed — the QQT-compatible runtime was NOT checked", flush=True)
    tests = [Path(arg) if Path(arg).is_file() else TEST_DIR / arg for arg in options.tests] if options.tests else sorted(TEST_DIR.glob("test_*.lua"))
    runs = 0
    for test in tests:
        runners = [("Lua 5.4", run_test)] + ([("LuaJIT", lambda path: luajit_test(luajit, path))] if luajit else [])
        for runtime, runner in runners:
            runs += 1
            try:
                runner(test)
            except Exception as exc:
                failures.append(f"{test.name} [{runtime}]")
                print(f"FAIL [{runtime}]: {test.name}: {exc}", file=sys.stderr, flush=True)
    runtimes = "Lua 5.4 + LuaJIT" if luajit else "Lua 5.4 only"
    print(f"Offline test files: {len(tests)} files x {runtimes}; {runs - len([f for f in failures if '[' in f])} runs passed, {len(failures)} failures", flush=True)
    if failures:
        print("Failures: " + ", ".join(failures), file=sys.stderr, flush=True)
    sys.exit(bool(failures))
