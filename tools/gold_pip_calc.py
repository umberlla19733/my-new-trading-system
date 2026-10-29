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


def risk_warn(balance: float, equity: float, warn_pct: float) -> tuple[float, bool]:
    """Mirror of RiskWarning(): how much of the balance is in floating loss, and whether
    that deserves the warning. Read-only - it never decides to close anything."""
    if balance <= 0.0 or warn_pct <= 0.0:
        return 0.0, False
    pct = max(0.0, (balance - equity) / balance * 100.0)
    return pct, pct >= warn_pct


# --------------------------------------------------------------------------
# Panel switches, money fields, arms and the broker minimum (mirrored v1.14)
# --------------------------------------------------------------------------
SWITCHES = ("MIRROR", "AUTO", "BE", "WARN", "KILL", "BREAKER",
            "DAILY", "MONEY", "SIZING", "ADAPT", "ALERT", "DRY")


def _d(inputs: dict) -> dict:
    """Fill in the EA's own defaults so a test can name only what it cares about."""
    base = {"mirror_sl": True, "mirror_tp": True, "auto_apply_on_start": True,
            "be_mode": "BASKET_PIPS", "risk_warn_pct": 40.0, "enable_kill_switch": False,
            "max_dd_pct": 60.0, "emergency_float_loss_pct": 60,
            "daily_loss_pct": 0.0, "daily_profit_pct": 0.0,
            "basket_money_exit": False, "basket_take_money": 500.0, "basket_stop_money": 500.0,
            "risk_pct": 0.0, "adaptive_stops": True, "dry_run": False,
            "close_step_pct": 50.0, "persist_panel": True}
    base.update(inputs)
    return base


def bits_default(inputs: dict) -> int:
    """SwInitDefaults(): every switch starts where the Inputs left its feature."""
    i = _d(inputs)
    want = {
        "MIRROR":  i["mirror_sl"] or i["mirror_tp"],
        "AUTO":    i["auto_apply_on_start"],
        "BE":      i["be_mode"] != "OFF",
        "WARN":    i["risk_warn_pct"] > 0,
        "KILL":    i["enable_kill_switch"],
        "BREAKER": i["emergency_float_loss_pct"] > 0,
        "DAILY":   i["daily_loss_pct"] > 0 or i["daily_profit_pct"] > 0,
        "MONEY":   i["basket_money_exit"],
        "SIZING":  i["risk_pct"] > 0,
        "ADAPT":   i["adaptive_stops"],
        "ALERT":   True,
        "DRY":     i["dry_run"],
    }
    bits = 0
    for k, name in enumerate(SWITCHES):
        if want[name]:
            bits |= (1 << k)
    return bits


def gates(inputs: dict, bits: int) -> dict:
    """The Use*() gate list: some switches may only silence, others are in charge."""
    i = _d(inputs)
    on = {name: bool((bits >> k) & 1) for k, name in enumerate(SWITCHES)}
    return {
        "mirror":  (i["mirror_sl"] or i["mirror_tp"]) and on["MIRROR"],
        "auto":    on["AUTO"],
        "be":      i["be_mode"] != "OFF" and on["BE"],
        "warn":    i["risk_warn_pct"] > 0 and on["WARN"],
        "kill":    i["max_dd_pct"] > 0 and on["KILL"],
        "breaker": i["emergency_float_loss_pct"] > 0 and on["BREAKER"],
        "daily":   on["DAILY"] and (i["daily_loss_pct"] > 0 or i["daily_profit_pct"] > 0),
        "money":   on["MONEY"] and (i["basket_take_money"] > 0 or i["basket_stop_money"] > 0),
        "sizing":  on["SIZING"] and i["risk_pct"] > 0,
        "adapt":   on["ADAPT"],
        "alerts":  on["ALERT"],
        "dry":     i["dry_run"] or on["DRY"],
    }


def switch_bits_set(bits: int, name: str, on: bool) -> int:
    k = SWITCHES.index(name)
    return bits | (1 << k) if on else bits & ~(1 << k)


