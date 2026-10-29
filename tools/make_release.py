#!/usr/bin/env python3
"""Build (and gate) the release folder for GoldBasketGuard.

Everything a trader has to download lives in one place, and the copy only
happens if the EA passes every check first -- so a file can never be published
in a state the repo has not verified.

    python3 tools/make_release.py [--check-only] [--no-zip]

Checks run before anything is written:
  * tools/mql5_lint.py on the EA            (syntax-level MQL5 rules)
  * tools/gold_pip_calc.py --test           (logic mirrors must all pass)
  * byte hygiene: pure ASCII, no tabs, no CRLF, single file, no leftovers
  * balanced braces/parens outside strings and comments
  * unique input names, version property present
  * the zero-config contract: attaching the EA with NO changes must already
    give the gold setup and every protection -- which is why there are no
    preset files to load
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
DOC_DIR = ROOT / "docs"
SHEETS = ("GoldBasketGuard-features-fa.png", "GoldBasketGuard-flow-fa.png")

# What the EA must already do out of the box. A default drifting away from this
# list means "you now need a preset file again", which is exactly what this
# project decided against -- so the gate fails instead of shipping silently.
DEFAULTS_CONTRACT = [
    ("InpPipSize", "0.0", "pip size auto-detected from digits"),
    ("InpMoneyBasis", "MONEY_AUTO", "cent vs dollar account auto-detected"),
    ("InpOnlyThisChartSymbol", "true", "group = this chart's symbol"),
    ("InpMagicFilter", "0", "no magic filter: catches manual trades too"),
    ("InpIncludeBuy", "true", "buy legs in the group"),
    ("InpIncludeSell", "true", "sell legs in the group"),
    ("InpOnlyAfterAttach", "false", "existing positions are adopted at once"),
    ("InpAutoApplyOnStart", "true", "levels applied on OnInit"),
    ("InpAutoApplyToNew", "true", "every new ticket joins the group"),
    ("InpOverwriteExisting", "true", "existing SL/TP are aligned, not skipped"),
    ("InpMirrorSL", "true", "a manual SL drag is mirrored to the whole group"),
    ("InpMirrorTP", "true", "a manual TP drag is mirrored to the whole group"),
    ("InpTimerMs", "100", "100 ms loop: sub-second reaction instead of 1 s"),
    ("InpInstantMirror", "true", "trade events are answered inside the event itself"),
    ("InpMirrorGuardMs", "250", "own echo suppressed by value, never by a blind seconds window"),
    ("InpMinMsPerTicket", "0", "no cool-down between two modifications of a ticket"),
    ("InpMaxModsPerSecond", "25", "fast enough to bring a whole basket in line in one cycle"),
    ("InpSLPips", "300.0", "group stop 300 pips on gold"),
    ("InpTPPips", "500.0", "group target 500 pips on gold"),
    ("InpBeMode", "BE_BASKET_PIPS", "risk-free armed on the basket"),
    ("InpBeTriggerPips", "200.0", "risk-free after 200 pips"),
    ("InpBeLockPips", "10.0", "locked 10 pips beyond entry"),
    ("InpTrailMode", "TRAIL_STEP", "step trailing on"),
    ("InpTrailStartPips", "250.0", "trailing starts at 250 pips"),
    ("InpNewsEnabled", "true", "red-folder news guard on"),
    ("InpNewsImportance", "CALENDAR_IMPORTANCE_HIGH", "only HIGH impact events"),
    ("InpNewsCurrencies", "", "currency derived from the symbol"),
    ("InpNewsAction", "NEWS_WARN", "red-folder news warns - by default it closes nothing"),
    ("InpNewsPauseAutomation", "false", "mirroring / risk-free keep running inside a news window"),
    ("InpEnableKillSwitch", "false", "no close-all on group drawdown - only the account breaker closes"),
    ("InpMaxDrawdownPctEquity", "60.0", "if that switch is armed, it sits on the same 60% line"),
    ("InpCloseAllOnKill", "true", "and when armed it closes, not just pauses"),
    ("InpRiskWarnPct", "40.0", "40% of the balance in floating loss = warning only, no orders"),
    ("InpEmergencyFloatLossPct", "60", "close all only when 60% of the account is at risk"),
    ("InpEmergencyMarginLevelPct", "0", "margin level never forces a close by default"),
    ("InpEmergencyLockHours", "24", "EA stays locked after an emergency"),
    ("InpAdaptiveStops", "true", "widens the guard when the broker rejects"),
    ("InpDryRun", "false", "live by default (demo is the user's choice)"),
]


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
            return (bool(want.search(out)), out.strip())
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
            out.append("\n" * src.count("\n", i, n if j < 0 else j))
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


def input_defaults(text: str) -> dict:
    """{'InpSLPips': '300.0', ...} for every `input <type> Name = value;`."""
    out = {}
    for ln in text.splitlines():
        m = re.match(r"\s*input\s+[\w:<>]+\s+(\w+)\s*=\s*([^;]*);", ln)
        if m:
            out[m.group(1)] = m.group(2).strip().strip('"')
    return out


def same_value(a: str, b: str) -> bool:
    """Compare '300.0' with '300', 'true' with 'TRUE', '' with '""'."""
    a, b = a.strip().strip('"'), b.strip().strip('"')
    try:
        return abs(float(a) - float(b)) < 1e-9
    except ValueError:
        return a.lower() == b.lower()


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
    funcs = [mm.group(1) for mm in re.finditer(
        r"^[\w:<>,\s\*&\[\]]*?(\w+)\s*\([^;{}]*\)\s*(?:const\s*)?\{", code, re.M)
        if mm.group(1) not in ctrl]
    stats = dict(lines=len(lines), inputs=len(inputs), funcs=len(funcs),
                 groups=sum(1 for l in lines if re.match(r"\s*input\s+group\b", l)),
                 version=m.group(1) if m else "?")

    ok, out = g.run(["tools/mql5_lint.py", str(EA.relative_to(ROOT))])
    g.check("static lint clean", ok, out.splitlines()[-1] if out else "")

    ok, out = g.run(["tools/gold_pip_calc.py", "--test"], re.compile(r"(\d+)/(\d+) checks passed"))
    mm = re.search(r"(\d+)/(\d+) checks passed", out or "")
    tests_ok = bool(ok and mm and mm.group(1) == mm.group(2) and int(mm.group(1)) > 0)
    g.check("logic mirror tests", tests_ok, mm.group(0) if mm else "no test output")
    stats["tests"] = f"{mm.group(1)}/{mm.group(2)}" if mm else "0/0"

    # zero-config contract
    d = input_defaults(text)
    off = [f"{k}={d.get(k, '<missing>')} should be {v!r} ({why})"
           for k, v, why in DEFAULTS_CONTRACT if not same_value(d.get(k, "\x00"), v)]
    g.check(f"zero-config contract ({len(DEFAULTS_CONTRACT)} defaults)", not off,
            "; ".join(off[:3]) or "attach with no changes = gold setup, all guards armed")
    stats["contract"] = len(DEFAULTS_CONTRACT)

    # no preset folder may come back without the gate knowing about it
    stray = sorted(p.name for p in (ROOT / "MQL5/Presets").glob("*.set")) if (ROOT / "MQL5/Presets").exists() else []
    g.check("no preset files to load", not stray, "removed on purpose" if not stray else f"found {stray}")
    return stats


# -------------------------------------------------------------------- release
def write_release(version: str, stats: dict, g: Gate, do_zip: bool) -> Path:
    out = ROOT / "release/GoldBasketGuard"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    shutil.copy2(EA, out / EA.name)
    for name in ("GoldBasketGuard-parameters.md", *SHEETS):
        src = DOC_DIR / name
        if src.exists():
            shutil.copy2(src, out / name)

    readme = f"""# GoldBasketGuard v{version} — release folder

