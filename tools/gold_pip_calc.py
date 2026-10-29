#!/usr/bin/env python3
"""GoldBasketGuard - pip calculator + logic specification.

MetaEditor cannot run in this sandbox, so the decision logic of the EA is
re-implemented here in ~150 lines and exercised against the behaviour the
EA promises. Run the checks with:

    python3 tools/gold_pip_calc.py --test
    python3 tools/gold_pip_calc.py --pips 200 --digits 2      # what is 200 pips on gold?
    python3 tools/gold_pip_calc.py --move 2650.00 2673.40 --digits 2

The pip convention (mirrors AutoPipSize() in GoldBasketGuard.mq5):
  * 2-digit XAUUSD  -> 1 pip = 0.10  (10 points)  -> 100 pips = $10.00 of gold
  * 3-digit XAUUSD  -> 1 pip = 0.10  (100 points)
  * 5-digit EURUSD  -> 1 pip = 0.0010 (10 points)
"""
from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field


def pip_size(digits: int, point: float = 0.01, override: float = 0.0) -> float:
    if override > 0:
        return override
    if digits <= 1:
        return 0.10
    if digits == 2:
        return 0.10
    if digits == 3:
        return 0.10
    return point * 10.0


@dataclass
class Ticket:
    ticket: int
    side: str            # "BUY" | "SELL"
    entry: float
    vol: float
    sl: float = 0.0
    tp: float = 0.0


