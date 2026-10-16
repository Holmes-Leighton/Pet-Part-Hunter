#!/usr/bin/env python3
"""Run the pure-logic Luau tests with the `luau` CLI.

Usage:  python tests/run_tests.py            (all tests/test_*.lua)
        python tests/run_tests.py tests/test_maze.lua
Set LUAU=/path/to/luau.exe if `luau` is not on PATH. Also runs luau-analyze (set LUAU_ANALYZE) over src/ and tests/.
"""
import glob, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUAU = os.environ.get("LUAU", "luau")
ANALYZE = os.environ.get("LUAU_ANALYZE", "luau-analyze")


def run_test(path):
    r = subprocess.run([LUAU, path], cwd=ROOT, capture_output=True, text=True, encoding="utf8", errors="replace")
    print("=== " + os.path.relpath(path, ROOT))
    print((r.stdout + r.stderr).rstrip())
    return r.returncode == 0


def analyze():
    files = sorted(glob.glob(os.path.join(ROOT, "src", "Shared", "*.lua")) + glob.glob(os.path.join(ROOT, "tests", "*.lua")))
    r = subprocess.run([ANALYZE] + files, cwd=ROOT, capture_output=True, text=True, encoding="utf8", errors="replace")
    out = (r.stdout + r.stderr).strip()
    print("=== luau-analyze (src/Shared, tests)")
    print(out if out else "  clean")
    return r.returncode == 0


def main():
    targets = sys.argv[1:] or sorted(glob.glob(os.path.join(ROOT, "tests", "test_*.lua")))
    results = [run_test(t) for t in targets]
    if not sys.argv[1:]:
        results.append(analyze())
    ok = all(results)
    print("\nALL PASSED" if ok else "\nFAILURES")
    sys.exit(0 if ok else 1)


main()