این پوشه نسخهٔ نهایی و بررسی‌شدهٔ اکسپرت است. **هیچ فایل پیش‌تنظیمی لازم نیست**:
همه‌چیز در خود فایل ساخته شده و مقداردهیِ پیش‌فرض برای طلا تنظیم شده است.

## contents

| file | what it is |
|---|---|
| `GoldBasketGuard.mq5` | the EA — {stats['lines']} lines, {stats['inputs']} inputs, {stats['groups']} input groups |
| `GoldBasketGuard-parameters.md` | every parameter, Persian reference |
| `GoldBasketGuard-features-fa.png` | one-image feature sheet (Persian) |
| `GoldBasketGuard-flow-fa.png` | how the risk engine behaves, tick by tick |
| `manifest.txt` | sha256 of each file + the checks that were run |

## install / نصب

1. در MetaTrader 5 منوی `File → Open Data Folder` را بزنید.
2. پوشهٔ `MQL5/Experts/GoldBasketGuard/` را بسازید و `GoldBasketGuard.mq5` را در آن بگذارید.
3. MetaEditor را باز کنید، فایل را باز کنید و `F7` (Compile) — باید `0 errors` بگیرید.
4. نمودار `XAUUSD` (M5 یا M15) → `Navigator → Expert Advisors` → اکسپرت را بکشید روی چارت.
5. در تب `Common` تیک `Allow Algo Trading` را روشن کنید. **تب Inputs را دست نزنید** —
   همه‌چیز آماده است. برای اولین اجرا اگر خواستید فقط تماشا کنید، `InpDryRun=true`.