def can_turn_on(inputs: dict, name: str) -> bool:
    """SwCanTurnOn(): a switch may always silence; turning a feature ON needs its mode or threshold."""
    i = _d(inputs)
    return {
        "MIRROR":  i["mirror_sl"] or i["mirror_tp"],
        "BE":      i["be_mode"] != "OFF",
        "WARN":    i["risk_warn_pct"] > 0,
        "KILL":    i["max_dd_pct"] > 0,
        "BREAKER": i["emergency_float_loss_pct"] > 0,
        "DAILY":   i["daily_loss_pct"] > 0 or i["daily_profit_pct"] > 0,
        "MONEY":   i["basket_take_money"] > 0 or i["basket_stop_money"] > 0,
        "SIZING":  i["risk_pct"] > 0,
    }.get(name, True)


def money_to_pips(money: float, mpp: float) -> float:
    """SL money typed on the panel -> pips, with the live group volume."""
    if money <= 0 or mpp <= 0:
        return 0.0
    return money / mpp


def pips_to_money(pips: float, mpp: float) -> float:
    if pips <= 0 or mpp <= 0:
        return 0.0
    return pips * mpp


def read_money_field(fields: dict, key: str, mpp: float) -> tuple[float, dict]:
    """One-shot: the box is converted and then cleared, so it never fights a typed pip value."""
    out = dict(fields)
    pips = money_to_pips(float(fields.get(key, 0.0)), mpp)
    if pips > 0:
        out[key] = 0.0
    return pips, out


def part_pct(typed: float, default: float = 50.0) -> float:
    p = default if typed <= 0 else typed
    return min(95.0, max(5.0, p))


def arm_confirm(arms: dict, key: str, now: int, window: int = 6) -> tuple[bool, dict]:
    """Two clicks on the SAME button within the window; other buttons keep their own state."""
    out = dict(arms)
    prev = out.get(key, 0)
    if not prev or now - prev >= window:
        out[key] = now
        return False, out
    out[key] = 0
    return True, out


def clamp_level(raw: float, bid: float, ask: float, min_gap: float,
                buy: bool, is_sl: bool) -> tuple[float, str]:
    """FinalizeLevel(): reject only a level on the wrong side, clamp the broker minimum away."""
    if raw <= 0:
        return 0.0, "none"
    if buy and is_sl:
        if raw >= bid:
            return 0.0, "rejected"
        return (bid - min_gap, "clamped") if raw > bid - min_gap else (raw, "ok")
    if buy and not is_sl:
        if raw <= bid:
            return 0.0, "rejected"
        return (ask + min_gap, "clamped") if raw < ask + min_gap else (raw, "ok")
    if not buy and is_sl:
        if raw <= ask:
            return 0.0, "rejected"
        return (ask + min_gap, "clamped") if raw < ask + min_gap else (raw, "ok")
    if raw >= ask:
        return 0.0, "rejected"
    return (bid - min_gap, "clamped") if raw > bid - min_gap else (raw, "ok")


def ui_pack(bits: int, values: dict) -> dict:
    """What the panel writes into the GlobalVariable anchors."""
    out = {"SW": float(bits)}
    out.update({k: float(v) for k, v in values.items()})
    return out


def ui_unpack(saved: dict) -> tuple[int, dict]:
    bits = int(saved.get("SW", 0))
    values = {k: v for k, v in saved.items() if k != "SW"}
    return bits, values


# --------------------------------------------------------------------------
# The v1.14+ performance layer: snapshots, panel diffing, idle loop
# --------------------------------------------------------------------------
class Snapshot:
    """Mirror of SnapRead()/SnapReset() and the lazy accessors.

    A cycle reads balance, equity, margin, quotes and the clock ONCE. Any order
    marks the snapshot stale, so the next read goes back to the terminal - that
    is what keeps the circuit breaker from deciding on numbers from before a close.
    """

    def __init__(self, terminal):
        self.terminal = terminal            # dict of live values, as the terminal has them
        self.cache = {}
        self.reads = 0                      # accessor trips, the thing we are minimising
        self.fresh = False

    def get(self, key):
        if not self.fresh:
            self.reads += 1
            self.cache = dict(self.terminal)
            self.fresh = True
        return self.cache[key]

    def reset(self):
        self.fresh = False


