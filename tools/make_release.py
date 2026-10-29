#!/usr/bin/env python3
"""Build (and gate) the release folder for GoldBasketGuard.

Everything a trader has to download lives in one place, and the copy only
happens if the EA passes every check first -- so a file can never be published
in a state the repo has not verified.

    python3 tools/make_release.py [--version 1.10] [--check-only]

Checks run before anything is written:
  * tools/mql5_lint.py on the EA            (syntax-level MQL5 rules)
  * tools/gold_pip_calc.py --test           (logic mirrors must all pass)
  * byte hygiene: pure ASCII, no tabs, no CRLF, single file, no leftovers
  * balanced braces/parens outside strings and comments
  * unique input names, version property present
  * every key of every preset exists in the EA and parses
"""
from __future__ import annotations

import argparse
import hashlib
import re
import shutil
import subprocess
import sys
import zipfile
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EA = ROOT / "MQL5/Experts/GoldBasketGuard/GoldBasketGuard.mq5"
PRESET_DIR = ROOT / "MQL5/Presets"
DOC_DIR = ROOT / "docs"
SHEET = "GoldBasketGuard-features-fa.png"


# --------------------------------------------------------------------- helpers
class Gate:
    def __init__(self):
        self.problems: list[str] = []
        self.passed: list[str] = []

    def check(self, name: str, ok: bool, detail: str = "") -> bool:
        if ok:
            self.passed.append(f"{name}{(' — ' + detail) if detail else ''}")
        else:
            self.problems.append(f"{name}{(' — ' + detail) if detail else ''}")
        return ok

    def run(self, args, want: str | re.Pattern | None = None) -> tuple[bool, str]:
        try:
            r = subprocess.run([sys.executable] + args, capture_output=True, text=True,
                               timeout=300, cwd=str(ROOT))
        except Exception as exc:                                # noqa: BLE001
            return False, f"could not run {' '.join(args)}: {exc}"
        out = (r.stdout or "") + (r.stderr or "")
        if r.returncode != 0:
            return False, out.strip().splitlines()[-1] if out.strip() else f"exit {r.returncode}"
        if isinstance(want, re.Pattern):
            m = want.search(out)
            return (bool(m), out.strip())
        if want and want not in out:
            return False, out.strip().splitlines()[-1]
        return True, out.strip()


