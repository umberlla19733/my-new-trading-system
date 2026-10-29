#!/usr/bin/env python3
"""Render a Persian diagram of HOW GoldBasketGuard manages risk at runtime.

make_feature_sheet.py answers "what does it have"; this answers "what happens
on every tick, and where the protective levels end up". Three blocks:

  A. the decision pipeline of one tick    (numbered, right-to-left serpentine)
  B. the profit-locking ladder on gold    (chart, simulated from the EA rules)
  C. the account-level ceilings           (gauge, from the same numbers)

All figures are read from the EA's input defaults, overlaid with the chosen
the EA's own input defaults, and block B replays the real risk-free / trailing rules
picture cannot quietly drift away from the code.

    python3 tools/make_flow_sheet.py --out docs/GoldBasketGuard-flow-fa.png
    python3 tools/make_flow_sheet.py --out docs/GoldBasketGuard-flow-fa.png

Needs: pillow, arabic-reshaper, python-bidi, Vazirmatn TTFs (same as the sheet).
"""
from __future__ import annotations

import argparse
import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from PIL import Image, ImageDraw  # noqa: E402

import make_feature_sheet as M  # shared styling, fonts, shaping, wrapping  # noqa: E402

S, W, PAD = M.S, M.W, M.PAD
BG, CARD, CARD2 = M.BG, M.CARD, M.CARD2
GOLD, TEXT, DIM = M.GOLD, M.TEXT, M.DIM
GREEN, RED, BLUE, ORANGE, CYAN = M.GREEN, M.RED, M.BLUE, M.ORANGE, M.CYAN
ROOT = Path(__file__).resolve().parent.parent
EA = ROOT / "MQL5/Experts/GoldBasketGuard/GoldBasketGuard.mq5"
ENTRY = 2641.25                                  # basket average entry of the sample path
NUM = r"-?\d+(?:\.\d+)?"


# ------------------------------------------------------------------ data layer
def ea_inputs() -> dict:
    """`input double InpX = 300.0; // ...` -> {'InpX': '300.0'} plus enum maps."""
    src = EA.read_text(encoding="utf-8")
    out = {}
    for ln in src.splitlines():
        m = re.match(r"\s*input\s+[\w:<>]+\s+(\w+)\s*=\s*([^;]+);", ln)
        if m:
            out[m.group(1)] = m.group(2).strip().strip('"')
    for name, body in re.findall(r"enum\s+(\w+)\s*\{(.*?)\};", src, re.S):
        for member, val in re.findall(r"^\s*(\w+)\s*=\s*(\w+)", body, re.M):
            out[f"__enum__{name}__{val}"] = member
    return out


def load_config() -> dict:
    """The EA's defaults ARE the configuration -- nothing to load on top."""
    return ea_inputs()


def switch_count() -> int:
    """How many on/off switches the panel exposes (read from the EA, never typed here)."""
    src = EA.read_text(encoding="utf-8")
    m = re.search(r"enum ENUM_SWITCH.*?\{(.*?)\};", src, re.S)
    return len(re.findall(r"SW_\w+\s*=", m.group(1))) if m else 0


def enum_name(cfg: dict, enum: str, key: str) -> str:
    raw = cfg.get(key, "0")
    return cfg.get(f"__enum__{enum}__{raw}", raw) if re.fullmatch(NUM, raw) else raw


def fnum(cfg: dict, key: str, default: float = 0.0) -> float:
    try:
        return float(cfg.get(key, default))
    except (TypeError, ValueError):
        return float(default)


def flag(cfg: dict, key: str) -> bool:
    return str(cfg.get(key, "false")).lower() in ("true", "1")


def pnum(v: float) -> str:
    """Persian number: 200.0 -> ۲۰۰, 1.5 -> ۱٫۵"""
    t = f"{v:g}"
    return M.persian_digits(t).replace(".", "٫")