### چه چیزهایی خودش تشخیص داده می‌شود

- اندازهٔ پیپ از تعداد رقم اعشار نماد (`AutoPipSize`)، ارزش پول به‌ازای پیپ از `TICK_SIZE` / `TICK_VALUE`
- حساب **سنتی یا دلاری** از ارز حساب؛ اعداد پولی خودکار تقسیم/ضرب می‌شوند، درصدها نه
- `hedging` یا `netting` بودن حساب، و سطح مارجین آزاد
- `STOPS_LEVEL` و `FREEZE_LEVEL` کارگزار؛ اگر سرور سطحی را رد کند، حاشیه زیاد و دوباره تلاش می‌شود
- نوع fill مجاز نماد، محدودیت نرخ ارسال دستور، و حضور/عدم حضور تقویم اقتصادی
- ارز خبر از نام نماد (XAU/GOLD → USD)؛ اگر تقویم در دسترس نبود، پنجرهٔ دستی `InpNewsManualWindows`

### سرعت واکنش (v{version})

- حلقهٔ مدیریت هر `InpTimerMs=100` میلی‌ثانیه اجرا می‌شود (۱۰ چرخه در ثانیه)، نه هر ۱ ثانیه
- `InpInstantMirror=true`: کشیدن SL/TP روی یک معامله **داخل همان رویداد معامله** به بقیهٔ گروه
  منتقل می‌شود؛ لازم نیست چرخهٔ بعدی صبر کند، و بازار ساکت هم سرعت را کم نمی‌کند
- «تغییر دستی» با مقایسهٔ عدد تشخیص داده می‌شود، نه با یک پنجرهٔ چندثانیه‌ای: اکسپرت فقط
  همان سطحی را که **خودش درخواست کرده** نادیده می‌گیرد، پس تغییر دستی شما گم نمی‌شود
- `InpMaxModsPerSecond=25` و `InpMinMsPerTicket=0`: یک سبد کامل در یک چرخه صاف می‌شود
- خط آخر پنل مدت واقعی هر چرخه را نشان می‌دهد: `cycle 1 ms (max 9 ms)`

### سیاست بستن (پیش‌فرض از نسخهٔ {version})

- **تنها بستن خودکار:** ضرر شناور **کل حساب** ≥ **۶۰٪ موجودی** → بستنِ همه + قفل اکسپرت
  (`InpEmergencyFloatLossPct=60`، قفل تا `InpEmergencyLockHours=24` ساعت، `UNLOCK` یا کلید `7` برای باز کردن)
