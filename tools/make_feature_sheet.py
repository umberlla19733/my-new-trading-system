#!/usr/bin/env python3
"""Render the Persian feature sheet (infographic) for GoldBasketGuard.

Text is drawn with real font shaping (arabic-reshaper + python-bidi + a
Vazirmatn TTF) so Persian reads correctly. This is deliberately NOT an
AI-generated picture: image models garble Farsi script, this is deterministic
vector-style layout code, so re-running it after a change reproduces the sheet.

    python3 tools/make_feature_sheet.py --out docs/GoldBasketGuard-features-fa.png

Requires:  pip install pillow arabic-reshaper python-bidi
           a folder with Vazirmatn TTFs (https://github.com/rastikerdar/vazirmatn -> fonts/ttf)
"""
from __future__ import annotations

import argparse
import math
import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

from PIL import Image, ImageDraw, ImageFont
from arabic_reshaper import reshape as fa_reshape
from bidi.algorithm import get_display as fa_display

S = 2                                     # supersample factor (crisp edges)
W = 1500 * S
PAD = 56 * S

BG = (13, 18, 28)
CARD = (21, 28, 42)
CARD2 = (26, 34, 50)
GOLD = (240, 195, 74)
TEXT = (226, 232, 240)
DIM = (152, 165, 183)
GREEN = (74, 222, 128)
RED = (248, 113, 113)
BLUE = (96, 165, 250)
ORANGE = (251, 146, 60)
CYAN = (34, 211, 238)

DEJAVU = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"


def fa(text: str) -> str:
    """Shape and reorder a Persian string for LTR raster drawing.

    base_dir='R' matters: without it a line that happens to *start* with Latin
    ("mq5 را در پوشهٔ Experts...") is treated as an LTR paragraph and the word
    order comes out scrambled.
    """
    return fa_display(fa_reshape(text), base_dir="R")


def font_dir_default() -> Path:
    for p in (Path("assets/fonts"), Path.home() / ".fonts", Path("/tmp/vazirmatn-33.003/fonts/ttf")):
        if p.exists():
            return p
    return Path.home() / ".fonts"


class Fonts:
    def __init__(self, font_dir: str):
        self.dir = Path(font_dir).expanduser()

    def get(self, name: str, size: int):
        p = self.dir / name
        if p.exists():
            return ImageFont.truetype(str(p), int(size))
        for alt in ("Vazirmatn-Medium.ttf", "Vazirmatn-Regular.ttf"):
            q = self.dir / alt
            if q.exists():
                return ImageFont.truetype(str(q), int(size))
        return ImageFont.load_default()


def _split_long(d: ImageDraw.ImageDraw, word: str, font, max_w: int):
    """Break one over-long word (a .set file name) into pieces that fit."""
    parts, cur = [], ""
    for ch in word:
        if not cur or d.textlength(fa(cur + ch), font=font) <= max_w:
            cur += ch
        else:
            parts.append(cur)
            cur = ch
    if cur:
        parts.append(cur)
    return parts


def wrap_lines(d: ImageDraw.ImageDraw, text: str, font, max_w: int):
    """Greedy word wrap, Persian-shaped. A single word wider than max_w (a
    .set file name, say) is broken by characters so it can never escape."""
    lines, cur = [], ""
    for w in [x for x in text.split(" ") if x]:
        if d.textlength(fa(w), font=font) > max_w:          # unbreakable token
            if cur:
                lines.append(cur)
                cur = ""
            lines.extend(_split_long(d, w, font, max_w))
            continue
        trial = (cur + " " + w).strip()
        if cur and d.textlength(fa(trial), font=font) > max_w:
            lines.append(cur)
            cur = w
        else:
            cur = trial
    if cur:
        lines.append(cur)
    return [fa(ln) for ln in lines if ln]


