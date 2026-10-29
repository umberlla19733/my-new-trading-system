#!/usr/bin/env python3
"""Estimate how much terminal work one management cycle of GoldBasketGuard costs.

Why this exists: the EA runs every InpTimerMs (100 ms by default), so what makes a
chart feel heavy is not the size of the file but the number of terminal accessors a
cycle calls. Every PositionGet*, AccountInfo*, SymbolInfo*, Object* write and
ChartRedraw is a round trip into the terminal, and a panel that repaints 27 objects
ten times a second is exactly what a trader feels as lag.

The tool walks the call graph from RunCycle -> Manage -> (guards, sizing, panel) and
counts accessor calls, weighting each call site by the loop it sits in:

  * a loop over positions        counted N times   (N = --tickets)
  * a loop over panel rows       counted 12 times
  * a retry loop around an order counted once
  * nested helper calls inherit the multiplier of their call site

It is a static estimate, not a profiler: it counts reachable call sites and never
models branch probability. Use it as the release gate uses it - as a ratchet that
stops the cycle from quietly getting heavier again.

    python3 tools/mql5_cost.py                  # a 5 ticket group
    python3 tools/mql5_cost.py --tickets 0      # idle chart
    python3 tools/mql5_cost.py --top 12         # where the calls live
    python3 tools/mql5_cost.py --max 160        # exit 1 above a budget
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EA = ROOT / "MQL5/Experts/GoldBasketGuard/GoldBasketGuard.mq5"

#--- accessor families that cost a trip into the terminal --------------------
ACCESSORS = {
    "AccountInfoDouble", "AccountInfoInteger", "AccountInfoString",
    "SymbolInfoDouble", "SymbolInfoInteger", "SymbolInfoString",
    "PositionsTotal", "PositionGetTicket", "PositionGetDouble", "PositionGetInteger",
    "PositionGetString", "PositionSelect", "PositionSelectByTicket",
    "HistorySelect", "HistoryDealsTotal", "HistoryDealGetDouble", "HistoryDealGetInteger",
    "HistoryDealGetTicket", "HistoryDealGetString", "OrdersHistoryTotal", "OrderGetTicket",
    "OrderGetDouble", "OrderGetInteger", "OrderGetString",
    "GlobalVariableGet", "GlobalVariableSet", "GlobalVariableCheck", "GlobalVariableDel",
    "ObjectFind", "ObjectCreate", "ObjectDelete", "ObjectsTotal", "ObjectName",
    "ObjectGetString", "ObjectSetString", "ObjectGetInteger", "ObjectSetInteger",
    "ObjectGetDouble", "ObjectSetDouble",
    "ChartRedraw", "ChartGetInteger", "ChartTimePriceToXY", "ChartXYToTimePrice",
    "TerminalInfoInteger", "MQLInfoInteger",
    "TimeCurrent", "TimeLocal", "TimeTradeServer", "GetTickCount",
    "iTime", "iOpen", "iClose", "iHigh", "iLow", "iBars",
    "CalendarValueHistory", "CalendarValueLast", "CopyRates",
    "Alert", "Print", "PrintFormat", "Comment", "PlaySound", "SendNotification",
    "EventSetMillisecondTimer", "StringToTime", "TimeToString",
}
# string and array plumbing: real calls, but orders of magnitude cheaper than the above
IGNORE = {"ArraySize", "ArrayResize", "ZeroMemory", "StringLen", "MathAbs", "MathMax",
          "MathMin", "MathPow", "MathRound", "MathSqrt", "MathFloor", "MathCeil",
          "StringFind", "StringSubstr", "StringToDouble", "StringToInteger",
          "IntegerToString", "DoubleToString", "StringFormat", "NormalizeDouble",
          "StringGetCharacter", "StringSplit", "GetLastError", "Sleep", "Symbol",
          "StringReplace", "StringTrim", "MathMod", "fmod", "ArrayFree"}

# Functions that a *quiet* cycle never executes: object creation, order sending,
# resets and event plumbing. They are measured separately as "action" cost.
COLD = {
    "OnInit", "OnDeinit", "OnChartEvent", "OnButton", "OnHotkey", "OnTimer", "OnTick",
    "OnTradeTransaction", "PanelCreate", "PanelShowPage", "PanelClearPage", "PanelDelete",
    "UiLoad", "UiSave", "UiReset", "InitAnchors", "NewTradingDay", "DetectAccountUnits",
    "TryModify", "ApplyGroupStops", "ApplyGroupStopsClear", "ApplyGroupStopsNow",
    "CloseGroup", "ClosePartialGroup", "CloseSingle", "ForceRiskFree", "ClampNotice",
    "PauseTillTomorrow", "ClearLockout", "EmergencyLock", "Notify", "Log",
}
# the order-sending paths: excluded from the quiet cycle, measured on their own
ACTION = {"TryModify", "ApplyGroupStops", "ApplyGroupStopsClear", "CloseGroup",
          "ClosePartialGroup", "CloseSingle", "ForceRiskFree", "ClampNotice"}
ACTION_ROOTS = ("ApplyGroupStops", "CloseGroup", "ClosePartialGroup")

POS_LOOP = re.compile(r"PositionsTotal\(\)|ArraySize\(g_pos\)|<\s*total\b|<\s*n\b")
PANEL_LOOP = re.compile(r"i < 12|i < rows|i < 11|i < 3;|ObjectsTotal|< 8;")
RETRY_LOOP = re.compile(r"InpRetryCount")
DEF_RE = re.compile(r"^[\w:<>,\s\*&\[\]]*?\b(\w+)\s*\([^;]*\)\s*(?:const\s*)?$")
LOOP_HDR = re.compile(r"\b(for|while)\s*\(")


def strip_noise(src: str) -> str:
    """Drop comments and string literals so braces and names can be counted safely."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append("\n")
            i = j
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("\n" * src.count("\n", i, j))
            i = j
            continue
        if c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append('"x"')
            i = min(j + 1, n)
            continue
        out.append(c)
        i += 1
    return "".join(out)