- **از ۴۰٪ فقط هشدار:** `Alert` + پوش + خط زرد پنل و `float -NN% bal`؛ هیچ دستوری فرستاده نمی‌شود
  (`InpRiskWarnPct=40`)
- kill-switch روی درصد equity: **خاموش** (`InpEnableKillSwitch=false`)؛ اگر روشنش کنید آستانه‌اش روی همان ۶۰٪ است
- بستن بر اساس margin level، free margin و افت equity از سقف: **خاموش** (`0`)
- گارد اخبار: **فقط هشدار** (`InpNewsAction=NEWS_WARN`)؛ برای بستن قبل از خبر قرمز `NEWS_CLOSE_GROUP` را انتخاب کنید
- حد ضرر/حد سود گروهی، ریسک‌فری و تریلینگ مثل قبل کار می‌کنند؛ `CLOSE ALL` و `CLOSE LOSERS` فقط با دو کلیک پشت سر هم

قصد معاملاتی (فاصلهٔ حد ضرر/حد سود، آستانهٔ ریسک‌فری، «کدام معاملات گروه من است»)
تشخیص‌دادنی نیست؛ همان‌ها در پنل روی چارت یا تب Inputs تایپ می‌شوند.

> این اکسپرت معامله باز نمی‌کند؛ فقط مدیریت حد سود/حد ضرر، ریسک‌فری، گارد اخبار
> و مدیریت سرمایهٔ گروهی را انجام می‌دهد. اول روی حساب دمو تست شود.

## verified by `tools/make_release.py`

{chr(10).join('- ' + p for p in g.passed)}

Rebuild this folder any time with:

```
python3 tools/make_release.py
```
"""
    (out / "README.md").write_text(readme, encoding="utf-8")

    man = [f"GoldBasketGuard v{version}", f"built {date.today().isoformat()} by tools/make_release.py",
           f"source: {EA.relative_to(ROOT)}",
           f"defaults contract: {stats['contract']} inputs pinned (no preset files needed)", "",
           "files (sha256  size  name):"]
    for f in sorted(out.rglob("*")):
        if f.is_file() and f.name != "manifest.txt":
            b = f.read_bytes()
            man.append(f"{hashlib.sha256(b).hexdigest()}  {len(b):>8}  {f.relative_to(out)}")
    man += ["", "checks passed:"] + [f"- {p}" for p in g.passed]
    (out / "manifest.txt").write_text("\n".join(man) + "\n", encoding="utf-8")

    if do_zip:
        for old in (ROOT / "release").glob("GoldBasketGuard-v*.zip"):
            old.unlink()
        zp = ROOT / f"release/GoldBasketGuard-v{version}.zip"
        with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as z:
            for f in sorted(out.rglob("*")):
                if f.is_file():
                    z.write(f, f.relative_to(out.parent))
        print(f"zip: {zp.relative_to(ROOT)} ({zp.stat().st_size // 1024} KB)")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--version", default=None, help="defaults to #property version in the EA")
    ap.add_argument("--check-only", action="store_true", help="run the gates, write nothing")
    ap.add_argument("--no-zip", action="store_true")
    a = ap.parse_args()

    if not a.version:
        m = re.search(r'#property\s+version\s+"([^"]+)"', EA.read_text(encoding="utf-8"))
        a.version = m.group(1) if m else "0.0"

    g = Gate()
    stats = verify(g, a.version)
    for p in g.passed:
        print(f"  ok    {p}")
    for p in g.problems:
        print(f"  FAIL  {p}")
    print(f"{'PASS' if not g.problems else 'BLOCKED'}: {len(g.passed)} checks, "
          f"{len(g.problems)} problems — v{stats['version']}, {stats['lines']} lines, "
          f"{stats['inputs']} inputs, {stats['funcs']} functions, tests {stats['tests']}, "
          f"contract {stats['contract']}/{stats['contract']}")
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
