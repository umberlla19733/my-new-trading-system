# GoldBasketGuard v1.10 — release folder

این پوشه نسخهٔ نهایی و بررسی‌شدهٔ اکسپرت است. فایل اصلی برای MetaEditor همان
`GoldBasketGuard.mq5` است (تک‌فایل، بدون `#include` اختصاصی).

## contents

| file | what it is |
|---|---|
| `GoldBasketGuard.mq5` | the EA (2524 lines, 101 inputs) |
| `presets/*.set` | 4 ready-made profiles for gold |
| `GoldBasketGuard-parameters.md` | every parameter, Persian reference |
| `GoldBasketGuard-features-fa.png` | one-image feature sheet (Persian) |
| `GoldBasketGuard-flow-fa.png` | how the risk engine behaves, tick by tick |
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

- EA file present — MQL5/Experts/GoldBasketGuard/GoldBasketGuard.mq5
- pure ASCII (MetaEditor safe) — 0 non-ASCII bytes
- no tab characters
- no CRLF line endings
- no TODO / FIXME / XXX left
- version property — found 1.10, expected 1.10
- braces balanced — 242 open / 242 close
- parens balanced — 1380 open / 1380 close
- input names unique
- input count sane — 101 inputs
- static lint clean —    clean: blocks balanced, no obvious syntax/API problems
- logic mirror tests — 60/60 checks passed
- presets valid (4 files)

Rebuild this folder any time with:

```
python3 tools/make_release.py --version 1.10
```