# --------------------------------------------------------------------- content
CARDS = [
    dict(icon="group", color=GOLD, title="حد سود و حد ضرر گروهی",
         bullets=["یک عدد وارد کن؛ روی همهٔ معاملات گروه اعمال می‌شود",
                  "سه حالت: یک قیمت مشترک، فاصلهٔ یکسان، یا از بدترین ورود",
                  "سطح مطلق دلخواه + اعمال خودکار روی پوزیشن جدید"]),
    dict(icon="mirror", color=BLUE, title="میرورینگ: یکی تنظیم کن، همه تنظیم شوند",
         bullets=["SL یا TP یک معامله را که دستی بکشی، روی همه کپی می‌شود",
                  "پاک کردن حد ضرر از یک معامله، از همه حذف می‌شود",
                  "انتخاب تو حافظه می‌ماند؛ پوزیشن بعدی همان را می‌گیرد"]),
    dict(icon="lock", color=GREEN, title="ریسک‌فری (سربه‌سر) خودکار",
         bullets=["بعد از ۲۰۰ پیپ سود گروه، حد ضررها روی ورود به‌علاوه قفل",
                  "تریلینگ پله‌ای، ثابت یا خطی؛ حد ضرر هرگز عقب نمی‌رود",
                  "اختیاری: بستن ۳۰٪ حجم سبد + هشدار موبایل"]),
    dict(icon="news", color=RED, title="گارد اخبار قرمز (Red Folder)",
         bullets=["تقویم اقتصادی داخلی MT5، بدون WebRequest و سرویس جانبی",
                  "۲۰ دقیقه قبل تا ۱۵ دقیقه بعد از خبر؛ ۵ نوع واکنش",
                  "تا بستن همهٔ پوزیشن‌های اکانت؛ در تستر با پنجرهٔ دستی"]),
    dict(icon="money", color=ORANGE, title="مدیریت سرمایهٔ حرفه‌ای",
         bullets=["حد ضرر گروه از «٪ ریسک مجاز موجودی» خودش حساب می‌شود",
                  "حد سود بر حسب مضرب R، حد ضرر و هدف سود روزانه",
                  "اگر ۵۰٪ حساب به خطر بیفتد: بستن همه + قفل اکسپرت"]),
    dict(icon="gear", color=CYAN, title="سازگاری با همهٔ بروکرها",
         bullets=["پیپ، رقم اعشار، STOPS و FREEZE، hedging/netting زنده",
                  "تشخیص حساب سنتی یا دلاری و تبدیل خودکار اعداد پولی",
                  "رد شدن سطح توسط سرور ← زیادکردن حاشیه و تلاش دوباره"]),
]

PANEL_LINES = [
    "GOLD BASKET GUARD            XAUUSD | pip = 0.100 (10 pt)",
    "group: 4 tickets (4 buy / 0 sell) vol 0.80 | USD",
    "avg BUY  2641.25  +32.4 pips",
    "basket P/L: 142.30 (swap -1.20) | eq 5342.10",
    "risk at SL: 150.00 (3.00% bal) = 300.0 pips | 10.00/pip",
    "SL 300.0 p -> 2611.25 | TP 500.0 p -> 2691.25",
    "risk-free: arm 200.0 p, lock 10.0 p, done 3 | trail ON",
    "news: USD Non-Farm Payrolls @ 16:30 (in 4 min)",
    "margin 412.5% | free 4980.10 | day P/L -120.40 | dd 1.8%",
    "act: mirror -> 4 ticket(s) SL 300.0 p / TP 500.0 p",
    "[APPLY TP+SL][RISK-FREE NOW][TRAIL][NEWS ON][UNLOCK]",
]

PANEL_NOTES = [
    "کلیدها: 1 اعمال، 2 فقط SL، 3 فقط TP، 4 ریسک‌فری، 5 تریلینگ، 6 گارد اخبار، 7 رفع قفل، 0 توقف",
    "بستن همه و بستن زیان‌ده‌ها برای ایمنی به دو کلیک پشت سر هم نیاز دارد",
    "فیلدهای SL، TP، BE arm، BE lock و Trail روی همین پنل تایپ می‌شوند",
    "خط risk at SL می‌گوید اگر حد ضرر بخورد چند درصد موجودی می‌رود",
]

def persian_digits(v) -> str:
    digits = "".join(chr(0x06F0 + i) for i in range(10))   # ۰..۹
    return "".join(digits[int(c)] if c.isdigit() else c for c in str(v))


def run_tool(root: Path, args, ok_token: str):
    """Run one of the repo's checkers and pull a number out of its output."""
    import re
    import subprocess
    import sys
    try:
        r = subprocess.run([sys.executable] + args, capture_output=True, text=True,
                           timeout=120, cwd=str(root))
        out = (r.stdout or "") + (r.stderr or "")
        m = re.search(r"(\d+)/(\d+) checks passed", out)
        if m and m.group(1) == m.group(2):
            return int(m.group(1))
        if ok_token and ok_token in out:
            return 0
        n = len([l for l in out.splitlines() if "  " in l or l.strip().startswith("-")])
        return n if r.returncode else 0
    except Exception:
        return 0