def parse_bodies(clean: str) -> dict:
    """name -> body text, for every top level function definition."""
    lines = clean.split("\n")
    off, starts = [], 0
    for ln in lines:
        off.append(starts)
        starts += len(ln) + 1
    funcs = {}
    i = 0
    while i < len(lines):
        ln = lines[i]
        if ln[:1] not in (" ", "\t", "") and LOOP_HDR.search(ln) is None:
            m = DEF_RE.match(ln)
            if m and m.group(1) not in ("if", "for", "while", "switch", "return", "else"):
                name = m.group(1)
                depth, j, opened = 0, i, False
                while j < len(lines):
                    for ch in lines[j]:
                        if ch == "{":
                            depth, opened = depth + 1, True
                        elif ch == "}":
                            depth -= 1
                    if opened and depth == 0:
                        break
                    if depth < 0:
                        break
                    j += 1
                if opened and j < len(lines):
                    body = clean[off[i]:off[j] + len(lines[j])]
                    funcs.setdefault(name, body)
                    i = j
                    continue
        i += 1
    return funcs


def loop_weight(line: str, tickets: int) -> int:
    if POS_LOOP.search(line):
        return max(0, tickets)
    if PANEL_LOOP.search(line):
        return 12
    if RETRY_LOOP.search(line):
        return 1
    return 2                                       # unknown small loop: conservative


def line_calls(line: str, mult: int, calls: dict) -> None:
    for fn in re.findall(r"\b([A-Za-z_]\w*)\s*\(", line):
        if fn in IGNORE:
            continue
        if fn in ACCESSORS:
            calls[fn] += mult


def update_stack(line: str, stack: list, pending):
    for ch in line:
        if ch == "{":
            stack.append(pending if pending is not None else stack[-1])
            pending = None
        elif ch == "}" and len(stack) > 1:
            stack.pop()
    return pending


def calls_in(body: str, tickets: int) -> dict:
    """Accessor calls inside one function body, weighted by the loop each sits in.

    A loop with braces multiplies everything until its closing brace; a loop with a
    brace-less single statement multiplies only that statement - which is the case
    this tool got wrong the first time, so the two shapes are handled apart.
    """
    calls = defaultdict(int)
    lines = body.split("\n")
    stack, pending = [1], None
    i = 0
    while i < len(lines):
        line = lines[i]
        cur = stack[-1]
        if LOOP_HDR.search(line):
            pend = cur * loop_weight(line, tickets)
            j = i + 1
            while j < len(lines) and not lines[j].strip():
                j += 1
            if "{" not in line and j < len(lines) and not lines[j].strip().startswith("{"):
                line_calls(line, cur, calls)
                line_calls(lines[j], pend, calls)
                i = j + 1
                continue
            pending = pend
        line_calls(line, cur, calls)
        pending = update_stack(line, stack, pending)
        i += 1
    return dict(calls)