@dataclass
class Basket:
    tickets: list[Ticket] = field(default_factory=list)
    pip: float = 0.10
    market: float = 0.0          # bid for buys / ask for sells (single price model)
    stops_points: float = 0.0
    point: float = 0.01

    # --- mirrors ComputeBasket() / AnchorPrice() -------------------------
    def avg(self, side: str) -> float:
        rows = [t for t in self.tickets if t.side == side]
        if not rows:
            return 0.0
        return sum(t.entry * t.vol for t in rows) / sum(t.vol for t in rows)

    def worst(self, side: str) -> float:
        rows = [t.entry for t in self.tickets if t.side == side]
        if not rows:
            return 0.0
        return min(rows) if side == "BUY" else max(rows)

    def gain_pips(self, t: Ticket) -> float:
        return (self.market - t.entry) / self.pip if t.side == "BUY" else (t.entry - self.market) / self.pip

    def basket_gain_pips(self) -> float:
        buys = [t for t in self.tickets if t.side == "BUY"]
        sells = [t for t in self.tickets if t.side == "SELL"]
        if buys and not sells:
            return (self.market - self.avg("BUY")) / self.pip
        if sells and not buys:
            return (self.avg("SELL") - self.market) / self.pip
        vb = sum(t.vol for t in buys)
        vs = sum(t.vol for t in sells)
        if vb > vs:
            return (self.market - self.avg("BUY")) / self.pip
        if vs > vb:
            return (self.avg("SELL") - self.market) / self.pip
        return 0.0

    def anchor(self, t: Ticket, mode: str) -> float:
        if mode == "APPLY_SAME_LEVEL":
            return self.avg(t.side) or t.entry
        if mode == "APPLY_FROM_WORST":
            return self.worst(t.side)
        return t.entry

    # --- mirrors FinalizeLevel() ----------------------------------------
    def finalize(self, t: Ticket, is_sl: bool, raw: float) -> float:
        gap = max(self.stops_points * self.point, 0.0) + self.point * 0.5
        if gap <= 0:
            gap = self.point * 10.0
        if t.side == "BUY":
            if is_sl:
                if raw >= self.market:
                    return -1.0                     # rejected
                return min(raw, self.market - gap)
            if raw <= self.market:
                return -1.0
            return max(raw, self.market + gap)
        if is_sl:
            if raw <= self.market:
                return -1.0
            return max(raw, self.market + gap)
        if raw >= self.market:
            return -1.0
        return min(raw, self.market - gap)

    # --- mirrors ApplyGroupStops() --------------------------------------
    def apply_group(self, mode: str, sl_pips: float, tp_pips: float) -> int:
        """One modification request per ticket, exactly like TryModify()."""
        changed = 0
        for t in self.tickets:
            a = self.anchor(t, mode)
            new_sl, new_tp = t.sl, t.tp
            if sl_pips > 0:
                raw = a - sl_pips * self.pip if t.side == "BUY" else a + sl_pips * self.pip
                v = self.finalize(t, True, raw)
                if v > 0:
                    new_sl = v
            if tp_pips > 0:
                raw = a + tp_pips * self.pip if t.side == "BUY" else a - tp_pips * self.pip
                v = self.finalize(t, False, raw)
                if v > 0:
                    new_tp = v
            if abs(new_sl - t.sl) > 0 or abs(new_tp - t.tp) > 0:
                t.sl, t.tp = round(new_sl, 8), round(new_tp, 8)
                changed += 1
        return changed

    # --- mirrors the "mirror one manual edit" path ----------------------
    def mirror_from(self, edited: Ticket, mode: str) -> None:
        """The trader dragged SL/TP of ONE ticket: copy it to the whole group."""
        sl_level = edited.sl if edited.sl > 0 else -1.0
        tp_level = edited.tp if edited.tp > 0 else -1.0
        for t in self.tickets:
            if sl_level < 0:
                t.sl = 0.0
            elif mode == "APPLY_SAME_LEVEL":
                t.sl = sl_level
            else:                                    # same distance from own entry
                dist = abs(edited.sl - edited.entry)
                t.sl = self.finalize(t, True, t.entry - dist if t.side == "BUY" else t.entry + dist)
            if tp_level < 0:
                t.tp = 0.0
            elif mode == "APPLY_SAME_LEVEL":
                t.tp = tp_level
            else:
                dist = abs(edited.tp - edited.entry)
                t.tp = self.finalize(t, False, t.entry + dist if t.side == "BUY" else t.entry - dist)

    # --- mirrors ApplyRiskFree() + ApplyTrailing() ----------------------
    def risk_free(self, arm_pips: float, lock_pips: float, per_ticket: bool, use_avg: bool) -> int:
        moved = 0
        gate = self.basket_gain_pips() if not per_ticket else None
        for t in self.tickets:
            ok = (self.gain_pips(t) >= arm_pips) if per_ticket else (gate >= arm_pips)
            if not ok or self.gain_pips(t) <= 0:
                continue
            a = (self.avg(t.side) if use_avg else t.entry) or t.entry
            off = lock_pips * self.pip
            raw = a + off if t.side == "BUY" else a - off
            v = self.finalize(t, True, raw)
            better = (t.sl == 0) or (v > t.sl + self.point if t.side == "BUY" else v < t.sl - self.point)
            if v > 0 and better:
                t.sl, moved = round(v, 8), moved + 1
        return moved

    def trail_step(self, start_pips: float, step_pips: float, min_pips: float, follow_group: bool) -> int:
        moved = 0
        gate = self.basket_gain_pips()
        for t in self.tickets:
            trig = gate if follow_group else self.gain_pips(t)
            own = self.gain_pips(t)
            if trig < start_pips or own <= 0:
                continue
            locked = max(0.0, ((own - min_pips) // step_pips) * step_pips)
            raw = t.entry + locked * self.pip if t.side == "BUY" else t.entry - locked * self.pip
            v = self.finalize(t, True, raw)
            better = (t.sl == 0) or (v > t.sl + self.point if t.side == "BUY" else v < t.sl - self.point)
            if v > 0 and better:
                t.sl, moved = round(v, 8), moved + 1
        return moved


# --------------------------------------------------------------------------
#  Risk sizing, cent accounts and the emergency breaker (mirrored from MQL5)
# --------------------------------------------------------------------------
def money_per_pip(vol_total: float, pip: float, tick_size: float, tick_value: float) -> float:
    """Account-currency value of 1 pip for the whole basket."""
    if tick_size <= 0 or tick_value <= 0 or vol_total <= 0:
        return 0.0
    return vol_total * (pip / tick_size) * tick_value


def auto_sl_pips(balance: float, risk_pct: float, mpp: float, floor_pips: float, cap_pips: float) -> float:
    if mpp <= 0 or risk_pct <= 0:
        return 0.0
    pips = (balance * risk_pct / 100.0) / mpp
    if cap_pips > 0:
        pips = min(pips, cap_pips)
    if floor_pips > 0:
        pips = max(pips, floor_pips)
    return pips


def money_factor(cent: bool, basis: str, divisor: float = 100.0) -> float:
    """What the numbers you type mean on a cent vs a dollar account."""
    if basis == "ACCOUNT_CCY":
        return 1.0
    if basis == "REAL_USD":
        return divisor
    return divisor if cent else 1.0          # AUTO


def is_cent_currency(ccy: str) -> bool:
    up = (ccy or "").upper()
    return up in {"USC", "EUC", "GBC", "RUC", "AUC", "JYC", "CHC", "BRC"} or "CENT" in up


def emergency_hit(balance: float, equity: float, margin_level: float, free_margin: float,
                  loss_pct: float, ml_limit: float, fm_pct: float, peak_equity: float = 0.0,
                  dd_pct: float = 0.0) -> str:
    fl = equity - balance
    if loss_pct > 0 and balance > 0 and fl <= -balance * loss_pct / 100.0:
        return "floating loss %.2f = %.1f%% of balance" % (fl, -fl / balance * 100.0)
    if dd_pct > 0 and peak_equity > 0 and equity < peak_equity * (1 - dd_pct / 100.0):
        return "equity drawdown %.1f%% from peak" % ((peak_equity - equity) / peak_equity * 100.0)
    if ml_limit > 0 and margin_level > 0 and margin_level <= ml_limit:
        return "margin level %.1f%%" % margin_level
    if fm_pct > 0 and equity > 0 and free_margin <= equity * fm_pct / 100.0:
        return "free margin %.1f%% of equity" % (free_margin / equity * 100.0)
    return ""


def in_manual_window(minutes_now: int, dow_now: int, windows: str) -> bool:
    """'HH:MM-HH:MM' (all days) or 'DOW-HH:MM-HH:MM' (0=Sunday), server time."""
    for raw in (windows or "").split(";"):
        w = raw.strip()
        if len(w) < 5:
            continue
        seg = w.split("-")
        dow = -1
        if len(seg) == 3:
            dow = int(seg[0])
            seg = seg[1:]
        elif len(seg) != 2:
            continue
        if dow >= 0 and dow != dow_now:
            continue
        def to_min(x):
            parts = x.split(":")
            if len(parts) != 2:
                return -1
            h, m = int(parts[0]), int(parts[1])
            if not (0 <= h <= 23 and 0 <= m <= 59):
                return -1
            return h * 60 + m
        a, b = to_min(seg[0]), to_min(seg[1])
        if a < 0 or b < 0:
            continue
        if b < a:                                   # wraps past midnight
            if minutes_now >= a or minutes_now <= b:
                return True
        elif a <= minutes_now <= b:
            return True
    return False


def news_window_hit(event_time: int, now: int, before_min: int, after_min: int) -> bool:
    dt = event_time - now
    return dt <= before_min * 60 and -dt <= after_min * 60


# --------------------------------------------------------------------------
def _mk() -> Basket:
    b = Basket(pip=0.10, market=2650.00, stops_points=0.0, point=0.01)
    b.tickets = [Ticket(1, "BUY", 2630.00, 0.10), Ticket(2, "BUY", 2640.00, 0.20), Ticket(3, "BUY", 2645.00, 0.10)]
    return b


def run_tests() -> int:
    fails: list[str] = []
    passed = [0]

    def check(name, cond):
        if cond:
            passed[0] += 1
        else:
            fails.append(name)

    # pip conversion on gold
    check("pip@2digits", abs(pip_size(2) - 0.10) < 1e-12)
    check("pip@3digits", abs(pip_size(3, 0.001) - 0.10) < 1e-12)
    check("100 pips = $10", abs(100 * pip_size(2) - 10.0) < 1e-9)

    # volume weighted average of the group
    b = _mk()
    check("vw avg", abs(b.avg("BUY") - (2630 * .1 + 2640 * .2 + 2645 * .1) / .4) < 1e-9)
    check("group gain", abs(b.basket_gain_pips() - (2650.0 - b.avg("BUY")) / 0.10) < 1e-9)

    # 1) group TP/SL: every ticket ends up on the SAME price (APPLY_SAME_LEVEL)
    n = b.apply_group("APPLY_SAME_LEVEL", sl_pips=300, tp_pips=500)
    check("applied to all 3", n == 3)
    check("identical SL", len({round(t.sl, 2) for t in b.tickets}) == 1)
    check("identical TP", len({round(t.tp, 2) for t in b.tickets}) == 1)
    check("SL = avg - 300p", abs(b.tickets[0].sl - round(b.avg("BUY") - 30.0, 2)) < 0.011)
    check("TP = avg + 500p", abs(b.tickets[0].tp - round(b.avg("BUY") + 50.0, 2)) < 0.011)

    # 2) per-ticket mode keeps distances equal but levels individual
    b2 = _mk()
    b2.apply_group("APPLY_PER_TICKET", sl_pips=300, tp_pips=500)
    check("per-ticket distances equal", len({round(abs(t.entry - t.sl) / 0.10, 6) for t in b2.tickets}) == 1)

    # 3) THE headline feature: edit one ticket manually -> group follows
    b3 = _mk()
    b3.apply_group("APPLY_SAME_LEVEL", sl_pips=300, tp_pips=500)
    b3.tickets[1].tp = 2712.50          # trader drags TP of the middle ticket
    b3.mirror_from(b3.tickets[1], "APPLY_SAME_LEVEL")
    check("mirror copies the price", all(abs(t.tp - 2712.50) < 1e-9 for t in b3.tickets))
    b3.tickets[2].sl = 0.0               # trader removes the SL of one ticket
    b3.mirror_from(b3.tickets[2], "APPLY_SAME_LEVEL")
    check("mirror copies removal", all(t.sl == 0.0 for t in b3.tickets))

    # 4) risk-free after 200 pips of group profit
    b4 = _mk()
    check("not yet risk-free", b4.risk_free(200, 10, per_ticket=False, use_avg=False) == 0)
    b4.market = 2650.00 + 200 * 0.10     # group avg +200 pips
    moved = b4.risk_free(200, 10, per_ticket=False, use_avg=False)
    check("all profitable tickets locked", moved >= 1)
    for t in b4.tickets:
        check(f"SL above entry #{t.ticket}", t.sl >= t.entry)
        check(f"lock is 10 pips #{t.ticket}", abs((t.sl - t.entry) / 0.10 - 10.0) < 1e-6)

    # 5) risk-free is one-way: it must never pull the SL back
    before = [t.sl for t in b4.tickets]
    b4.market = b4.market - 30.0
    b4.risk_free(200, 10, per_ticket=False, use_avg=False)
    check("SL never loosens", all(t.sl >= v for t, v in zip(b4.tickets, before)))

    # 6) step trailing locks profit in steps of 30 pips
    b5 = _mk()
    b5.market = 2650.00 + 400 * 0.10
    b5.trail_step(start_pips=250, step_pips=30, min_pips=40, follow_group=True)
    for t in b5.tickets:
        locked = (t.sl - t.entry) / 0.10
        check(f"locked profit multiple of step #{t.ticket}", abs(locked % 30) < 1e-6)
        check(f"still >= min gap #{t.ticket}", b5.gain_pips(t) - locked >= 40 - 1e-6)

    # 7) a stop that sits on the wrong side of the market is rejected, not sent
    b6 = Basket(pip=0.10, market=2600.00, stops_points=20.0, point=0.01)
    b6.tickets = [Ticket(9, "BUY", 2650.00, 0.10)]
    check("wrong-side SL rejected", b6.finalize(b6.tickets[0], True, 2660.0) < 0)
    b6.apply_group("APPLY_SAME_LEVEL", sl_pips=100, tp_pips=100)
    check("no bogus level written", b6.tickets[0].sl == 0.0)
    check("TP pushed by stops level", b6.tickets[0].tp >= 2600.0 + 20 * 0.01)

    # 8) risk sizing: % of balance -> pips, with cap/floor and R multiple
    mpp = money_per_pip(vol_total=0.4, pip=0.10, tick_size=0.01, tick_value=1.0)
    # 0.4 lot of gold: 1 tick (0.01) = $1 per lot -> 1 pip (0.10) = $10 per lot -> $4 for 0.4 lot
    check("money per pip = 4 USD for 0.4 lot", abs(mpp - 4.0) < 1e-9)
    pips = auto_sl_pips(balance=10000, risk_pct=1.0, mpp=mpp, floor_pips=80, cap_pips=0)
    check("1% of 10k = 25 pips -> floored to 80", abs(pips - 80.0) < 1e-9)
    pips2 = auto_sl_pips(balance=10000, risk_pct=30.0, mpp=mpp, floor_pips=80, cap_pips=400)
    check("cap respected (3000/4=750 -> 400)", abs(pips2 - 400.0) < 1e-9)
    pips3 = auto_sl_pips(balance=10000, risk_pct=2.0, mpp=mpp, floor_pips=0, cap_pips=0)
    check("2% of 10k = 50 pips on 0.4 lot", abs(pips3 - 50.0) < 1e-9)
    check("bigger basket -> tighter SL (same risk)",
          auto_sl_pips(10000, 2.0, money_per_pip(0.8, 0.10, 0.01, 1.0), 0, 0) < pips3)

    # 9) cent account detection + money units
    check("USC is cent", is_cent_currency("USC"))
    check("USD is not cent", not is_cent_currency("USD"))
    check("CentUSD detected", is_cent_currency("CentUSD"))
    check("AUTO on cent -> x100", money_factor(True, "AUTO") == 100.0)
    check("AUTO on dollar -> x1", money_factor(False, "AUTO") == 1.0)
    check("ACCOUNT_CCY never converts", money_factor(True, "ACCOUNT_CCY") == 1.0)
    check("REAL_USD forces x100", money_factor(False, "REAL_USD") == 100.0)

    # 10) the "50% of the account is at risk" breaker
    check("50% floating loss trips", "floating loss" in emergency_hit(2000, 1000, 200, 500, 50, 150, 0))
    check("25% floating loss does not trip", emergency_hit(2000, 1500, 200, 500, 50, 0, 0) == "")
    check("margin level trips", "margin level" in emergency_hit(2000, 1900, 140, 100, 0, 150, 0))
    check("free margin trips", "free margin" in emergency_hit(2000, 1900, 0, 50, 0, 0, 10))
    check("peak drawdown trips", "drawdown" in emergency_hit(2000, 1900, 0, 0, 0, 0, 0, peak_equity=4000, dd_pct=50))
    check("peak drawdown not tripped at exactly 50%", "drawdown" not in emergency_hit(2000, 2000.0, 0, 0, 0, 0, 0, peak_equity=4000, dd_pct=50))
    check("nothing to guard when off", emergency_hit(2000, 1000, 100, 0, 0, 0, 0) == "")

    # 11) manual news windows (tester fallback), server time
    win = "1-14:30-14:45;5-12:00-13:30"
    check("inside window", in_manual_window(14 * 60 + 35, 1, win))
    check("outside window", not in_manual_window(14 * 60 + 50, 1, win))
    check("wrong day ignored", not in_manual_window(14 * 60 + 35, 3, win))
    check("other day window works", in_manual_window(12 * 60 + 30, 5, win))
    check("malformed segment ignored", not in_manual_window(12 * 60 + 30, 5, "5:12:00-13:30"))
    check("overnight wrap", in_manual_window(23 * 60 + 50, 1, "22:00-01:00") and in_manual_window(30, 1, "22:00-01:00"))
    t0 = 1_700_000_000
    check("20 min before is inside", news_window_hit(t0 + 20 * 60, t0, 20, 15))
    check("21 min before is outside", not news_window_hit(t0 + 21 * 60, t0, 20, 15))
    check("15 min after is inside", news_window_hit(t0 - 15 * 60, t0, 20, 15))
    check("16 min after is outside", not news_window_hit(t0 - 16 * 60, t0, 20, 15))

    if fails:
        print("FAILED:")
        for f in fails:
            print("  - " + f)
        return 1
    print("GoldBasketGuard logic: %d/%d checks passed (TP/SL group, mirror, risk-free, trail, limits, sizing, cent, breaker, news)"
          % (passed[0], passed[0] + len(fails)))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--test", action="store_true", help="run the logic checks")
    ap.add_argument("--pips", type=float, help="convert pips to a gold price move")
    ap.add_argument("--digits", type=int, default=2, help="symbol digits (2 or 3 for XAUUSD)")
    ap.add_argument("--point", type=float, default=0.01)
    ap.add_argument("--override", type=float, default=0.0, help="InpPipSize value")
    ap.add_argument("--move", nargs=2, type=float, metavar=("FROM", "TO"), help="price move in pips")
    a = ap.parse_args()

    if a.test:
        return run_tests()
    pip = pip_size(a.digits, a.point, a.override)
    if a.pips is not None:
        print(f"{a.pips:g} pips = {a.pips * pip:.2f} USD of gold price ({a.pips * pip / a.point:g} points), pip = {pip}")
    if a.move:
        print(f"move {a.move[0]:.2f} -> {a.move[1]:.2f} = {(a.move[1] - a.move[0]) / pip:+.1f} pips")
    if a.pips is None and not a.move:
        print(f"pip for {a.digits}-digit symbol = {pip} ({pip / a.point:g} points)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