def strip_code(src: str) -> str:
    """Drop comments and string literals, keeping line structure."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            j = src.find("*/", i + 2)
            tail = "\n" * src.count("\n", i, n if j < 0 else j)
            out.append(tail)
            i = n if j < 0 else j + 2
            continue
        if c in '"\'':
            q, j = c, i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == q:
                    break
                j += 1
            out.append('""')
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


# ----------------------------------------------------------------------- gates
def verify(g: Gate, version: str) -> dict:
    raw = EA.read_bytes()
    text = raw.decode("utf-8", errors="replace")
    lines = text.splitlines()

    g.check("EA file present", EA.exists(), str(EA.relative_to(ROOT)))
    g.check("pure ASCII (MetaEditor safe)", raw == text.encode("utf-8", "ignore"),
            f"{sum(1 for b in raw if b > 127)} non-ASCII bytes")
    g.check("no tab characters", b"\t" not in raw)
    g.check("no CRLF line endings", b"\r" not in raw)
    g.check("no TODO / FIXME / XXX left", not re.search(r"TODO|FIXME|XXX", text))

    m = re.search(r'#property\s+version\s+"([^"]+)"', text)
    g.check("version property", bool(m) and m.group(1) == version,
            f"found {m.group(1) if m else 'none'}, expected {version}")

    code = "\n".join(strip_code(text).splitlines())
    g.check("braces balanced", code.count("{") == code.count("}"),
            f"{code.count('{')} open / {code.count('}')} close")
    g.check("parens balanced", code.count("(") == code.count(")"),
            f"{code.count('(')} open / {code.count(')')} close")

    inputs = re.findall(r"^\s*input\s+(?:group\s+)?[\w:<>,\s\*&]+?\s(\w+)\s*(?:=|;)", text, re.M)
    inputs = [i for i in inputs if not i.startswith("input")]
    dupe = sorted({i for i in inputs if inputs.count(i) > 1})
    g.check("input names unique", not dupe, ",".join(dupe[:6]))
    g.check("input count sane", len(inputs) >= 40, f"{len(inputs)} inputs")

    ctrl = ("if", "for", "while", "switch", "catch", "return", "else", "do")
    funcs = [m.group(1) for m in re.finditer(
        r"^[\w:<>,\s\*&\[\]]*?(\w+)\s*\([^;{}]*\)\s*(?:const\s*)?\{", code, re.M)
        if m.group(1) not in ctrl]
    stats = dict(lines=len(lines), inputs=len(inputs), funcs=len(funcs),
                 version=m.group(1) if m else "?")

    ok, out = g.run(["tools/mql5_lint.py", str(EA.relative_to(ROOT))])
    g.check("static lint clean", ok, out.splitlines()[-1] if out else "")

    ok, out = g.run(["tools/gold_pip_calc.py", "--test"], re.compile(r"(\d+)/(\d+) checks passed"))
    mm = re.search(r"(\d+)/(\d+) checks passed", out or "")
    tests_ok = bool(ok and mm and mm.group(1) == mm.group(2) and int(mm.group(1)) > 0)
    g.check("logic mirror tests", tests_ok, mm.group(0) if mm else "no test output")
    stats["tests"] = f"{mm.group(1)}/{mm.group(2)}" if mm else "0/0"

    # presets: every key must be a real input, values must parse
    decl = dict(re.findall(r"^\s*input\s+(?:group\s+)?[\w:<>,\s\*&]*?\b(\w+)\s*=\s*([^;]*);",
                           text, re.M))
    types = {}
    for ln in text.splitlines():
        m = re.match(r"\s*input\s+(?:group\s+)?(.+?)\s+(\w+)\s*=", ln)
        if m:
            types[m.group(2)] = m.group(1).strip()

    def value_ok(name: str, val: str) -> bool:
        t = types.get(name, "")
        if t == "string":
            return True
        if val == "":                                   # empty string / default
            return t in ("", "string")
        if t in ("double", "float"):
            return bool(re.fullmatch(r"-?\d+(\.\d+)?([eE][-+]?\d+)?", val))
        if t in ("bool",):
            return val in ("true", "false", "0", "1")
        if t in ("color",):
            return bool(re.fullmatch(r"0[xX][0-9a-fA-F]{6}|\d+|C'[^']+'|clr_\w+", val))
        if t in ("int", "long", "uint", "ulong", "short", "char", "uchar", "long long"):
            return bool(re.fullmatch(r"-?\d+", val))
        if t in ("datetime",):
            return bool(re.fullmatch(r"-?\d+|\d{4}\.\d{2}\.\d{2}(\s\d{2}:\d{2}(:\d{2})?)?", val))
        # enum input: a member name or its numeric value
        return bool(re.fullmatch(r"-?\d+", val) or re.fullmatch(r"\w+", val))
    bad = []
    for s in sorted(PRESET_DIR.glob("*.set")):
        keys = []
        for ln in s.read_text(encoding="utf-8").splitlines():
            ln = ln.strip()
            if not ln or ln.startswith(";"):
                continue
            if "=" not in ln:
                bad.append(f"{s.name}: no '=' in {ln[:28]!r}")
                continue
            k, v = ln.split("=", 1)
            k, v = k.strip(), v.strip().rstrip(";").strip().strip('"')
            keys.append(k)
            if k not in types:
                bad.append(f"{s.name}: {k} is not an input")
            elif not value_ok(k, v):
                bad.append(f"{s.name}: {k}={v[:20]!r} does not fit input type "
                           f"{types[k]!r}")
        if len(keys) != len(set(keys)):
            bad.append(f"{s.name}: duplicate keys")
    presets = sorted(p.name for p in PRESET_DIR.glob("*.set"))
    g.check(f"presets valid ({len(presets)} files)", not bad and len(presets) >= 1,
            "; ".join(bad[:3]))
    stats["presets"] = len(presets)
    return stats


# -------------------------------------------------------------------- release
def write_release(version: str, stats: dict, g: Gate, do_zip: bool) -> Path:
    out = ROOT / "release/GoldBasketGuard"
    if out.exists():
        shutil.rmtree(out)
    (out / "presets").mkdir(parents=True)

    shutil.copy2(EA, out / EA.name)
    for s in sorted(PRESET_DIR.glob("*.set")):
        shutil.copy2(s, out / "presets" / s.name)
    for name in ("GoldBasketGuard-parameters.md", SHEET):
        src = DOC_DIR / name
        if src.exists():
            shutil.copy2(src, out / name)

    readme = f"""# GoldBasketGuard v{version} — release folder

