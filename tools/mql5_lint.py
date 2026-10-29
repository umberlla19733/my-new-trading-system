#!/usr/bin/env python3
"""Lightweight static checks for MQL5 sources.

The sandbox has no MetaEditor, so this is a defensive linter for the
mistakes that actually break a build: unbalanced blocks, missing
semicolons after a call, tabs/non-ASCII bytes (MetaEditor encoding
problems), duplicate definitions and calls to symbols that are neither
defined in the file nor part of the MQL5 standard surface.

Usage:  python3 tools/mql5_lint.py MQL5/Experts/GoldBasketGuard/GoldBasketGuard.mq5
Exit:   0 clean, 1 problems found.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# Bare (non member) calls that belong to MQL5 / the shipped standard library.
KNOWN = set("""
Print PrintFormat Alert Comment  UninitializeReason Sleep
StringFormat StringConcatenate DoubleToString IntegerToString StringToDouble StringToInteger
StringLen StringFind StringSubstr StringSplit StringTrimLeft StringTrimRight StringToUpper StringToLower
StringGetCharacter StringSetCharacter StringReplace StringInit
MathAbs MathMax MathMin MathFloor MathCeil MathRound MathPow MathSqrt MathLog MathSin MathCos
NormalizeDouble ArrayResize ArraySize ArrayFree ArrayInitialize ArraySetAsSeries ArraySort ArrayCopy ArrayCopyRange
ObjectCreate ObjectDelete ObjectFind ObjectMove ObjectSetInteger ObjectSetDouble ObjectSetString
ObjectGetInteger ObjectGetDouble ObjectGetString ObjectsTotal ObjectsDeleteAll ObjectsDeleteAll ChartRedraw IsTester IsVisual MQLInfoInteger ObjectName GlobalVariableDel GlobalVariableCheck ChartTimePriceToXY ChartXYToTimePrice
ChartSetInteger ChartGetInteger ChartSetString ChartTimePriceToXY ChartXYToTimePrice
SymbolInfoDouble SymbolInfoInteger SymbolInfoString SymbolSelect SymbolInfoDigits SymbolInfoPoint
AccountInfoDouble AccountInfoInteger AccountInfoString
PositionsTotal PositionGetTicket PositionSelect PositionSelectByTicket PositionGetString PositionGetInteger PositionGetDouble
OrdersTotal OrderGetTicket OrderSelect OrderGetString OrderGetInteger OrderGetDouble OrderSend OrderCheck HistorySelect
iTime iClose iHigh iLow iOpen iVolume iBarShift iMA iRSI TimeCurrent TimeLocal TimeTradeServer TimeToStruct StructToTime
MQLInfoInteger TerminalInfoInteger TerminalInfoString AccountInfoDouble GetTickCount GetTickCount64
EventSetTimer EventKillTimer EventSetMillisecondTimer EventCharacter EventIsKeyDown
ZeroMemory InitializeCritical CopyRateFromStream FileOpen FileClose FileWrite FileRead FileWriteString FileReadString
SendNotification SendMail PlaySound IsStopped ResumeChart PeriodSeconds
TimeTradeServer TimeGMT TimeGMTCurrent TimeToStruct StructToTime TimeToString PeriodSeconds
CalendarValueHistory CalendarValueHistoryByEvent CalendarValueLast CalendarValueLastByEvent CalendarValueById
CalendarEventById CalendarEventByCountry CalendarEventByCurrency CalendarCountryById CalendarCountries
GlobalVariableSet GlobalVariableGet GlobalVariableCheck GlobalVariableDelete GlobalVariablesTotal GlobalVariableName
HistorySelect HistoryDealsTotal HistoryDealGetTicket HistoryDealGetDouble HistoryDealGetInteger HistoryDealGetString
HistoryOrdersTotal HistoryOrderGetTicket HistoryOrderGetDouble HistoryOrderGetInteger
ResetLastError GetLastError UninitializeReasonGet SymbolInfoIsEqualDoubleEx