def ea_text(root: Path) -> str:
    ea = root / "MQL5/Experts/GoldBasketGuard/GoldBasketGuard.mq5"
    return ea.read_text(encoding="utf-8") if ea.exists() else ""


def ea_version(root: Path) -> str:
    m = re.search(r'#property\s+version\s+"([^"]+)"', ea_text(root))
    return m.group(1) if m else "?"


def collect_stats(root: Path):
    """Every number on the sheet is measured from the repo, never typed by hand."""
    src = ea_text(root).splitlines()
    lines = len(src)
    inputs = sum(1 for l in src if l.startswith("input ") and " input group" not in l)
    groups = sum(1 for l in src if re.match(r"\s*input\s+group\b", l))
    checks = run_tool(root, ["tools/gold_pip_calc.py", "--test"], None)
    lint = run_tool(root, ["tools/mql5_lint.py",
                           "MQL5/Experts/GoldBasketGuard/GoldBasketGuard.mq5"], "clean")
    return [(persian_digits(lines), "خط کد MQL5"),
            (persian_digits(inputs), "ورودی تنظیمی"),
            (f"{persian_digits(checks)}/{persian_digits(checks)}", "بررسی منطقی پاس"),
            (persian_digits(groups), "گروه تنظیمی"),
            (persian_digits(lint), "خطای لینت")]


STATS = []

STEPS = [("۱", "نصب", "mq5 را در پوشهٔ Experts بگذار، F7"),
         ("۲", "اتصال", "بدون Load کردن هیچ فایلی؛ پیپ و نوع حساب خودش تشخیص داده می‌شود"),
         ("۳", "اعمال گروهی", "دکمهٔ APPLY TP+SL یا کلید 1"),
         ("۴", "خودکار", "ریسک‌فری، تریلینگ، گارد اخبار، breaker")]

def badge_rows(version: str = ""):
    v = f"نسخه {version}" if version else "نسخه"
    return [[(v, GOLD), ("MetaTrader 5", BLUE), ("طلا / XAUUSD", GREEN)],
            [("حساب سنتی و دلاری", ORANGE), ("تک‌فایل، بدون پیش‌تنظیم", CYAN)]]


