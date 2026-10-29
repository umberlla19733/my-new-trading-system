# GoldBasketGuard v1.11 — release folder

این پوشه نسخهٔ نهایی و بررسی‌شدهٔ اکسپرت است. **هیچ فایل پیش‌تنظیمی لازم نیست**:
همه‌چیز در خود فایل ساخته شده و مقداردهیِ پیش‌فرض برای طلا تنظیم شده است.

## contents

| file | what it is |
|---|---|
| `GoldBasketGuard.mq5` | the EA — 2526 lines, 101 inputs, 10 input groups |
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

قصد معاملاتی (فاصلهٔ حد ضرر/حد سود، آستانهٔ ریسک‌فری، «کدام معاملات گروه من است»)
تشخیص‌دادنی نیست؛ همان‌ها در پنل روی چارت یا تب Inputs تایپ می‌شوند.

> این اکسپرت معامله باز نمی‌کند؛ فقط مدیریت حد سود/حد ضرر، ریسک‌فری، گارد اخبار
> و مدیریت سرمایهٔ گروهی را انجام می‌دهد. اول روی حساب دمو تست شود.

## verified by `tools/make_release.py`

- EA file present — MQL5/Experts/GoldBasketGuard/GoldBasketGuard.mq5
- pure ASCII (MetaEditor safe) — 0 non-ASCII bytes
- no tab characters
- no CRLF line endings
- no TODO / FIXME / XXX left
- version property — found 1.11, expected 1.11
- braces balanced — 242 open / 242 close
- parens balanced — 1380 open / 1380 close
- input names unique
- input count sane — 101 inputs
- static lint clean —    clean: blocks balanced, no obvious syntax/API problems
- logic mirror tests — 60/60 checks passed
- zero-config contract (30 defaults) — attach with no changes = gold setup, all guards armed
- no preset files to load — removed on purpose

Rebuild this folder any time with:

```
python3 tools/make_release.py
```