def panel_writes(prev_sig, sig, forced):
    """RowSet()/OLabel() are only reached when the panel content really moved."""
    return forced or sig != prev_sig


def next_timer_ms(positions_total, group_tickets, fast_ms, idle_ms):
    """TuneTimer(): one Hz while the account holds nothing, 10 Hz as soon as it does."""
    if positions_total == 0 and group_tickets == 0:
        return max(fast_ms, idle_ms)
    return max(20, fast_ms)


def group_match(sym, magic, comment, pos_type, open_time, cfg):
    """Everything CollectGroup requires of a ticket: market position + MatchPosition."""
    if pos_type not in ("BUY", "SELL"):        # the loop's first line, before the rest
        return False
    if cfg.get("symbol_filter") and sym not in cfg["symbol_filter"]:
        return False
    if cfg.get("magic") and magic != cfg["magic"]:
        return False
    if pos_type == "BUY" and not cfg.get("buy", True):
        return False
    if pos_type == "SELL" and not cfg.get("sell", True):
        return False
    if cfg.get("ignore_manual") and not comment:
        return False
    if cfg.get("comment") and cfg["comment"] not in comment:
        return False
    if cfg.get("only_after_attach") and open_time < cfg["start"]:
        return False
    return True


def group_precheck(sym, magic, comment, pos_type, open_time, cfg):
    """The cheap pre-filter CollectGroup runs before it touches the expensive rules.

    It must never drop a ticket that the full check would have accepted.
    """
    if pos_type not in ("BUY", "SELL"):
        return False
    if pos_type == "BUY" and not cfg.get("buy", True):
        return False
    if pos_type == "SELL" and not cfg.get("sell", True):
        return False
    if cfg.get("magic") and magic != cfg["magic"]:
        return False
    if cfg.get("only_after_attach") and open_time < cfg["start"]:
        return False
    if cfg.get("symbol_filter") and sym not in cfg["symbol_filter"]:
        return False
    return True


# --------------------------------------------------------------------------
# v1.16: the EA has to stay alive - cool-down, fuse, lock expiry, watchdog
# --------------------------------------------------------------------------
class SendGuard:
    """Mirror of BoHeld()/BoHold()/FuseOn()/FuseTrip() in front of OrderSend.

    The old behaviour was the dangerous one: a refused request was repeated on
    every 100 ms cycle, four times per ticket, with a Sleep() in between - and a
    broker or terminal that is refusing you does not change its mind about that.
    """

    CAP_MS = 60000

    def __init__(self, backoff_ms=2000, retry_delay_ms=120, fuse_count=8, now=0):
        self.backoff_ms = backoff_ms
        self.retry_delay_ms = retry_delay_ms
        self.fuse_count = fuse_count
        self.now = now
        self.table = {}          # ticket -> (level signature, held until, failures)
        self.run = 0             # refusals in a row
        self.step = 0            # how often the fuse cooldown has doubled
        self.until = 0           # fuse expiry, ms
        self.manual = False      # a manual APPLY bought exactly one attempt
        self.sent = 0
        self.refused = 0

    def tick(self, ms):
        self.now += ms

    def fuse_on(self):
        if self.until and self.now >= self.until:
            self.until = 0
            self.step = 0
        return self.until > 0

    def close_allowed(self):
        """Closing is never held back: an unwanted position is worse than a slow retry."""
        return True

    def allowed(self, ticket, sig, protective=False):
        if self.fuse_on() and not self.manual:
            return False
        if self.backoff_ms > 0 and not protective:
            held = self.table.get(ticket)
            if held and held[0] == sig and held[1] > self.now:
                return False
        return True

    def spend_manual(self):
        self.manual = False

    def note_ok(self, ticket):
        self.sent += 1
        self.run = 0
        self.table.pop(ticket, None)

    def note_fail(self, ticket, sig):
        self.refused += 1
        prev = self.table.get(ticket)
        fails = (prev[2] + 1) if prev else 1
        ms = max(self.backoff_ms, self.retry_delay_ms)
        for _ in range(1, fails):
            ms *= 2
            if ms >= self.CAP_MS:
                ms = self.CAP_MS
                break
        self.table[ticket] = (sig, self.now + min(self.CAP_MS, ms), fails)
        if self.fuse_count <= 0:
            return 0
        self.run += 1
        if self.run < self.fuse_count:
            return 0
        self.run = 0
        secs = min(300, 30 << self.step)
        self.step += 1
        self.until = self.now + secs * 1000
        return secs