# --------------------------------------------------------------------- block A
def pipeline(cfg: dict) -> list:
    """Order of operations inside Manage(), with the defaults shipped in the file."""
    sl, tp = fnum(cfg, "InpSLPips", 300), fnum(cfg, "InpTPPips", 500)
    be, arm, lock = enum_name(cfg, "ENUM_BE_MODE", "InpBeMode"), fnum(cfg, "InpBeTriggerPips", 200), fnum(cfg, "InpBeLockPips", 10)
    trail = enum_name(cfg, "ENUM_TRAIL_MODE", "InpTrailMode")
    news_act = enum_name(cfg, "ENUM_NEWS_ACTION", "InpNewsAction")
    risk_pct = fnum(cfg, "InpRiskPctPerBasket")
    steps = [
        ("شروع هر تیک", f"OnTick و تایمر {pnum(fnum(cfg, 'InpTimerMs'))} میلی‌ثانیه؛ سقف {pnum(fnum(cfg, 'InpMaxModsPerSecond'))} درخواست تغییر در ثانیه. اگر حساب هیچ پوزیشنی نداشته باشد تایمر تا {pnum(fnum(cfg, 'InpIdleRefreshMs'))} میلی‌ثانیه آرام می‌شود و با اولین پوزیشن برمی‌گردد؛ یک snapshot از حساب و قیمت در شروع چرخه خوانده می‌شود و بین همهٔ گاردها تقسیم می‌گردد", GOLD),
        ("گروه را پیدا کن", "سمبل + مَجیک + کامنت + جهت + فیلتر زمان؛ تشخیص hedging یا netting", BLUE),
        ("سبد را بساز", "میانگین ورود، حجم کل، پیپ سود/زیان، ریسک روی SL، کمیسیون و swap برآوردی", BLUE),
        ("ویرایش دستی شده؟", "اگر SL یا TP یک معامله را عوض یا پاک کردی، همان روی همهٔ گروه کپی می‌شود؛ داخل خودِ رویداد معامله، بدون پنجرهٔ کوری چندثانیه‌ای", BLUE),
        ("سطح مطلوب گروه", f"حد ضرر {pnum(sl)} پیپ و حد سود {pnum(tp)} پیپ، در حالت اعمال انتخابی", GOLD),
    ]
    nsw = switch_count()
    if nsw:
        steps.insert(5, ("کلیدهای پنل",
                         f"{M.pd(nsw)} کلید روشن/خاموش روی صفحهٔ دوم پنل (کلید {M.pd(8)})؛ "
                         "خاموش کردن همیشه از پنل ممکن است، روشن کردن وقتی Inputs آستانه یا حالتش را داده باشد؛ "
                         f"انتخاب‌ها برای همین حساب و نماد ذخیره می‌شوند (InpPersistPanel={'روشن' if flag(cfg, 'InpPersistPanel') else 'خاموش'})",
                         CYAN))
    if flag(cfg, "InpNewsEnabled"):
        steps.append(("گارد اخبار قرمز",
                      f"تقویم MT5، فقط اهمیت HIGH؛ {pnum(fnum(cfg, 'InpNewsBeforeMin', 20))} دقیقه قبل "
                      f"تا {pnum(fnum(cfg, 'InpNewsAfterMin', 15))} دقیقه بعد؛ {news_act}", RED))
    if be != "BE_OFF":
        steps.append(("ریسک‌فری خودکار",
                      f"سود گروه ≥ {pnum(arm)} پیپ؛ SL روی ورود + {pnum(lock)} پیپ ({be}، یک‌بار)", GREEN))
    if trail != "TRAIL_OFF":
        steps.append(("تریلینگ",
                      f"از {pnum(fnum(cfg, 'InpTrailStartPips', 250))} پیپ، هر {pnum(fnum(cfg, 'InpTrailStepPips', 30))} پیپ یک پله؛ "
                      "حد ضرر هرگز عقب نمی‌رود", GREEN))
    if flag(cfg, "InpBeClosePartial"):
        steps.append(("بستن جزئی", f"{pnum(fnum(cfg, 'InpBeClosePartialPct', 30))}٪ از حجم سبد هم‌زمان با ریسک‌فری", GREEN))
    if risk_pct > 0:
        steps.append(("سایز ریسک", f"هر سبد {pnum(risk_pct)}٪ موجودی؛ فاصلهٔ SL و TP خودش حساب می‌شود", ORANGE))
    if flag(cfg, "InpEnableKillSwitch"):
        steps.append(("سقف افت حساب",
                      f"زیان شناور گروه > {pnum(fnum(cfg, 'InpMaxDrawdownPctEquity', 15))}٪ equity؛ kill-switch و بستن همه", ORANGE))
    if fnum(cfg, "InpDailyLossLimitPct") or fnum(cfg, "InpDailyProfitTargetPct"):
        steps.append(("نگهبان روزانه",
                      f"حد ضرر روز {pnum(fnum(cfg, 'InpDailyLossLimitPct'))}٪ / هدف سود {pnum(fnum(cfg, 'InpDailyProfitTargetPct'))}٪؛ توقف تا نیمه‌شب سرور", CYAN))
    fl = fnum(cfg, "InpEmergencyFloatLossPct")
    ml = fnum(cfg, "InpEmergencyMarginLevelPct")
    if fl or ml:
        conds = []
        if fl:
            conds.append(f"زیان شناور اکانت ≥ {pnum(fl)}٪ موجودی")
        if ml:
            conds.append(f"margin level < {pnum(ml)}٪")
        steps.append(("بریکر اضطراری", " یا ".join(conds) + "؛ بستن همهٔ پوزیشن‌ها", RED))
    steps.append(("اعمال و قفل",
                  f"TryModify با رعایت STOPS/FREEZE و سقف {pnum(fnum(cfg, 'InpMaxModsPerSecond'))} درخواست در ثانیه؛ "
                  f"اگر سرور رد کند همان سطح برای همان تیکت {pnum(fnum(cfg, 'InpSendBackoffMs'))} میلی‌ثانیه تکرار نمی‌شود "
                  f"(با هر رد شدن دو برابر، تا سقف یک دقیقه) و پس از {pnum(fnum(cfg, 'InpErrorFuseCount'))} رد شدن "
                  f"پشت‌سرهم فرستادن خودکار برای نیم دقیقه ساکت می‌شود — بستن پوزیشن هیچ‌وقت معطل نمی‌ماند. "
                  f"پس از اضطرار: قفل {pnum(fnum(cfg, 'InpEmergencyLockHours', 24))} ساعت که خودش باز می‌شود (یا UNLOCK / کلید ۷)",
                  GOLD))
    return steps