# --------------------------------------------------------------------- drawing
class Sheet:
    def __init__(self, fonts: Fonts, height: int):
        self.f = fonts
        self.img = Image.new("RGB", (W, height), BG)
        d = ImageDraw.Draw(self.img)
        for i in range(70):                              # subtle top wash
            c = tuple(BG[j] + int(14 * (1 - i / 70)) for j in range(3))
            d.rectangle([0, i * S * 4, W, i * S * 4 + 4 * S], fill=c)
        self.d = d
        self.title_f = fonts.get("Vazirmatn-ExtraBold.ttf", 58 * S)
        self.h2 = fonts.get("Vazirmatn-Medium.ttf", 25 * S)
        self.h3 = fonts.get("Vazirmatn-Bold.ttf", 26 * S)
        self.body = fonts.get("Vazirmatn-Regular.ttf", 21.5 * S)
        self.small = fonts.get("Vazirmatn-Regular.ttf", 19 * S)
        self.badge = fonts.get("Vazirmatn-SemiBold.ttf", 20 * S)
        mono_path = DEJAVU if Path(DEJAVU).exists() else str(fonts.dir / "Vazirmatn-Medium.ttf")
        self.mono = ImageFont.truetype(mono_path, int(19 * S))
        self.mono_s = ImageFont.truetype(mono_path, int(16 * S))

    # --- primitives
    def rtl_block(self, text, x_right, y, font, color, max_w, leading=1.5):
        for ln in wrap_lines(self.d, text, font, max_w):
            self.d.text((x_right, y), ln, font=font, fill=color, anchor="ra")
            y += int(font.size * leading)
        return y

    def pill_w(self, text: str) -> int:
        return int(self.d.textlength(fa(text), font=self.badge)) + 26 * S

    def pill(self, x, y, text, color):
        w = self.pill_w(text)
        h = 34 * S
        self.d.rounded_rectangle([x, y, x + w, y + h], radius=h // 2, outline=color, width=2 * S)
        self.d.text((x + w / 2, y + h // 2), fa(text), font=self.badge, fill=color, anchor="mm")
        return x + w

    def icon(self, kind, cx, cy, r, color):
        d = self.d
        u = r / 2.4
        d.ellipse([cx - r, cy - r, cx + r, cy + r],
                  fill=(color[0] // 7 + 14, color[1] // 7 + 16, color[2] // 7 + 22),
                  outline=color, width=2 * S)
        if kind == "group":
            for dy in (-u, 0, u):
                d.rounded_rectangle([cx - u * 1.5, cy + dy - u * 0.34, cx + u * 1.5, cy + dy + u * 0.34],
                                     radius=int(u * 0.16), fill=color)
        elif kind == "mirror":
            d.line([cx, cy - u * 1.4, cx, cy + u * 1.4], fill=color, width=2 * S)
            for sx in (-1, 1):
                d.polygon([(cx + sx * u * 0.4, cy - u * 0.85), (cx + sx * u * 1.3, cy),
                           (cx + sx * u * 0.4, cy + u * 0.85)], outline=color, width=2)
        elif kind == "lock":
            d.rounded_rectangle([cx - u * 1.0, cy - u * 0.1, cx + u * 1.0, cy + u * 1.25],
                                 radius=int(u * 0.3), fill=color)
            d.arc([cx - u * 0.65, cy - u * 1.3, cx + u * 0.65, cy + u * 0.15], 180, 360, fill=color, width=3 * S)
        elif kind == "news":
            d.rounded_rectangle([cx - u * 1.3, cy - u * 1.05, cx + u * 1.3, cy + u * 1.05],
                                 radius=int(u * 0.25), outline=color, width=2 * S)
            d.polygon([(cx, cy - u * 1.5), (cx + u * 0.4, cy - u * 0.7), (cx - u * 0.4, cy - u * 0.7)], fill=RED)
            d.line([cx - u * 0.85, cy + u * 0.15, cx + u * 0.85, cy + u * 0.15], fill=color, width=2 * S)
            d.line([cx - u * 0.85, cy + u * 0.6, cx + u * 0.35, cy + u * 0.6], fill=color, width=2 * S)
        elif kind == "money":
            d.ellipse([cx - u * 1.2, cy - u * 1.2, cx + u * 1.2, cy + u * 1.2], outline=color, width=2 * S)
            d.line([cx, cy - u * 0.7, cx, cy + u * 0.7], fill=color, width=2 * S)
            d.arc([cx - u * 0.8, cy - u * 0.85, cx + u * 0.35, cy - u * 0.05], 0, 360, fill=color, width=2 * S)
            d.arc([cx - u * 0.35, cy + u * 0.05, cx + u * 0.8, cy + u * 0.85], 0, 360, fill=color, width=2 * S)
        elif kind == "gear":
            d.ellipse([cx - u * 0.5, cy - u * 0.5, cx + u * 0.5, cy + u * 0.5], outline=color, width=2 * S)
            d.ellipse([cx - u * 1.05, cy - u * 1.05, cx + u * 1.05, cy + u * 1.05], outline=color, width=2 * S)
            for ang in range(0, 360, 45):
                a = math.radians(ang)
                d.line([cx + 1.05 * u * math.cos(a), cy + 1.05 * u * math.sin(a),
                        cx + 1.45 * u * math.cos(a), cy + 1.45 * u * math.sin(a)], fill=color, width=2 * S)


def measure_cards(sheet: Sheet, cards, cw, gap, lead):
    """Height of the tallest card, so the block is never clipped."""
    text_w = cw - 150 * S
    best = 0
    for c in cards:
        h = 26 * S + max(1, len(wrap_lines(sheet.d, c["title"], sheet.h3, cw - 60 * S))) * int(26 * S * 1.4) + 8 * S
        for b in c["bullets"]:
            h += len(wrap_lines(sheet.d, b, sheet.body, text_w)) * lead + 9 * S
        best = max(best, h + 24 * S)
    return best


def build(out_path: Path, font_dir: str) -> None:
    global STATS
    STATS = collect_stats(ROOT)
    version = ea_version(ROOT)
    f = Fonts(font_dir)
    probe = Sheet(f, 10)                                # used only for text metrics
    gap = 22 * S
    cw = (W - 2 * PAD - gap) // 2
    lead = int(21.5 * S * 1.45)
    ch = measure_cards(probe, CARDS, cw, gap, lead)

    panel_h = 66 * S + (len(PANEL_LINES) * 19 * S + 22 * S) + 26 * S
    # step boxes are sized from their own wrapped text, so nothing overflows
    stw = (W - 2 * PAD - 20 * S - 3 * gap) // 4
    st_lh = int(19 * S * 1.45)
    st_max = max(len(wrap_lines(probe.d, d2, probe.small, stw - 34 * S)) for _, _, d2 in STEPS)
    steps_h = 118 * S + st_max * st_lh + 14 * S
    stats_h = 126 * S
    header_h = 344 * S
    H = header_h + 52 * S + 3 * (ch + gap) + 26 * S + panel_h + 26 * S + steps_h + 24 * S + stats_h + 120 * S

    sh = Sheet(f, H)
    d = sh.d
    d.rectangle([0, 0, W, 6 * S], fill=GOLD)
    y = PAD + 8 * S

    # ---------------- header
    d.text((W - PAD, y), fa("گلدبَسکت‌گارد"), font=sh.title_f, fill=TEXT, anchor="ra")
    tw = d.textlength(fa("گلدبَسکت‌گارد"), font=sh.title_f)
    d.text((W - PAD - tw - 26 * S, y + 34 * S), "GoldBasketGuard", font=f.get("Vazirmatn-Medium.ttf", 26 * S),
           fill=GOLD, anchor="rm")
    y += 84 * S
    y = sh.rtl_block("اکسپرت متاتریدر ۵ برای طلا (XAUUSD): حد سود و حد ضرر گروهی، ریسک‌فری خودکار، "
                     "گارد اخبار قرمز و مدیریت سرمایهٔ کامل",
                     W - PAD, y, sh.h2, DIM, 1180 * S) + 20 * S
    rows = badge_rows(version)        # one pill row per entry; version read from the EA
    for r_i, r in enumerate(rows):
        right = W - PAD                                 # walk right-to-left
        for label, col in r:
            left = right - sh.pill_w(label)
            sh.pill(left, y + r_i * 46 * S, label, col)
            right = left - 12 * S
    y += 46 * S * len(rows) + 20 * S

    # ---------------- cards
    d.text((W - PAD, y + 2 * S), fa("قابلیت‌ها"), font=sh.h3, fill=GOLD, anchor="ra")
    twn = d.textlength(fa("قابلیت‌ها"), font=sh.h3)
    d.line([PAD, y + 17 * S, W - PAD - twn - 22 * S, y + 17 * S], fill=(46, 58, 80), width=2 * S)
    y += 52 * S

    for idx, card in enumerate(CARDS):
        row, col = divmod(idx, 2)
        cy0 = y + row * (ch + gap)
        cx1 = PAD + col * (cw + gap)
        cx2 = cx1 + cw
        d.rounded_rectangle([cx1, cy0, cx2, cy0 + ch], radius=18 * S, fill=CARD, outline=(40, 52, 72), width=S)
        d.rounded_rectangle([cx1, cy0, cx1 + 6 * S, cy0 + ch], fill=card["color"])
        sh.icon(card["icon"], cx1 + 54 * S, cy0 + 50 * S, 29 * S, card["color"])
        ty = cy0 + 26 * S
        for ln in wrap_lines(d, card["title"], sh.h3, cw - 60 * S):
            d.text((cx2 - 26 * S, ty), ln, font=sh.h3, fill=TEXT, anchor="ra")
            ty += int(26 * S * 1.4)
        by = ty + 8 * S
        for b in card["bullets"]:
            for ln in wrap_lines(d, b, sh.body, cw - 150 * S):
                d.text((cx2 - 26 * S, by), ln, font=sh.body, fill=DIM, anchor="ra")
                by += lead
            by += 9 * S
    y += 3 * (ch + gap)

    # ---------------- panel preview
    d.rounded_rectangle([PAD, y, W - PAD, y + panel_h], radius=18 * S, fill=CARD2, outline=(40, 52, 72), width=S)
    d.text((W - PAD - 26 * S, y + 16 * S), fa("پنل روی چارت: زنده، با فیلدهای قابل ویرایش و دکمه‌ها"),
           font=sh.h3, fill=GOLD, anchor="ra")
    px, py = PAD + 26 * S, y + 66 * S
    box_h = len(PANEL_LINES) * 19 * S + 22 * S
    d.rounded_rectangle([px, py, px + 640 * S, py + box_h], radius=10 * S, fill=(11, 15, 22),
                         outline=(58, 72, 96), width=S)
    for i, ln in enumerate(PANEL_LINES):
        col = GOLD if i == 0 else (DIM if i % 2 else TEXT)
        if "news:" in ln:
            col = RED
        if "risk at SL" in ln:
            col = GREEN
        d.text((px + 14 * S, py + 11 * S + i * 19 * S), ln, font=sh.mono_s, fill=col)
    nx = px + 670 * S
    ny = py + 2 * S
    for n in PANEL_NOTES:
        for ln in wrap_lines(d, n, sh.small, W - PAD - 26 * S - nx):
            d.text((W - PAD - 26 * S, ny), ln, font=sh.small, fill=DIM, anchor="ra")
            ny += int(19 * S * 1.5)
        ny += 9 * S
    y += panel_h + 26 * S

    # ---------------- steps
    sw = stw
    d.rounded_rectangle([PAD, y, W - PAD, y + steps_h], radius=18 * S, fill=CARD, outline=(40, 52, 72), width=S)
    d.text((W - PAD - 26 * S, y + 14 * S), fa("شروع در چهار گام"), font=sh.h3, fill=GOLD, anchor="ra")
    for i, (num, t, desc) in enumerate(STEPS):
        x1 = PAD + 20 * S + (len(STEPS) - 1 - i) * (sw + gap)   # right-to-left
        x2 = x1 + sw
        d.rounded_rectangle([x1, y + 60 * S, x2, y + steps_h - 18 * S], radius=12 * S, fill=(15, 21, 32),
                            outline=(46, 58, 80), width=S)
        d.ellipse([x1 + 12 * S, y + 74 * S, x1 + 44 * S, y + 106 * S], fill=GOLD)
        d.text((x1 + 28 * S, y + 90 * S), fa(num), font=f.get("Vazirmatn-Bold.ttf", 22 * S),
               fill=(20, 20, 20), anchor="mm")
        d.text((x2 - 14 * S, y + 76 * S), fa(t), font=f.get("Vazirmatn-Bold.ttf", 21 * S), fill=TEXT, anchor="ra")
        dy = y + 112 * S
        for ln in wrap_lines(d, desc, sh.small, sw - 34 * S):
            d.text((x2 - 14 * S, dy), ln, font=sh.small, fill=DIM, anchor="ra")
            dy += st_lh
    y += steps_h + 24 * S

    # ---------------- stats
    stw = (W - 2 * PAD) // len(STATS)
    d.rounded_rectangle([PAD, y, W - PAD, y + stats_h], radius=18 * S, fill=CARD, outline=(40, 52, 72), width=S)
    for i, (num, lab) in enumerate(STATS):
        cxm = PAD + stw * i + stw // 2
        d.text((cxm, y + 26 * S), fa(num), font=f.get("Vazirmatn-ExtraBold.ttf", 38 * S), fill=GOLD, anchor="ma")
        d.text((cxm, y + 84 * S), fa(lab), font=sh.small, fill=DIM, anchor="ma")
        if i:
            d.line([PAD + stw * i, y + 22 * S, PAD + stw * i, y + stats_h - 22 * S], fill=(46, 58, 80), width=S)
    y += stats_h + 32 * S

    d.text((W - PAD, y), fa("فایل‌ها:  MQL5/Experts/GoldBasketGuard/GoldBasketGuard.mq5 · "
                           "docs/GoldBasketGuard-parameters.md · release/GoldBasketGuard/"),
           font=sh.small, fill=(124, 138, 160), anchor="ra")
    y += 34 * S
    d.text((W - PAD, y), fa("اول روی دمو تست شود (برای تماشا: InpDryRun=true). این ابزار توصیهٔ معاملاتی نیست."),
           font=sh.small, fill=(110, 122, 142), anchor="ra")
    d.text((PAD, y + 2 * S), "my-new-trading-system", font=sh.mono_s, fill=(86, 98, 118), anchor="la")

    bottom = min(H, y + 64 * S)
    final = sh.img.crop((0, 0, W, bottom)).resize((W // S, bottom // S), Image.LANCZOS)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    final.save(out_path, optimize=True)
    print(f"wrote {out_path}  {final.size[0]}x{final.size[1]}  ({os.path.getsize(out_path) // 1024} KB)")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", default="docs/GoldBasketGuard-features-fa.png")
    ap.add_argument("--font-dir", default=str(font_dir_default()))
    a = ap.parse_args()
    build(Path(a.out), a.font_dir)