def lock_tick(now_server, lock_until, paused, killed):
    """LockoutTick(): the lock has to expire on its own, breaker flag or not."""
    if lock_until <= 0:
        return lock_until, paused, killed, ""
    if now_server >= lock_until:
        return 0, False, False, "lockout expired - automation resumed"
    return lock_until, True, killed, "locked"


def watchdog_due(now, last, timer_ms, fast_ms, tester=False, last_watch=0, throttle=30000):
    """A chart that switched templates can lose its timer; the next tick re-arms it."""
    if tester or fast_ms <= 0 or last <= 0:
        return False
    if now - last <= max(1500, 6 * timer_ms):
        return False
    return now - last_watch > throttle


def send_pressure(tickets, retries):
    """OrderSend attempts per cycle for a stuck basket: before / after v1.16."""
    return tickets * (retries + 1), max(1, tickets)


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



class StickerLog:
    """Mirror of g_st[] + DetectManualEdits() -- which SL/TP diff counts as manual.

    v1.12 rule: our own modify is suppressed by *request identity* (the exact level we
    asked the server for), never by a blind multi-second window, and the clock used is
    GetTickCount64() (ms), not TimeCurrent() -- so sparse ticks cannot freeze it and a
    fast manual drag is never silently dropped.
    """

    def __init__(self, guard_ms: int = 250):
        self.guard_ms = guard_ms
        self.rec: dict[int, dict] = {}

    @staticmethod
    def same(a: float, b: float, pt: float) -> bool:
        return abs(a - b) <= pt

    def remember(self, t: "Ticket", now_ms: int = 0, pt: float = 1e-5) -> None:
        self.rec[t.ticket] = dict(sl=t.sl, tp=t.tp, seen_ms=now_ms,
                                  req_sl=0.0, req_tp=0.0, req_ms=0, pending=False)

    def mark_sent(self, t: "Ticket", now_ms: int) -> None:
        """What TryModify() does after the server accepted exactly sl/tp."""
        r = self.rec[t.ticket]
        r.update(req_sl=t.sl, req_tp=t.tp, req_ms=now_ms, pending=True)

    def pending_live(self, tk: int, now_ms: int) -> bool:
        r = self.rec[tk]
        if not r["pending"]:
            return False
        if now_ms - r["req_ms"] > max(500, 4 * self.guard_ms):
            r["pending"] = False            # the echo never arrived: unblock the ticket
            return False
        return True

    def scan(self, tickets: list, now_ms: int, pt: float = 1e-5) -> list:
        """Tickets the trader really changed -- the EA mirrors exactly those."""
        edits = []
        for t in tickets:
            tk = t.ticket
            if tk not in self.rec:
                self.remember(t, now_ms, pt)         # new ticket: just record it
                continue
            r = self.rec[tk]
            sl_diff = not self.same(t.sl, r["sl"], pt)
            tp_diff = not self.same(t.tp, r["tp"], pt)
            if not sl_diff and not tp_diff:
                matched = self.same(t.sl, r["req_sl"], pt) and self.same(t.tp, r["req_tp"], pt)
                if r["pending"] and (matched or now_ms - r["req_ms"] > self.guard_ms):
                    r["pending"] = False             # request settled (or the window passed)
                continue
            echoed = (r["pending"] and self.same(t.sl, r["req_sl"], pt)
                      and self.same(t.tp, r["req_tp"], pt))
            if r["pending"] and not echoed and self.pending_live(tk, now_ms):
                continue                             # in flight: retry next cycle, never drop
            r["pending"] = False
            self.remember(t, now_ms, pt)             # memory holds the trader's values now
            if echoed:
                continue                             # that one was ours
            edits.append(t)
        return edits

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

    # 10) the "60% of the account is at risk" breaker (the only automatic close-all)
    check("60% floating loss trips", "floating loss" in emergency_hit(2000, 800, 200, 500, 60, 0, 0))
    check("59% floating loss does not trip", emergency_hit(2000, 820, 200, 500, 60, 0, 0) == "")
    check("margin level is off in the default policy", emergency_hit(2000, 1900, 100, 100, 60, 0, 0) == "")
    check("margin level still works when armed", "margin level" in emergency_hit(2000, 1900, 140, 100, 60, 150, 0))
    # the 40% warning is loud but harmless: it never closes
    check("warn at 40% of balance", risk_warn(2000, 1200, 40)[1] and abs(risk_warn(2000, 1200, 40)[0] - 40.0) < 1e-9)
    check("warn silent at 39%", not risk_warn(2000, 1210, 40)[1])
    check("warn does not close: 40% is below the 60% line", emergency_hit(2000, 1200, 0, 0, 60, 0, 0) == "")
    check("percentages are cent-account neutral", risk_warn(200000, 120000, 40) == risk_warn(2000, 1200, 40))
    check("warn off = no readout at all", risk_warn(2000, 100, 0) == (0.0, False))
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

    # 12) mirror echo guard: identity-based, ms clock, never a silent drop
    b = _mk()
    st = StickerLog(guard_ms=250)
    for t in b.tickets:
        st.remember(t)                                # memory = reality before the apply
    b.apply_group("APPLY_SAME_LEVEL", sl_pips=500, tp_pips=0)     # EA writes SL to all 3
    for t in b.tickets:
        st.remember(t, now_ms=900)                    # TryModify re-reads the accepted level
        st.mark_sent(t, now_ms=1000)                  # ... and remembers the request
    check("own echo is not a manual edit", st.scan(b.tickets, now_ms=1040) == [])
    check("echo cleared the pending flag", all(not st.rec[t.ticket]["pending"] for t in b.tickets))
    b.tickets[1].sl = 2605.0                          # trader drags SL right after the echo
    check("edit right after an apply is seen at once",
          [t.ticket for t in st.scan(b.tickets, now_ms=1080)] == [2])
    b2 = _mk()
    st2 = StickerLog(guard_ms=250)
    for t in b2.tickets:
        st2.remember(t)
        st2.mark_sent(t, now_ms=1000)                 # our request is still in flight
    b2.tickets[2].sl = 2611.0                         # a value we did not ask for
    check("in-flight edit deferred, not dropped", st2.scan(b2.tickets, now_ms=1040) == [])
    check("deferred edit mirrored once the echo window passes",
          [t.ticket for t in st2.scan(b2.tickets, now_ms=2100)] == [3])
    b3 = _mk()                                        # sparse ticks: TimeCurrent frozen
    st3 = StickerLog(guard_ms=250)
    for t in b3.tickets:
        st3.remember(t, now_ms=5000)
    b3.tickets[0].tp = 2700.0
    check("ms clock sees the edit even without a new tick",
          [t.ticket for t in st3.scan(b3.tickets, now_ms=5100)] == [1])
    check("adopted value does not loop", st2.scan(b2.tickets, now_ms=2200) == [])
    check("pending cleared when the edit is adopted", not st2.rec[3]["pending"])
    b4 = _mk()                                        # broker snapped our level by 1 point
    b4.tickets[0].sl = b4.tickets[0].sl - 0.001
    st4 = StickerLog(guard_ms=250)
    for t in b4.tickets:
        st4.remember(t, now_ms=0)                     # memory = what the server accepted
        st4.mark_sent(t, now_ms=0)                    # request = what we asked for
    check("snapped level settles without a correction loop",
          st4.scan(b4.tickets, now_ms=400) == [] and st4.scan(b4.tickets, now_ms=500) == [])
    check("echo window closes on its own", all(not st4.rec[t.ticket]["pending"] for t in b4.tickets))

    # 11) v1.14 panel switches: input AND switch, persistence, money fields, arms
    g0 = gates({}, bits_default({}))
    check("defaults keep the v1.13 policy (kill off, breaker on, warn on)",
          g0["kill"] is False and g0["breaker"] is True and g0["warn"] is True
          and g0["money"] is False and g0["sizing"] is False and g0["daily"] is False
          and g0["auto"] is True and g0["be"] is True and g0["adapt"] is True
          and g0["alerts"] is True and g0["dry"] is False)
    check("switch state is exactly the input state at start",
          bits_default({}) == bits_default({"enable_kill_switch": False}))
    b_kill = switch_bits_set(bits_default({}), "KILL", True)
    check("panel switch turns the optional kill switch on without touching Inputs",
          gates({}, b_kill)["kill"] is True)
    b_q = switch_bits_set(bits_default({}), "BREAKER", False)
    g_q = gates({}, b_q)
    hit = emergency_hit(10000.0, 3000.0, 500.0, 1000.0, 60.0, 0.0, 0.0)
    check("switch off silences the close-all even at 70% risk",
          hit != "" and not g_q["breaker"])
    check("and the same account still closes when the switch is on",
          gates({}, bits_default({}))["breaker"] is True)
    check("a switch cannot invent a threshold (sizing needs InpRiskPctPerBasket)",
          gates({"risk_pct": 0.0}, switch_bits_set(bits_default({}), "SIZING", True))["sizing"] is False
          and can_turn_on({"risk_pct": 0.0}, "SIZING") is False)
    check("a switch cannot invent a threshold (daily needs a limit)",
          can_turn_on({}, "DAILY") is False and can_turn_on({"daily_loss_pct": 5.0}, "DAILY") is True)
    check("silencing always works, even for a feature the Inputs configured",
          gates({}, switch_bits_set(bits_default({}), "WARN", False))["warn"] is False)
    b_dry = switch_bits_set(bits_default({}), "DRY", True)
    b_noalert = switch_bits_set(bits_default({}), "ALERT", False)
    events = ["breaker fired", "risk-free reached"]
    check("DRY-RUN from the panel sends nothing",
          gates({}, b_dry)["dry"] is True and gates({"dry_run": True}, bits_default({}))["dry"] is True)
    check("ALERTS off hushes every pop-up but keeps the decisions",
          (lambda g: (len(events) if g["alerts"] else 0) == 0)(gates({}, b_noalert))
          and gates({}, b_noalert)["be"] is True)
    mpp = money_per_pip(0.40, 0.10, 0.01, 1.0)
    check("0.40 lot on gold = $4 per pip", abs(mpp - 4.0) < 1e-9)
    check("SL money 200 -> 50 pips", abs(money_to_pips(200.0, mpp) - 50.0) < 1e-9)
    check("pips back to money", abs(pips_to_money(50.0, mpp) - 200.0) < 1e-9)
    # the typed money and the per-pip value are both in ACCOUNT currency, so a cent
    # account multiplies both sides and the pips come out identical - no factor needed
    check("cent account: same pips when both sides speak cents",
          abs(money_to_pips(200.0 * 100.0, mpp * 100.0) - money_to_pips(200.0, mpp)) < 1e-12)
    check("no group volume -> no conversion (money stays put)",
          money_to_pips(200.0, 0.0) == 0.0)
    pips_left, fields_after = read_money_field({"SLM": 200.0, "TPM": 0.0}, "SLM", mpp)
    check("money box is one-shot: converted then cleared",
          abs(pips_left - 50.0) < 1e-9 and fields_after["SLM"] == 0.0
          and read_money_field(fields_after, "SLM", mpp)[0] == 0.0)
    check("CLOSE PART percent is clamped into a sane band",
          part_pct(3.0) == 5.0 and part_pct(99.0) == 95.0 and part_pct(0.0) == 50.0
          and part_pct(25.0, default=30.0) == 25.0)
    arms: dict[str, int] = {}
    fired, arms = arm_confirm(arms, "CLOSEALL", 100)
    fired2, arms2 = arm_confirm(arms, "CLOSELOSE", 101)
    check("first click only arms the button", fired is False and fired2 is False)
    check("one button's arm does not steal another's (v1.13 bug)",
          arms2.get("CLOSEALL") == 100 and arm_confirm(arms2, "CLOSEALL", 102)[0] is True)
    check("the window expires on its own",
          arm_confirm(arm_confirm({}, "CLOSEWIN", 200)[1], "CLOSEWIN", 210)[0] is False)
    v, st = clamp_level(2649.90, 2650.0, 2650.01, 0.20, True, True)
    check("a stop inside the broker minimum is clamped, not dropped",
          st == "clamped" and abs(v - 2649.80) < 1e-9)
    check("a level the broker accepts is left alone",
          clamp_level(2645.0, 2650.0, 2650.01, 0.20, True, True) == (2645.0, "ok"))
    check("clamping moves the stop away from the market, never closer", v < 2649.90)
    check("a level on the wrong side is still rejected",
          clamp_level(2655.0, 2650.0, 2650.01, 0.20, True, True) == (0.0, "rejected"))
    check("TP clamp keeps the target at least the broker minimum away",
          clamp_level(2650.05, 2650.0, 2650.01, 0.20, True, False)[1] == "clamped")
    saved = ui_pack(bits_default({}), {"SLP": 300.0, "TPP": 500.0, "BEA": 200.0, "ABSL": 0.0})
    back_bits, back_vals = ui_unpack(saved)
    check("panel values survive a round trip through the anchors",
          back_bits == bits_default({}) and back_vals["SLP"] == 300.0 and back_vals["ABSL"] == 0.0)
    check("RESET UI returns to the inputs (no anchors left behind)",
          gates({}, ui_unpack({"SW": float(bits_default({}))})[0])["kill"] is False
          and bits_default({}) == bits_default({"persist_panel": False}))

    # 12) the lightness layer: snapshot, panel diff, idle loop, pre-filter
    term = {"bal": 10000.0, "eq": 9400.0, "ml": 410.0, "fm": 8000.0}
    snap = Snapshot(term)
    for _ in range(6):
        snap.get("eq")
    check("one snapshot per cycle, not one per guard", snap.reads == 1)
    term["eq"] = 3500.0                        # an order went out and moved equity
    snap.reset()
    check("an order invalidates the snapshot", snap.get("eq") == 3500.0 and snap.reads == 2)
    snap.get("bal")
    check("reads inside one cycle stay cached", snap.reads == 2)
    check("a quiet chart writes nothing", panel_writes(42, 42, False) is False)
    check("a click paints at once even with the same numbers", panel_writes(42, 42, True) is True)
    check("changed numbers paint", panel_writes(42, 43, False) is True)
    check("idle loop is 1 Hz, live loop 10 Hz",
          next_timer_ms(0, 0, 100, 1000) == 1000 and next_timer_ms(3, 3, 100, 1000) == 100)
    check("positions outside the group still keep the fast loop",
          next_timer_ms(2, 0, 100, 1000) == 100)
    cfgs = [{}, {"magic": 7}, {"buy": False}, {"sell": False}, {"ignore_manual": True},
            {"comment": "GBG"}, {"only_after_attach": True, "start": 100},
            {"symbol_filter": {"XAUUSD"}, "magic": 7, "comment": "GBG", "only_after_attach": True,
             "start": 100}]
    ok = True
    for sym in ("XAUUSD", "EURUSD"):
        for mg in (0, 7, 9):
            for cmt in ("", "GBG-3", "manual note"):
                for typ in ("BUY", "SELL", "PENDING"):
                    for ot in (50, 100, 500):
                        for c in cfgs:
                            if group_precheck(sym, mg, cmt, typ, ot, c) is False and \
                               group_match(sym, mg, cmt, typ, ot, c) is True:
                                ok = False
    check("the cheap pre-filter never drops a ticket the group would take", ok)

    # 13) staying alive: cool-down, fuse, lock expiry, watchdog
    g = SendGuard()
    check("the first refusal holds this level for 2 s",
          g.allowed(11, "a|b") and (g.note_fail(11, "a|b") or not g.allowed(11, "a|b")))
    check("a different level for the same ticket goes at once", g.allowed(11, "c|d"))
    check("a protective move never waits", g.allowed(11, "a|b", protective=True))
    g.tick(500)
    check("the same level still waits inside the window", not g.allowed(11, "a|b"))
    g.tick(2000)
    check("and goes after the window", g.allowed(11, "a|b"))
    g2 = SendGuard()
    g2.note_fail(7, "x|y")
    check("the first refusal holds for 2 s", g2.table[7][1] - g2.now == 2000)
    g2.note_fail(7, "x|y")
    check("the second refusal doubles to 4 s", g2.table[7][1] - g2.now == 4000)
    for _ in range(9):
        g2.note_fail(7, "x|y")
    check("the cool-down never exceeds 60 s", g2.table[7][1] - g2.now <= 60000)
    g2.note_ok(7)
    check("an accepted request clears the history", 7 not in g2.table)
    g3 = SendGuard(backoff_ms=0)
    g3.note_fail(3, "s")
    check("InpSendBackoffMs = 0 keeps the old retry-every-cycle behaviour", g3.allowed(3, "s"))
    g4 = SendGuard()
    secs = 0
    for i in range(8):
        secs = g4.note_fail(40 + i, "same")
    check("eight refusals in a row blow the fuse for 30 s", secs == 30 and g4.fuse_on())
    check("the fuse stops automatic modifies", not g4.allowed(40, "same"))
    check("the fuse never stops a close", g4.close_allowed())
    g4.manual = True
    check("APPLY buys exactly one attempt through the fuse", g4.allowed(99, "fresh"))
    g4.spend_manual()
    check("and only one", not g4.allowed(99, "fresh"))
    g4.tick(30000)
    check("the fuse expires by itself", not g4.fuse_on())
    g5 = SendGuard(fuse_count=0)
    for i in range(30):
        g5.note_fail(50 + i, "s")
    check("the fuse can be switched off", not g5.fuse_on())
    check("lock expiry also clears the breaker flag (v1.15 bug)",
          lock_tick(200, 100, True, True) == (0, False, False, "lockout expired - automation resumed"))
    check("an active lock keeps the EA paused", lock_tick(50, 100, False, False)[1] is True)
    check("no lock, no change", lock_tick(50, 0, False, False) == (50 and 0, False, False, "") or
          lock_tick(50, 0, False, False) == (0, False, False, ""))
    check("watchdog waits for six idle cycles, not five",
          watchdog_due(47000, 41000, 1000, 100) is False and watchdog_due(47001, 41000, 1000, 100) is True)
    check("watchdog floor is 1500 ms when the loop is fast",
          watchdog_due(46400, 45000, 100, 100) is False and watchdog_due(46600, 45000, 100, 100) is True)
    check("watchdog never fires in the tester", watchdog_due(46600, 45000, 100, 100, tester=True) is False)
    check("watchdog re-arms at most once every 30 s",
          watchdog_due(46600, 45000, 100, 100, last_watch=45100) is False)
    check("one attempt per ticket per cycle instead of four",
          send_pressure(5, 3) == (20, 5))

    if fails:
        print("FAILED:")
        for f in fails:
            print("  - " + f)
        return 1
    print("GoldBasketGuard logic: %d/%d checks passed (TP/SL group, mirror + echo guard, risk-free, "
          "trail, limits, sizing, cent, 60%% breaker, 40%% warning, news, panel switches + money "
          "fields, lightness layer, send protection)" % (passed[0], passed[0] + len(fails)))
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