"""
" ".split())

SKIP_RETURN = set("if for while switch return sizeof catch do else".split())


def strip_code(src: str) -> str:
    """Blank out comments and string literals, keep line structure."""
    out, i, n = [], 0, len(src)
    in_line = in_block = in_str = in_chr = False
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if in_line:
            if c == "\n":
                in_line = False
                out.append(c)
            else:
                out.append(" ")
            i += 1
            continue
        if in_block:
            if c == "*" and nxt == "/":
                in_block = False
                out.append("  ")
                i += 2
                continue
            out.append(c if c == "\n" else " ")
            i += 1
            continue
        if in_str:
            if c == "\\":
                out.append("  ")
                i += 2
                continue
            if c == '"':
                in_str = False
            out.append(" ")
            i += 1
            continue
        if c == "/" and nxt == "/":
            in_line = True
            out.append("  ")
            i += 2
            continue
        if c == "/" and nxt == "*":
            in_block = True
            out.append("  ")
            i += 2
            continue
        if c == '"':
            in_str = True
            out.append(" ")
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def lint(path: Path) -> list[str]:
    problems: list[str] = []
    raw = path.read_bytes()
    if any(b > 127 for b in raw):
        problems.append("file contains non-ASCII bytes - MetaEditor may mangle it (keep the source ASCII or save as UTF-16LE)")
    if b"\t" in raw:
        problems.append("file contains tab characters")
    if b"\r\n" in raw:
        pass  # CRLF is fine for MetaEditor

    src = raw.decode("utf-8", errors="replace")
    code = strip_code(src)
    lines = code.split("\n")

    # 1) balance
    for name, o, c in (("brace", "{", "}"), ("paren", "(", ")"), ("bracket", "[", "]")):
        depth, bad_line = 0, 0
        for no, line in enumerate(lines, 1):
            before = depth
            depth += line.count(o) - line.count(c)
            if depth < 0:
                bad_line = no
                break
            if depth == 0 and before > 0:
                pass
        total = code.count(o) - code.count(c)
        if total != 0:
            problems.append(f"unbalanced {name}: net {total:+d}" + (f" (goes negative at line {bad_line})" if bad_line else ""))

    # 2) statements that look like a bare call but do not end with ';'
    code_lines = src.split("\n")
    call_re = re.compile(r"^([A-Za-z_]\w*)\s*\(")
    def_re  = re.compile(r"^[A-Za-z_~]\w*\s+[A-Za-z_~]\w*(::\w+)?\s*\(")
    kw_re   = re.compile(r"^(if|for|while|switch|catch|else|return|do)\b")
    for no, line in enumerate(lines, 1):
        t = line.strip()
        if not t or t.startswith("#"):
            continue
        if t[-1] in ";{}:,":
            continue
        if line.count("(") - line.count(")") != 0 or line.count("[") - line.count("]") != 0:
            continue   # statement continues on the next line
        if kw_re.match(t):
            continue
        if def_re.match(t):
            continue
        if call_re.match(t):
            problems.append(f"line {no}: bare call without ';' -> {code_lines[no - 1].strip()[:90]}")

    # 3) function definitions (signatures may wrap over two lines)
    defs, joined = {}, []
    buf = ""
    for line in lines:
        cand = (buf + " " + line.strip()).strip() if buf else line.strip()
        bal = cand.count("(") - cand.count(")")
        if bal > 0:
            buf = cand
            continue
        buf = ""
        joined.append(cand)
    for no, cand in enumerate(joined, 1):
        m = re.match(r"^\s*(?:void|int|bool|double|string|long|ulong|datetime|color|uint|uchar|char|float|short|ushort|\w+_t|ENUM_\w+)\s+([A-Za-z_]\w*)\s*\([^;]*\)\s*(?:const)?\s*$", cand)
        if m:
            name = m.group(1)
            if name in defs:
                problems.append(f"duplicate definition of {name}() (line ~{no})")
            defs[name] = no

    # 4) unknown bare calls
    used = set()
    for line in lines:
        for m in re.finditer(r"(?<![.\w])([A-Za-z_]\w*)\s*\(", line):
            used.add(m.group(1))
    unknown = sorted(u for u in used if u not in KNOWN and u not in defs and u not in SKIP_RETURN)
    for u in unknown:
        problems.append(f"call to unknown function {u}() - not defined in file and not a known MQL5 function")

    # 5) inputs must be unique and referenced style
    inputs = re.findall(r"^\s*input\s+(?!group\b)\S+\s+(\w+)", code, re.M)
    dup = {i for i in inputs if inputs.count(i) > 1}
    for d in sorted(dup):
        problems.append(f"input {d} declared twice")
    decl = set(inputs) | set(re.findall(r"^\s*(?:double|bool|int|long|ulong|datetime|string|color|uint|char)\s+(\w+)\s*[=;,]", code, re.M))
    for name in sorted(set(re.findall(r"\bInp\w+", code))):
        if name not in decl:
            problems.append(f"input {name} is used but never declared")
    # 6) declared but never referenced (dead knobs are a documentation bug)
    body = code
    for name in sorted(set(inputs)):
        if len(re.findall(r"\b" + re.escape(name) + r"\b", body)) < 2:
            problems.append(f"input {name} is declared but never used in the code")
    enum_members = set(re.findall(r"^\s*([A-Z][A-Z0-9_]{3,})\s*=\s*\d+,?", code, re.M))
    for name in sorted(enum_members):
        if len(re.findall(r"\b" + re.escape(name) + r"\b", body)) < 2:
            problems.append(f"enum member {name} is declared but never used")
    # 7) MQL5 does not concatenate adjacent string literals: "A" "B" is an error
    macros = dict(re.findall(r'^\s*#define\s+(\w+)\s+"([^"]*)"\s*$', src, re.M))
    non_define = "\n".join(l for l in src.splitlines() if not l.lstrip().startswith("#define"))
    for name in macros:
        if re.search(r"\b" + re.escape(name) + r'\s*"', non_define):
            problems.append(f"macro {name} is followed by a string literal - MQL5 has no adjacent-literal "
                            "concatenation, write  " + name + ' + "text"')

    # 8) in-place string helpers return bool, they are not the modified string
    for fn in ("StringToUpper", "StringToLower", "StringTrimLeft", "StringTrimRight"):
        if re.search(fn + r"\([^)]*\)\s*(==|!=|\+|<|>)", code) or re.search(r"(==|!=|\+)\s*" + fn + r"\(", code):
            problems.append(fn + "() modifies its argument in place and returns bool - do not use it as a value")
    return problems


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    rc = 0
    for arg in sys.argv[1:]:
        p = Path(arg)
        if not p.exists():
            print(f"missing file: {p}")
            return 2
        probs = lint(p)
        print(f"== {p}")
        if not probs:
            print("   clean: blocks balanced, no obvious syntax/API problems")
        else:
            rc = 1
            for x in probs:
                print("   - " + x)
    return rc


if __name__ == "__main__":
    sys.exit(main())