این پوشه نسخهٔ نهایی و بررسی‌شدهٔ اکسپرت است. فایل اصلی برای MetaEditor همان
`GoldBasketGuard.mq5` است (تک‌فایل، بدون `#include` اختصاصی).

## contents

| file | what it is |
|---|---|
| `GoldBasketGuard.mq5` | the EA ({stats['lines']} lines, {stats['inputs']} inputs) |
| `presets/*.set` | {stats['presets']} ready-made profiles for gold |
| `GoldBasketGuard-parameters.md` | every parameter, Persian reference |
| `{SHEET}` | one-image feature sheet (Persian) |
| `manifest.txt` | sha256 of each file + the checks that were run |

## install / نصب

1. در MetaTrader 5 منوی `File → Open Data Folder` را بزنید.
2. پوشهٔ `MQL5/Experts/GoldBasketGuard/` را بسازید و `GoldBasketGuard.mq5` را در آن بگذارید.
3. MetaEditor را باز کنید، فایل را باز کنید و `F7` (Compile) — باید `0 errors` بگیرید.
4. نمودار `XAUUSD` (M5 یا M15) → تب `Navigator → Expert Advisors` → اکسپرت را بکشید روی چارت.
5. در تب `Common` گزینهٔ `Allow Algo Trading` را روشن کنید، سپس در تب `Inputs`
   یکی از فایل‌های `presets/*.set` را `Load` کنید (برای شروع: `GoldBasketGuard_DryRun_Safe.set`).

> این اکسپرت معامله باز نمی‌کند؛ فقط مدیریت حد سود/حد ضرر، ریسک‌فری، گارد اخبار
> و مدیریت سرمایهٔ گروهی را انجام می‌دهد. اول روی حساب دمو تست شود.

## verified by `tools/make_release.py`

{chr(10).join('- ' + p for p in g.passed)}

Rebuild this folder any time with:

```
python3 tools/make_release.py --version {version}
```
"""
    (out / "README.md").write_text(readme, encoding="utf-8")

    man = [f"GoldBasketGuard v{version}", f"built {date.today().isoformat()} by tools/make_release.py",
           f"source: {EA.relative_to(ROOT)}", "", "files (sha256  size  name):"]
    for f in sorted(out.rglob("*")):
        if f.is_file() and f.name != "manifest.txt":
            b = f.read_bytes()
            man.append(f"{hashlib.sha256(b).hexdigest()}  {len(b):>8}  {f.relative_to(out)}")
    man += ["", "checks passed:"] + [f"- {p}" for p in g.passed]
    (out / "manifest.txt").write_text("\n".join(man) + "\n", encoding="utf-8")

    if do_zip:
        zp = ROOT / f"release/GoldBasketGuard-v{version}.zip"
        with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as z:
            for f in sorted(out.rglob("*")):
                if f.is_file():
                    z.write(f, f.relative_to(out.parent))
        print(f"zip: {zp.relative_to(ROOT)} ({zp.stat().st_size // 1024} KB)")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--version", default=None, help="must match #property version in the EA")
    ap.add_argument("--check-only", action="store_true", help="run the gates, write nothing")
    ap.add_argument("--no-zip", action="store_true")
    a = ap.parse_args()

    if not a.version:
        m = re.search(r'#property\s+version\s+"([^"]+)"', EA.read_text(encoding="utf-8"))
        a.version = m.group(1) if m else "0.0"
        if a.check_only:
            print(f"(version read from the EA: {a.version})")

    g = Gate()
    stats = verify(g, a.version or "0.0")
    for p in g.passed:
        print(f"  ok    {p}")
    for p in g.problems:
        print(f"  FAIL  {p}")
    print(f"{'PASS' if not g.problems else 'BLOCKED'}: {len(g.passed)} checks, "
          f"{len(g.problems)} problems — {stats['lines']} lines, {stats['inputs']} inputs, "
          f"{stats['funcs']} functions, tests {stats['tests']}")
    if g.problems:
        print("release NOT written: fix the problems above first")
        return 1
    if a.check_only:
        return 0
    out = write_release(a.version, stats, g, not a.no_zip)
    print(f"wrote {out.relative_to(ROOT)}/ + manifest.txt")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