# ------------------------------------------------------------------ block B
PROFIT = [0, 18, -42, -16, 26, 74, 118, 152, 188, 206, 232, 262, 244, 226, 254, 296,
          334, 306, 282, 322, 364, 402, 382, 424, 462, 442, 486, 520, 498, 542, 566,
          540, 520, 562, 604, 586, 626, 612, 648]


def simulate(cfg: dict):
    """Replay the EA's protective logic on the sample gold path.

    Returns (basket pips, group SL in pips, events). Risk-free arms on the
    basket trigger, then step-trailing ratchets the SL forward only.
    """
    sl = -fnum(cfg, "InpSLPips", 300)
    arm, lock = fnum(cfg, "InpBeTriggerPips", 200), fnum(cfg, "InpBeLockPips", 10)
    start, step, dist = (fnum(cfg, "InpTrailStartPips", 250), fnum(cfg, "InpTrailStepPips", 30),
                         fnum(cfg, "InpTrailDistPips", 120))
    be_on = enum_name(cfg, "ENUM_BE_MODE", "InpBeMode") != "BE_OFF"
    trail_on = enum_name(cfg, "ENUM_TRAIL_MODE", "InpTrailMode") == "TRAIL_STEP"
    out, events, done, last_k = [], [], False, -1
    for i, p in enumerate(PROFIT):
        if be_on and not done and p >= arm:
            sl, done = max(sl, lock), True
            events.append((i, p, f"ریسک‌فری: SL روی +{pnum(lock)} پیپ", GREEN))
        if trail_on and p >= start:
            k = int((p - start) // step)
            if k > last_k:
                last_k = k
                if p - dist > sl:
                    sl = p - dist
                    if len(events) < 5:
                        events.append((i, p, f"پلهٔ {M.persian_digits(k + 1)}: SL روی +{pnum(sl)} پیپ", CYAN))
        out.append(sl)
    return PROFIT, out, events


def chart_height(cfg: dict) -> int:
    """Panel height: plot + price axis + one legend line per ratchet event."""
    _, _, events = simulate(cfg)
    return 470 * S + len(events) * int(19 * S * 1.5) + 70 * S


def ceilings(cfg: dict) -> list:
    """Rungs on the account gauge: (percent of balance at risk, label, colour)."""
    rows = []
    if flag(cfg, "InpEnableKillSwitch"):
        rows.append((fnum(cfg, "InpMaxDrawdownPctEquity", 15),
                     "٪  ·  سقف افت سرمایهٔ کل؛ قطع اضطراری و توقف اکسپرت", ORANGE))
    dd = fnum(cfg, "InpEmergencyEquityDdPct")
    if dd:
        rows.append((dd, "٪  ·  افت سرمایه از سقف ثبت‌شده؛ بستن همه", ORANGE))
    dl = fnum(cfg, "InpDailyLossLimitPct")
    if dl:
        rows.append((dl, "٪ — حد ضرر روزانه؛ توقف تا نیمه‌شب وقت سرور", CYAN))
    warn = fnum(cfg, "InpRiskWarnPct")
    if warn:
        rows.append((warn, "٪  ·  هشدار ریسک (Alert و پوش)؛ هیچ دستوری فرستاده نمی‌شود", CYAN))
    fl = fnum(cfg, "InpEmergencyFloatLossPct")
    if fl:
        rows.append((fl, "٪  ·  زیان شناور کل حساب؛ بستن همه و قفل اکسپرت", RED))
    rows.sort(key=lambda r: r[0])
    return rows


def width_of(i: int, steps: list, cw: int, gap: int) -> int:
    """Width of box i: the last one spans both columns when the count is odd."""
    if len(steps) % 2 == 1 and i == len(steps) - 1:
        return 2 * cw + gap
    return cw


# ---------------------------------------------------------------------- render
class Flow:
    def __init__(self, sh: M.Sheet, cfg: dict):
        self.sh, self.d, self.cfg = sh, sh.d, cfg
        self.d = sh.d
        self.y = PAD

    def fa(self, t):
        return M.fa(t)

    def section(self, title: str):
        d = self.d
        d.text((W - PAD, self.y), self.fa(title), font=self.sh.h3, fill=GOLD, anchor="ra")
        t = d.textlength(self.fa(title), font=self.sh.h3)
        d.line([PAD, self.y + 17 * S, W - PAD - t - 22 * S, self.y + 17 * S], fill=(46, 58, 80), width=2 * S)
        self.y += 52 * S

    def header(self):
        d = self.d
        title = "نقشهٔ عملکرد: مدیریت سرمایه در هر تیک"
        d.text((W - PAD, self.y), self.fa(title), font=self.sh.title_f, fill=TEXT, anchor="ra")
        tw = d.textlength(self.fa(title), font=self.sh.title_f)
        d.text((W - PAD - tw - 24 * S, self.y + 32 * S), "GoldBasketGuard · runtime flow",
               font=self.sh.f.get("Vazirmatn-Medium.ttf", 24 * S), fill=GOLD, anchor="rm")
        self.y += 76 * S
        sub = ("همهٔ اعداد از مقادیر پیش‌فرض خودِ فایل اکسپرت خوانده می‌شوند — هیچ فایل "
               "پیش‌تنظیمی لازم نیست؛ پلکان سود هم با همان قوانین ریسک‌فری و تریلینگ شبیه‌سازی شده است")
        for ln in M.wrap_lines(d, sub, self.sh.h2, 1240 * S):
            d.text((W - PAD, self.y), ln, font=self.sh.h2, fill=DIM, anchor="ra")
            self.y += int(25 * S * 1.5)
        self.y += 30 * S

    # ---- A -----------------------------------------------------------------
    def pipeline_box(self, steps, box_h, cw, gap):
        d = self.d
        for i, (t, desc, color) in enumerate(steps):
            r, c = divmod(i, 2)
            bw = width_of(i, steps, cw, gap)
            x1 = PAD + (1 - c) * (cw + gap) if bw == cw else PAD   # right column first: RTL
            yy = self.y + r * (box_h + 16 * S)
            d.rounded_rectangle([x1, yy, x1 + bw, yy + box_h], radius=14 * S, fill=CARD,
                                 outline=(40, 52, 72), width=S)
            d.rounded_rectangle([x1, yy, x1 + 5 * S, yy + box_h], fill=color)
            cx = x1 + 44 * S
            d.ellipse([cx - 17 * S, yy + 19 * S, cx + 17 * S, yy + 53 * S], fill=color)
            d.text((cx, yy + 36 * S), self.fa(M.persian_digits(i + 1)),
                   font=self.sh.f.get("Vazirmatn-Bold.ttf", 20 * S), fill=(18, 22, 30), anchor="mm")
            tx = x1 + bw - 26 * S
            ty = yy + 24 * S
            for ln in M.wrap_lines(d, t, self.sh.h3, bw - 120 * S):
                d.text((tx, ty), ln, font=self.sh.h3, fill=TEXT, anchor="ra")
                ty += int(26 * S * 1.4)
            ty = yy + 24 * S + int(26 * S * 1.4)
            for ln in M.wrap_lines(d, desc, self.sh.small, bw - 120 * S):
                d.text((tx, ty), ln, font=self.sh.small, fill=DIM, anchor="ra")
                ty += int(19 * S * 1.45)
            bw = width_of(i, steps, cw, gap)
            if c == 1 and bw == cw:                             # arrow into the left box
                d.polygon([(x1 - 4 * S, yy + box_h // 2 - 7 * S), (x1 - 4 * S, yy + box_h // 2 + 7 * S),
                           (x1 - 15 * S, yy + box_h // 2)], fill=(96, 112, 138))
            if i + 1 < len(steps) and (i % 2 == 1 or len(steps) - i == 2):
                mx = x1 + bw // 2                               # continue below
                d.polygon([(mx - 8 * S, yy + box_h + 3 * S), (mx + 8 * S, yy + box_h + 3 * S),
                           (mx, yy + box_h + 13 * S)], fill=(96, 112, 138))
        rows = (len(steps) + 1) // 2
        self.y += rows * (box_h + 16 * S) + 18 * S

    # ---- B -----------------------------------------------------------------
    def ladder(self, chart_h, prof, slp, events, cfg):
        d = self.d
        d.rounded_rectangle([PAD, self.y, W - PAD, self.y + chart_h], radius=18 * S, fill=CARD2,
                             outline=(40, 52, 72), width=S)
        px0, px1 = PAD + 34 * S, W - PAD - 210 * S
        legend_h = len(events) * int(19 * S * 1.5) + 40 * S
        py0, py1 = self.y + 78 * S, self.y + chart_h - 54 * S - legend_h
        tp = fnum(cfg, "InpTPPips", 500)
        pmax, pmin = max(max(prof), tp) + 70, -fnum(cfg, "InpSLPips", 300) - 70
        X = lambda i: px0 + (px1 - px0) * i / (len(prof) - 1)
        Y = lambda p: py1 - (py1 - py0) * (p - pmin) / (pmax - pmin)

        d.text((px0, self.y + 28 * S), self.fa("سناریوی نمونه، نه نتیجهٔ بک‌تست"),
               font=self.sh.small, fill=(124, 138, 160), anchor="la")
        d.text((W - PAD - 26 * S, self.y + 28 * S),
               self.fa(f"بازوی ریسک‌فری {pnum(fnum(cfg, 'InpBeTriggerPips', 200))} پیپ · شروع تریلینگ "
                       f"{pnum(fnum(cfg, 'InpTrailStartPips', 250))} · پله {pnum(fnum(cfg, 'InpTrailStepPips', 30))}"),
               font=self.sh.small, fill=DIM, anchor="ra")

        for p in range(int(pmin // 100 * 100), int(pmax) + 1, 100):
            yy = Y(p)
            if not (py0 - 4 * S <= yy <= py1 + 4 * S):
                continue                                      # keep ticks inside the plot
            d.line([px0, yy, px1, yy], fill=(34, 44, 62), width=S)
            d.text((px1 + 14 * S, yy), f"{ENTRY + p * 0.1:.2f}", font=self.sh.mono_s, fill=(146, 160, 182), anchor="lm")
            d.text((W - PAD - 24 * S, yy), self.fa(f"{pnum(p)}p"), font=self.sh.small, fill=(112, 124, 144), anchor="rm")
        def level_line(level, col, lab, above=True):
            yy = Y(level)
            for x in range(int(px0), int(px1), 14 * S):
                d.line([x, yy, x + 8 * S, yy], fill=col, width=2 * S)
            oy = yy - 10 * S if above else yy + 10 * S
            w = int(d.textlength(self.fa(lab), font=self.sh.small))
            d.rectangle([px0 + 6 * S, oy - 8 * S, px0 + 14 * S + w, oy + 26 * S], fill=CARD2)
            d.text((px0 + 10 * S, oy), self.fa(lab), font=self.sh.small, fill=col, anchor="la")

        level_line(0, DIM, "میانگین ورود گروه")
        level_line(tp, RED, f"حد سود گروه، {pnum(tp)} پیپ بالا")
        slv = -fnum(cfg, "InpSLPips", 300)
        yy = Y(slv)
        for x in range(int(px0), int(px1), 14 * S):
            d.line([x, yy, x + 8 * S, yy], fill=(150, 96, 96), width=2 * S)
        lw = int(d.textlength(self.fa(f"حد ضرر اولیه  {pnum(-slv)} پیپ پایین‌تر"), font=self.sh.small))
        d.rectangle([px0 + 6 * S, yy - 32 * S, px0 + 14 * S + lw, yy - 2 * S], fill=CARD2)
        d.text((px0 + 10 * S, yy - 28 * S), self.fa(f"حد ضرر اولیه  {pnum(-slv)} پیپ پایین‌تر"),
               font=self.sh.small, fill=(178, 128, 128), anchor="la")

        for i in range(len(prof)):                               # locked-profit shading
            if slp[i] > slv:
                d.line([X(i), Y(prof[i]), X(i), Y(slp[i])], fill=(34, 66, 50), width=2 * S)
        d.line([(X(i), Y(p)) for i, p in enumerate(slp)], fill=GREEN, width=3 * S, joint="curve")
        d.line([(X(i), Y(p)) for i, p in enumerate(prof)], fill=GOLD, width=3 * S, joint="curve")

        for k, (i, p, lab, col) in enumerate(events):
            x, yv = X(i), Y(p)
            d.line([x, yv, x, py1], fill=(col[0] // 3, col[1] // 3, col[2] // 3), width=S)
            d.ellipse([x - 13 * S, yv - 13 * S, x + 13 * S, yv + 13 * S], fill=col)
            d.text((x, yv), self.fa(M.persian_digits(k + 1)), font=self.sh.f.get("Vazirmatn-Bold.ttf", 17 * S),
                   fill=(18, 22, 30), anchor="mm")
        lx, ly = px0, py1 + 26 * S
        for lab, col in (("مسیر سود سبد (پیپ)", GOLD), ("حد ضرر گروه — فقط جلو می‌رود", GREEN)):
            d.line([lx, ly, lx + 32 * S, ly], fill=col, width=3 * S)
            d.text((lx + 40 * S, ly), self.fa(lab), font=self.sh.small, fill=DIM, anchor="lm")
            lx += int(d.textlength(self.fa(lab), font=self.sh.small)) + 80 * S
        d.text((W - PAD - 26 * S, ly), self.fa("خط‌چینِ هر عدد = همان لحظهٔ تغییر حد ضرر"),
               font=self.sh.small, fill=(124, 138, 160), anchor="rm")
        ly += 34 * S
        for k, (i, p, lab, col) in enumerate(events):      # what each dot means
            d.ellipse([W - PAD - 52 * S, ly - 9 * S, W - PAD - 34 * S, ly + 9 * S], fill=col)
            d.text((W - PAD - 43 * S, ly), self.fa(M.persian_digits(k + 1)),
                   font=self.sh.f.get("Vazirmatn-Bold.ttf", 15 * S), fill=(18, 22, 30), anchor="mm")
            txt = f"{lab} · در سودِ {pnum(p)} پیپ"
            d.text((W - PAD - 70 * S, ly), self.fa(txt), font=self.sh.small, fill=TEXT, anchor="rm")
            ly += int(19 * S * 1.5)
        self.y += chart_h + 34 * S

    # ---- C -----------------------------------------------------------------
    def gauge(self, h, cfg):
        d = self.d
        d.rounded_rectangle([PAD, self.y, W - PAD, self.y + h], radius=18 * S, fill=CARD,
                             outline=(40, 52, 72), width=S)
        bar0, bar1 = PAD + 40 * S, W - PAD - 40 * S
        by = self.y + 76 * S
        top = max([v for v, _, _ in ceilings(cfg)] + [20.0])
        vmax = 20.0 * math.ceil((top + 10.0) / 20.0)          # a little air past the last line
        bh_px, bw_px = int(22 * S), int(bar1 - bar0)                          # risk gradient
        grad = Image.new("RGB", (bw_px, bh_px))
        gd = ImageDraw.Draw(grad)
        for x in range(bw_px):
            t = x / max(1, bw_px - 1)
            gd.line([(x, 0), (x, bh_px)],
                    fill=(int(36 + 158 * t), int(96 - 52 * t), int(64 - 22 * t)))
        mask = Image.new("L", (bw_px, bh_px), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, bw_px - 1, bh_px - 1], radius=bh_px // 2, fill=255)
        self.sh.img.paste(grad, (int(bar0), int(by)), mask)
        d.text((W - PAD - 40 * S, self.y + 30 * S), self.fa("چند درصد از موجودی الان در خطر است؟"),
               font=self.sh.h3, fill=GOLD, anchor="ra")
        for p in range(0, int(vmax) + 1, max(1, int(vmax / 4))):
            x = bar0 + (bar1 - bar0) * p / vmax
            d.line([x, by + 26 * S, x, by + 34 * S], fill=(86, 98, 118), width=S)
            d.text((x, by + 42 * S), self.fa(pnum(p) + "٪"), font=self.sh.small, fill=(122, 134, 154), anchor="ma")
        gy = by + 78 * S
        for val, lab, col in ceilings(cfg):
            x = bar0 + (bar1 - bar0) * min(val, vmax) / vmax
            d.line([x, by - 4 * S, x, by + 26 * S], fill=col, width=2 * S)
            d.ellipse([x - 7 * S, by - 12 * S, x + 7 * S, by + 2 * S], fill=col)
            d.text((bar1, gy), self.fa(f"{pnum(val)}{lab}"), font=self.sh.body, fill=TEXT, anchor="ra")
            d.line([bar0, gy + 24 * S, x, gy + 24 * S], fill=(46, 58, 80), width=S)
            gy += 36 * S
        notes = []
        ml = fnum(cfg, "InpEmergencyMarginLevelPct")
        if ml:
            notes.append(f"margin level زیر {pnum(ml)}٪؛ بستن همه، مستقل از درصد زیان (چون مارجین زودتر از همه می‌شکند)")
        if flag(cfg, "InpEmergencyStepDown"):
            notes.append("اول فقط بدترین تیکت بسته می‌شود؛ اگر مارجین بحرانی بود همه یکجا")
        if flag(cfg, "InpNewsEnabled"):
            act = enum_name(cfg, "ENUM_NEWS_ACTION", "InpNewsAction")
            closes = "CLOSE" in act
            notes.append("گارد اخبار: " + (
                f"{pnum(fnum(cfg, 'InpNewsBeforeMin', 20))} دقیقه قبل از رویداد قرمز، واکنش {act} - بستن دارد"
                if closes else
                f"{pnum(fnum(cfg, 'InpNewsBeforeMin', 20))} دقیقه قبل از رویداد قرمز، واکنش {act} - فقط هشدار، بستن ندارد"))
        div = fnum(cfg, "InpCentDivisor", 100)
        notes.append(f"روی حساب سنتی، اعداد پولی خودکار بر {pnum(div)} تقسیم می‌شوند؛ "
                     "درصدها بدون تغییرند")
        gy += 6 * S
        for n in notes:
            for seg in M.wrap_lines(d, n, self.sh.small, W - 2 * PAD - 80 * S):
                d.text((bar1, gy + 6 * S), seg, font=self.sh.small, fill=DIM, anchor="ra")
                gy += int(19 * S * 1.45)
            gy += 4 * S
        self.y += h + 34 * S

    def footer(self):
        d = self.d
        d.line([PAD, self.y, W - PAD, self.y], fill=(40, 52, 72), width=S)
        self.y += 22 * S
        d.text((W - PAD, self.y), self.fa("این اکسپرت هیچ‌وقت معامله باز نمی‌کند؛ فقط مدیریت می‌کند. "
                                          "با InpDryRun=true هیچ دستوری ارسال نمی‌شود و همه‌چیز در لاگ است."),
               font=self.sh.small, fill=(124, 138, 160), anchor="ra")
        self.y += 30 * S
        d.text((W - PAD, self.y), self.fa("بازسازی این تصویر:"), font=self.sh.small,
               fill=(96, 108, 128), anchor="ra")
        d.text((W - PAD - int(d.textlength(self.fa("بازسازی این تصویر:"), font=self.sh.small)) - 16 * S, self.y),
               "python3 tools/make_flow_sheet.py", font=self.sh.mono_s,
               fill=(110, 124, 146), anchor="rm")
        self.y += 46 * S


def render(cfg: dict, fonts: M.Fonts):
    """One measuring pass on a tall canvas, then draw at the exact height."""
    probe = M.Sheet(fonts, 6000 * S)
    f = Flow(probe, cfg)
    steps = pipeline(cfg)
    prof, slp, events = simulate(cfg)
    gap = 20 * S
    cw = (W - 2 * PAD - gap) // 2
    box_h = 34 * S + 20 * S + 2 * int(26 * S * 1.4) + int(19 * S * 1.45)
    for t, desc, _ in steps:
        extra = max(0, len(M.wrap_lines(probe.d, desc, probe.small, cw - 120 * S)) - 1) * int(19 * S * 1.45)
        tw = max(0, len(M.wrap_lines(probe.d, t, probe.h3, cw - 120 * S)) - 1) * int(26 * S * 1.4)
        box_h = max(box_h, 34 * S + 20 * S + tw + int(26 * S * 1.4) + extra + 26 * S)
    n = (len(steps) + 1) // 2
    total = PAD + 76 * S + int(25 * S * 1.5) * 2 + 30 * S + 52 * S + n * (box_h + 16 * S) + 18 * S
    total += 52 * S + chart_height(cfg) + 34 * S + 52 * S + (210 * S + len(ceilings(cfg)) * 36 * S + 130 * S) + 130 * S
    return box_h, cw, gap, total, steps, (prof, slp, events)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", default="docs/GoldBasketGuard-flow-fa.png")
    ap.add_argument("--font-dir", default=str(M.font_dir_default()))
    a = ap.parse_args()
    cfg = load_config()
    if not cfg:
        print("cannot read the EA file — run this from the repo root", file=sys.stderr)
        return 2
    fonts = M.Fonts(a.font_dir)
    box_h, cw, gap, total, steps, (prof, slp, events) = render(cfg, fonts)

    sh = M.Sheet(fonts, int(total))
    f = Flow(sh, cfg)
    f.header()
    f.section("گام‌به‌گام: از تیک تا ارسال دستور")
    f.pipeline_box(steps, box_h, cw, gap)
    f.section("پلکان قفل‌شدن سود روی طلا")
    f.ladder(chart_height(cfg), prof, slp, events, cfg)
    f.section("سقف‌های محافظت روی حساب")
    f.gauge(210 * S + len(ceilings(cfg)) * 36 * S + 130 * S, cfg)
    f.footer()

    img = sh.img.crop((0, 0, W, min(int(total), f.y)))
    img = img.resize((W // S, img.size[1] // S), Image.LANCZOS)
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, optimize=True)
    print(f"wrote {out}  {img.size[0]}x{img.size[1]}  ({out.stat().st_size // 1024} KB)  "
          f"steps={len(steps)} events={len(events)} config=EA defaults")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