def callees(body: str) -> set:
    out = set()
    for fn in re.findall(r"\b([A-Za-z_]\w*)\s*\(", body):
        if fn not in IGNORE:
            out.add(fn)
    return out


def reachable(root: str, funcs: dict, skip: set) -> set:
    """Everything a cycle can execute, without walking into the cold/action edges."""
    seen, todo = set(), [root]
    while todo:
        name = todo.pop()
        if name in seen or name not in funcs or (name in skip and name != root):
            continue
        seen.add(name)
        for nxt in callees(funcs[name]):
            if nxt not in seen:
                todo.append(nxt)
    return seen


def analyse(root: str, tickets: int, path: Path = EA, skip: set = COLD) -> dict:
    clean = strip_noise(path.read_text(encoding="utf-8"))
    funcs = parse_bodies(clean)
    total = defaultdict(int)
    for name in sorted(reachable(root, funcs, skip)):
        for fn, n in calls_in(funcs[name], tickets).items():
            total[fn] += n
    return dict(total)


def action_cost(tickets: int, path: Path, skip: set) -> dict:
    """The same measure for the order-sending paths, once per touched ticket."""
    clean = strip_noise(path.read_text(encoding="utf-8"))
    funcs = parse_bodies(clean)
    total = defaultdict(int)
    live = skip - ACTION
    for root in ACTION_ROOTS:
        if root not in funcs:
            continue
        for name in sorted(reachable(root, funcs, live)):
            for fn, n in calls_in(funcs[name], tickets).items():
                total[fn] += n
    return dict(total)


def total_of(calls: dict) -> int:
    return sum(calls.values())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tickets", type=int, default=5, help="tickets in the group")
    ap.add_argument("--root", default="RunCycle", help="entry function to measure")
    ap.add_argument("--top", type=int, default=0, help="show the N heaviest accessors")
    ap.add_argument("--max", type=int, default=0, help="fail if one cycle costs more")
    ap.add_argument("--json", action="store_true", help="machine readable")
    ap.add_argument("--ea", default=str(EA), help="which .mq5 to measure (for before/after)")
    ap.add_argument("--tick-ms", type=int, default=100, help="fast loop period")
    ap.add_argument("--idle-ms", type=int, default=1000, help="loop period with an empty account")
    a = ap.parse_args()
    src = Path(a.ea)

    calls = analyse(a.root, a.tickets, src)
    total = total_of(calls)
    act = action_cost(a.tickets, src, COLD)
    writes = calls.get("ObjectSetString", 0) + calls.get("ObjectSetInteger", 0) + \
        calls.get("ObjectSetDouble", 0)
    if a.json:
        print(f'{{"root": "{a.root}", "tickets": {a.tickets}, "total": {total}, '
              f'"writes": {writes}, "redraws": {calls.get("ChartRedraw", 0)}, '
              f'"actions": {total_of(act)}}}')
    else:
        print(f"{a.root}() with {a.tickets} ticket(s): {total} terminal calls on the quiet path "
              f"[{writes} object writes, {calls.get('ChartRedraw', 0)} redraws, "
              f"{calls.get('PositionGetTicket', 0)} position reads]")
        print(f"   and {total_of(act)} more when one batch of orders actually goes out")
        if a.top:
            for name, n in sorted(calls.items(), key=lambda kv: (-kv[1], kv[0]))[:a.top]:
                print(f"   {n:5d}  {name}")
        else:
            idle = total_of(analyse(a.root, 0, src))
            m = re.search(r"input\s+int\s+InpIdleRefreshMs\s*=\s*(\d+)", src.read_text(encoding="utf-8"))
            if m:
                idle_ms = int(m.group(1))
                print(f"   with an empty account: {idle} calls per cycle, and the loop slows to "
                      f"{idle_ms} ms -> {round(idle * 1000 / idle_ms)} calls/second instead of "
                      f"{round(idle * 1000 / a.tick_ms)}")
            else:
                print(f"   with an empty account: {idle} calls per cycle, still at {a.tick_ms} ms "
                      f"(no InpIdleRefreshMs in this build)")
    if a.max and total > a.max:
        print(f"OVER BUDGET: {total} > {a.max}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
