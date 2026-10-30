# GoldBasketGuard v1.17 — release folder

این پوشه نسخهٔ نهایی و بررسی‌شدهٔ اکسپرت است. **هیچ فایل پیش‌تنظیمی لازم نیست**:
همه‌چیز در خود فایل ساخته شده و مقداردهیِ پیش‌فرض برای طلا تنظیم شده است.

## contents

| file | what it is |
|---|---|
| `GoldBasketGuard.mq5` | the EA — 3327 lines, 108 inputs, 10 input groups |
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

### سرعت واکنش (v1.17)

- حلقهٔ مدیریت هر `InpTimerMs=100` میلی‌ثانیه اجرا می‌شود (۱۰ چرخه در ثانیه)، نه هر ۱ ثانیه
- `InpInstantMirror=true`: کشیدن SL/TP روی یک معامله **داخل همان رویداد معامله** به بقیهٔ گروه
  منتقل می‌شود؛ لازم نیست چرخهٔ بعدی صبر کند، و بازار ساکت هم سرعت را کم نمی‌کند
- «تغییر دستی» با مقایسهٔ عدد تشخیص داده می‌شود، نه با یک پنجرهٔ چندثانیه‌ای: اکسپرت فقط
  همان سطحی را که **خودش درخواست کرده** نادیده می‌گیرد، پس تغییر دستی شما گم نمی‌شود
- `InpMaxModsPerSecond=25` و `InpMinMsPerTicket=0`: یک سبد کامل در یک چرخه صاف می‌شود
- خط آخر پنل مدت واقعی هر چرخه را نشان می‌دهد: `cycle 1 ms (max 9 ms)`

### سیاست بستن (پیش‌فرض از نسخهٔ 1.17)

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

- EA file present — MQL5/Experts/GoldBasketGuard/GoldBasketGuard.mq5
- pure ASCII (MetaEditor safe) — 0 non-ASCII bytes
- no tab characters
- no CRLF line endings
- no TODO / FIXME / XXX left
- version property — found 1.17, expected 1.17
- braces balanced — 311 open / 311 close
- parens balanced — 1755 open / 1755 close
- input names unique
- input count sane — 108 inputs
- static lint clean —    clean: blocks balanced, no obvious syntax/API problems
- logic mirror tests — 138/138 checks passed
- zero-config contract (43 defaults) — attach with no changes = gold setup, all guards armed
- the panel carries four buttons and no more — APPLY PAUSE UNLOCK CLOSEALL
- two numbers on the panel, no more — 2 editable fields
- the panel is one small card — 8 lines
- no page of toggles came back — the Inputs decide what runs; the chart only reports and overrides
- automation is on by default — levels are glued from the first cycle, so APPLY is only an emergency override
- every click runs a cycle at once — the panel shows the result of the click, not of the next tick
- only the destructive click asks twice — CLOSE ALL arms on the ms clock: TimeCurrent() stands still when the market does
- each armed action has its own timer — 2 arm timers
- closing is still one call, no loop of sleeps — one attempt per cycle per ticket
- dry run goes through one gate — only DryOn() and the input itself read InpDryRun
- cycle cost budget (a cycle with a group on it) — RunCycle() with 5 ticket(s): 149 terminal calls on the quiet path [15 object writes, 1 redraws, 7 position reads]
- cycle cost budget (an idle cycle) — RunCycle() with 0 ticket(s): 74 terminal calls on the quiet path [15 object writes, 1 redraws, 2 position reads]
- panel paints only what changed — a quiet chart must not touch a single chart object
- panel rows are cached in front of the chart — RowSet() compares before it calls OLabel()
- an order clears the account snapshot — 4 invalidations: guards never decide on stale equity
- terminal flags are read once — InTester() must not be an accessor per guard
- idle loop backs off — one hertz while the chart holds nothing
- no sleeping inside a live cycle — 1 Sleep site(s): Sleep(50);
- a refused modify is remembered — cool-down + fuse in front of the retry
- the cool-down is consulted before sending — the same rejected level cannot be pushed every 100 ms
- closes are never delayed or fused — an unwanted position is more dangerous than a slow retry
- an emergency lock expires by itself — InpEmergencyLockHours is a duration, not a life sentence
- a pause is not carried into the next session — a stray keypress must not disable the EA after a restart
- a lost timer is re-armed — the watchdog in RunCycle() plus OnInit
- no preset files to load — removed on purpose

Rebuild this folder any time with:

```
python3 tools/make_release.py
```
