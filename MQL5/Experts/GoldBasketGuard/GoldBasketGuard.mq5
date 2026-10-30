//+------------------------------------------------------------------+
//|                                              GoldBasketGuard.mq5 |
//|   Group (basket) TP/SL manager + automatic risk-free engine     |
//|   Target instrument: XAUUSD (Gold) on MetaTrader 5              |
//+------------------------------------------------------------------+
#property copyright   "my-new-trading-system"
#property link        "https://github.com/umberlla19733/my-new-trading-system"
#property version   "1.17"
#property description "Group (basket) stop-loss / take-profit manager with automatic risk-free for MT5"
#property description "Gold / XAUUSD: set TP-SL on ONE ticket, the whole group is aligned to it"
#property description "News guard (red-folder), risk-percent sizing, cent/dollar auto-detect; closes all at 60% account risk"
#property description "Zero-config: pip size, stops/freeze levels, hedging/netting and account currency are detected"
#property description "at start, so no preset file is needed. Sub-second reaction: 100 ms loop + trade-event driven mirroring."
#property description "v1.14: 12 on/off switches on the chart panel (keys 1-9, 0, -, =), remembered per account+symbol."
#property description "v1.15: lighter on the terminal - one account snapshot per cycle, the panel paints only"
#property description "what changed, and a chart with no positions ticks at 1 Hz instead of 10 Hz."
#property description "v1.16: stays alive - refused requests are held back instead of repeated, a run of"
#property description "refusals pauses automatic sending on its own, an emergency lock now expires by itself,"
#property description "a lost timer is re-armed, and PAUSE is no longer remembered across restarts."
#property description "v1.17: no switch page and no extra buttons - the Inputs decide, the panel reports on"
#property description "eight lines with four buttons and two numbers; levels are kept glued every cycle,"
#property description "so nothing has to be pressed, and the confirm window runs on the ms clock."
#property description "Not investment advice."

#include <Trade\Trade.mqh>

//--- enums ---------------------------------------------------------
enum ENUM_APPLY_MODE
  {
   APPLY_PER_TICKET   = 0,   // each ticket: same distance from own entry
   APPLY_SAME_LEVEL   = 1,   // all tickets: exact same price level
   APPLY_FROM_WORST   = 2    // distance from worst entry of the group
  };

enum ENUM_BE_MODE
  {
   BE_OFF             = 0,   // risk-free disabled
   BE_TICKET_PIPS     = 1,   // per ticket, after N pips in profit
   BE_BASKET_PIPS     = 2,   // group avg price moved N pips in profit
   BE_BASKET_MONEY    = 3,   // group profit >= fixed money
   BE_BASKET_PCT_EQ   = 4    // group profit >= % of equity
  };

enum ENUM_BE_LEVEL
  {
   BELVL_OWN_ENTRY    = 0,   // SL -> own entry + offset
   BELVL_GROUP_AVG    = 1,   // SL -> weighted avg entry of group + offset
  };

enum ENUM_TRAIL_MODE
  {
   TRAIL_OFF          = 0,   // no trailing
   TRAIL_STEP         = 1,   // lock profit in fixed pips steps
   TRAIL_FIXED        = 2,   // fixed distance behind price
   TRAIL_LINEAR       = 3    // distance shrinks with profit
  };

enum ENUM_NEWS_ACTION
  {
   NEWS_WARN          = 0,   // warn only
   NEWS_RISK_FREE     = 1,   // move everything to risk-free
   NEWS_CLOSE_LOSING  = 2,   // close losing tickets of the group
   NEWS_CLOSE_GROUP   = 3,   // close the whole group
   NEWS_CLOSE_ACCOUNT = 4    // close every position on the account
  };

enum ENUM_MONEY_BASIS
  {
   MONEY_AUTO         = 0,   // auto: cent account -> inputs are real USD
   MONEY_ACCOUNT_CCY  = 1,   // inputs are in account currency units (cents on cent accts)
   MONEY_REAL_USD     = 2    // inputs are always real USD/EUR of the account currency
  };

enum ENUM_CLOSE_MODE
  {
   CLOSE_ALL          = 0,   // all group positions
   CLOSE_LOSING       = 1,   // only losing tickets
   CLOSE_WINNING      = 2    // only winning tickets
  };

//--- inputs --------------------------------------------------------
input group "1) Group identification"
input long     InpMagicFilter            = 0;        // Magic filter (0 = all magics of this symbol)
input bool     InpOnlyThisChartSymbol    = true;     // Only positions of the chart symbol
input string   InpSymbolsFilter          = "";       // Extra symbol whitelist, comma separated (empty = off)
input string   InpCommentFilter          = "";       // Position comment contains (empty = off)
input bool     InpIncludeBuy             = true;     // Include BUY positions
input bool     InpIncludeSell            = true;     // Include SELL positions
input bool     InpOnlyAfterAttach        = false;    // Manage only positions opened after EA attach
input bool     InpIgnoreManualTickets    = false;    // Ignore tickets with empty comment (manual trades)

input group "2) Group TP / SL"
input ENUM_APPLY_MODE InpApplyMode       = APPLY_SAME_LEVEL; // How TP/SL is distributed over tickets
input double   InpSLPips                 = 300.0;    // Group SL distance, pips (0 = do not set)
input double   InpTPPips                 = 500.0;    // Group TP distance, pips (0 = do not set)
input bool     InpOverwriteExisting      = true;     // Overwrite SL/TP already present on a ticket
input bool     InpAutoApplyToNew         = true;     // Auto-apply to every newly opened position
input bool     InpAutoApplyOnStart       = true;      // Apply group TP/SL to existing positions at startup
input bool     InpReapplyEveryCycle      = true;      // Keep the levels glued every cycle: nothing to press by hand
input double   InpAbsSLPrice             = 0.0;      // Absolute group SL price (0 = use pips)
input double   InpAbsTPPrice             = 0.0;      // Absolute group TP price (0 = use pips)

input group "3) Mirror one manual edit to the whole group (core feature)"
input bool     InpMirrorSL               = true;     // If I edit SL on one ticket -> apply to all
input bool     InpMirrorTP               = true;     // If I edit TP on one ticket -> apply to all
input ENUM_APPLY_MODE InpMirrorMode      = APPLY_SAME_LEVEL; // Mirror as: same price / same distance
input int      InpMirrorGuardMs          = 250;       // Max ms to wait for the echo of our own modify

input group "4) Risk-free / breakeven (automatic)"
input ENUM_BE_MODE  InpBeMode            = BE_BASKET_PIPS; // Risk-free trigger
input double   InpBeTriggerPips          = 200.0;    // Trigger: pips in profit (ticket/basket modes)
input double   InpBeTriggerMoney         = 300.0;    // Trigger: group profit in money (account ccy)
input double   InpBeTriggerPctEquity     = 2.0;      // Trigger: group profit % of equity
input double   InpBeLockPips             = 10.0;     // Lock: how many pips beyond entry (can be 0)
input ENUM_BE_LEVEL InpBeLevel           = BELVL_OWN_ENTRY; // Where to put the SL
input bool     InpBeOnlyIfProfitable     = true;      // Skip tickets that are still losing
input bool     InpBeOneShot              = true;      // Do it once per ticket (never touch SL again)
input bool     InpBeClosePartial         = false;     // Also close part of the group at trigger
input double   InpBeClosePartialPct      = 30.0;      // % of group volume to close
input bool     InpBeUseHardTpInstead     = false;     // Move TP to lock instead of SL (no SL change)

input group "5) Trailing after risk-free"
input ENUM_TRAIL_MODE InpTrailMode       = TRAIL_STEP; // Trailing mode
input double   InpTrailStartPips         = 250.0;     // Start trailing after N pips in profit
input double   InpTrailStepPips          = 30.0;      // Step: lock N pips each time (STEP mode)
input double   InpTrailDistPips          = 120.0;     // Fixed distance behind price (FIXED mode)
input double   InpTrailMinPips           = 40.0;      // Min distance to price (LINEAR mode)
input double   InpTrailCoefPct           = 25.0;      // Shrink coef % of extra profit (LINEAR)
input double   InpTrailMaxPips           = 200.0;     // Max distance cap (LINEAR mode)
input bool     InpTrailFollowGroup       = true;      // Trigger trailing on group avg, not per ticket
input bool     InpTrailMoveTpToo         = false;     // Trail TP as well (rarely useful)
input double   InpTrailTpDistPips        = 250.0;     // TP distance used when InpTrailMoveTpToo

input group "6) Group money targets / optional kill-switch (off by default)"
input bool     InpEnableBasketMoneyExit  = false;     // Close group on money target / money stop
input double   InpBasketTakeMoney        = 500.0;     // Group take-profit in money
input double   InpBasketStopMoney        = 500.0;     // Group stop-loss in money (positive number)
input double   InpEstCommissionPerLot    = 0.0;        // Est. round-turn commission per 1.0 lot (for calc)
input bool     InpEnableKillSwitch       = false;     // Close-all on group drawdown (OFF: only the 60% account breaker closes)
input double   InpMaxDrawdownPctEquity   = 60.0;      // If that switch is enabled: % of equity in floating loss (60 = same line as the breaker)
input bool     InpCloseAllOnKill         = true;      // Kill switch also closes the group

input group "7) Broker safety"
input double   InpPipSize                = 0.0;       // Price value of 1 pip (0 = auto: 0.10 on gold)
input int      InpMinStopsPoints         = 0;         // Extra guard distance in points (on top of broker)
input int      InpMinDeltaPoints         = 2;         // Skip modify if change < N points (anti-spam)
input int      InpDeviationPoints        = 30;        // Max deviation / slippage in points
input int      InpMaxModsPerSecond       = 25;        // Rate limit of modification requests (0 = no limit)
input int      InpMinMsPerTicket         = 0;         // Min ms between 2 mods of the same ticket (0 = none)
input int      InpRetryCount             = 3;         // Retries on requote/busy
input int      InpRetryDelayMs           = 120;       // Floor for the wait before the same request is tried again (ms)
input int      InpSendBackoffMs          = 2000;      // After a rejection: hold this ticket+level back, doubling up to 60 s (0 = retry every cycle)
input int      InpErrorFuseCount         = 8;         // Rejections in a row that pause automatic sending for a while (0 = never)
input bool     InpRequireNewBar          = false;     // Evaluate only once per new bar
input int      InpTimerMs                = 100;       // Fast loop period in ms (0 = OnTick only)
input int      InpIdleRefreshMs          = 1000;      // Loop period in ms while the account holds no positions
input int      InpPanelRefreshMs         = 150;       // Panel repaint period (ms)
input bool     InpInstantMirror          = true;       // React to trade events at once, do not wait for the loop
input bool     InpDryRun                 = false;     // Dry run: log decisions, send nothing

input group "8) News guard - red-folder protection"
input bool     InpNewsEnabled            = true;      // Use the MT5 economic calendar
input ENUM_CALENDAR_EVENT_IMPORTANCE InpNewsImportance = CALENDAR_IMPORTANCE_HIGH; // Minimum importance to react to
input bool     InpNewsIncludeModerate    = false;     // Also react to orange (moderate) events
input int      InpNewsBeforeMin          = 20;        // Minutes before the release to react
input int      InpNewsAfterMin           = 15;        // Minutes after the release to stay defensive
input string   InpNewsCurrencies         = "";        // Currencies to watch, e.g. "USD,EUR" (empty = from symbol)
input ENUM_NEWS_ACTION InpNewsAction     = NEWS_WARN; // What to do inside the window (default: warn, never close)
input bool     InpNewsPauseAutomation    = false;     // Also suspend SL/TP editing inside the window
input bool     InpNewsTightenBeforeClose  = true;      // Move to risk-free first, then close (if action closes)
input string   InpNewsManualWindows      = "";        // Fallback windows "[DOW-]HH:MM-HH:MM;..." server time, DOW 0=Sun
input int      InpNewsRefreshSec         = 30;        // Calendar polling period (seconds, server limit 5204)

input group "9) Risk sizing, money units, broker adaptation"
input double   InpRiskPctPerBasket       = 0.0;        // Auto group SL from risk % of balance (0 = off)
input double   InpRiskRewardRatio        = 0.0;        // Auto TP = risk * ratio (0 = keep InpTPPips)
input double   InpRiskCapPips            = 0.0;        // Max SL pips the auto sizing may use (0 = no cap)
input double   InpRiskFloorPips          = 80.0;       // Min SL pips the auto sizing may use
input double   InpRiskWarnPct            = 40.0;        // Warning only: account floating loss >= % of balance (0 = off, sends nothing)
input int      InpEmergencyFloatLossPct  = 60;          // THE close-all line: account floating loss >= % of balance (0 = off)
input double   InpEmergencyEquityDdPct   = 0.0;         // Drawdown from peak equity >= percent -> close all (0 = off)
input int      InpEmergencyMarginLevelPct= 0;           // Margin level below this percent -> close all (0 = off; not used by default)
input int      InpEmergencyFreeMarginPct = 0;           // Free margin below a share of equity -> close all (0 = off)
input bool     InpEmergencyStepDown      = false;       // Close the worst ticket first instead of everything
input int      InpEmergencyLockHours     = 24;          // After an emergency: keep the EA paused for N hours
input double   InpDailyLossLimitPct      = 0.0;         // Daily loss limit, percent of day-start balance -> pause
input double   InpDailyProfitTargetPct   = 0.0;         // Daily profit target, percent of day-start balance -> pause
input bool     InpDailyCloseOnLimit      = true;        // Also close the group when a daily limit is hit
input ENUM_MONEY_BASIS InpMoneyBasis     = MONEY_AUTO;  // What money inputs mean on a cent account
input double   InpCentDivisor            = 100.0;       // How many account units make 1 real unit on a cent acct
input bool     InpAdaptiveStops          = true;        // If broker rejects a level, widen the guard and retry
input int      InpAdaptiveStopsCapPoints = 300;         // Max guard distance the auto-adaptation may reach

input group "10) Panel, alerts, misc"
input bool     InpShowPanel              = true;      // Show chart panel
input int      InpPanelX                 = 14;        // Panel X offset
input int      InpPanelY                 = 26;        // Panel Y offset
input int      InpFontSize               = 9;         // Font size
input color    InpClrPanelBg             = C'18,22,30';
input color    InpClrText                = clrGainsboro;
input color    InpClrAccent              = clrGold;
input color    InpClrOk                  = clrMediumSeaGreen;
input color    InpClrWarn                = clrOrange;
input bool     InpAlertOnRiskFree        = true;      // Alert when group became risk-free
input bool     InpPlaySound              = false;     // Play sound (alert.wav)
input bool     InpPushNotification       = false;     // Send push to MT5 mobile
input bool     InpVerboseLog             = true;      // Detailed log in Experts tab
input bool     InpPersistPanel           = true;      // Remember what was switched on the panel (per account + symbol)

//--- runtime state -------------------------------------------------
CTrade   g_trade;

double   g_pip          = 0.1;      // resolved pip size in price units
double   g_point        = 0.01;
int      g_digits       = 2;
double   g_slPips       = 0;        // editable from panel
double   g_tpPips       = 0;
double   g_beTrigger    = 0;
double   g_beLock       = 0;
double   g_trailDist    = 0;
bool     g_trailOn      = true;
bool     g_paused       = false;
bool     g_killed       = false;
bool     g_dirty        = true;
bool     g_hedging      = true;
datetime g_start_time   = 0;
datetime g_last_bar     = 0;
string   g_last_action  = "-";
string   g_info_line    = "";
//--- news guard state
bool     g_news_enabled  = true;
bool     g_news_active   = false;
string   g_news_desc     = "";
datetime g_news_next_time= 0;
datetime g_news_scan_at  = 0;
datetime g_news_handled  = 0;
int      g_news_errno    = 0;
bool     g_news_calendar = true;
bool     g_news_manual   = false;
bool     g_news_block_edits = false;
//--- account / money units
bool     g_cent          = false;
double   g_money_factor  = 1.0;
string   g_acct_ccy      = "USD";
double   g_risk_money    = 0.0;   // money at risk for the current group
double   g_money_per_pip = 0.0;
//--- guards
double   g_peak_equity   = 0.0;
int      g_day           = 0;
double   g_day_bal       = 0.0;
datetime g_lockout_until = 0;
int      g_stop_pad      = 0;     // adaptive stop guard, points
string   g_gv_prefix     = "";
string   g_warn         = "";
int      g_mod_this_sec = 0;
long     g_sec_stamp    = 0;
double   g_risk_pct     = 0.0;       // floating loss of the account, percent of balance
bool     g_risk_warned  = false;     // warning latched until the loss recovers
ulong    g_panel_ms     = 0;         // last panel repaint (ms clock)
bool     g_alerts_on    = true;      // pop-up / sound / push, toggled with key 8
long     g_arm_all      = 0;         // the CLOSE ALL second-click window, in ms
long     g_arm_clear    = 0;         // and the same for clearing protection
long     g_cycle        = -1;        // cycle counter, part of the cache key
double   g_a_bal        = 0.0;       // this cycle's account numbers
double   g_a_eq         = 0.0;
double   g_a_ml         = 0.0;
double   g_a_fm         = 0.0;
double   g_a_bid        = 0.0;       // chart symbol quotes
double   g_a_ask        = 0.0;
int      g_a_spread     = 0;
int      g_a_stops      = 0;
int      g_a_freeze     = 0;
double   g_a_mpp_lot    = -1.0;      // money per pip per lot, cached for one symbol
string   g_a_mpp_sym    = "";
bool     g_a_fresh      = false;     // false = something moved, re-read on next use
datetime g_a_now        = 0;         // TimeCurrent() of this snapshot
datetime g_a_snow       = 0;         // TimeTradeServer() of this snapshot
bool     g_a_allowed    = true;      // algo trading on, checked once a second
long     g_a_allowed_ms = -10000;
bool     g_is_tester    = false;     // InTester() is an accessor too: read it once
ulong    g_bo_tk[16];                // tickets with a pending cool-down
long     g_bo_until[16];             // ms until which the same request is held back
string   g_bo_sig[16];               // the level that was rejected: a NEW level may go at once
int      g_bo_fails[16];             // consecutive rejections for that ticket
int      g_bo_n        = 0;
long     g_fuse_until  = 0;          // no automatic sending before this moment (ms)
int      g_fuse_step   = 0;          // how often the cooldown has doubled
int      g_fuse_cnt    = 0;          // rejections in a row
bool     g_fuse_clear  = false;      // a manual APPLY overrides the cooldown once
int      g_send_ok     = 0;          // accepted requests since the panel was opened
int      g_send_fail   = 0;          // rejected requests since then
long     g_last_cycle  = 0;          // watchdog: when the last cycle ran
long     g_watch_ms    = 0;          // when the timer was last re-armed
string   g_row_txt[14];              // last text written to each panel row
color    g_row_clr[14];
bool     g_row_known[14];
bool     g_panel_force  = true;      // paint the panel on the next update, no matter what
long     g_panel_sig    = 0;         // fingerprint of the panel content
bool     g_obj_dirty    = false;     // did anything actually get written?
int      g_timer_ms     = 0;         // what the millisecond timer is set to now
int      g_last_ms      = 0;         // duration of the last management cycle (ms)
int      g_slow_ms      = 0;         // slowest cycle since the terminal was started
bool     g_in_trade     = false;     // re-entrancy guard for OnTradeTransaction
int      g_apply_seq    = 0;
double   g_mirrorSlDist = -1.0;
double   g_mirrorTpDist = -1.0;
double   g_mirrorSlPrice= 0.0;
double   g_absSl          = 0.0;      // runtime group SL price (input or mirrored)
double   g_absTp          = 0.0;      // runtime group TP price (input or mirrored)
double   g_mirrorTpPrice= 0.0;
bool     g_mirrorActive = false;
bool     g_be_partial_done = false;
int      g_be_done_count   = 0;

struct SPos
  {
   ulong    ticket;
   string   symbol;
   long     magic;
   int      type;
   double   open;
   double   sl;
   double   tp;
   double   vol;
   double   profit;
   double   swap;
   datetime time;
   string   comment;
   double   gain_pips;
   double   gain_money;
  };

struct SBasket
  {
   int      cnt, cnt_buy, cnt_sell;
   double   vol_buy, vol_sell, vol_total;
   double   avg_buy, avg_sell, avg_signed;
   double   profit, swap, comm;
   double   gain_pips_buy, gain_pips_sell, gain_pips_net;
   bool     pure_buy, pure_sell;
  };

struct SSticker          // per-ticket memory: our last known SL/TP + timing
  {
   ulong    ticket;
   double   sl, tp;
   datetime seen;         // last time we recorded a change
   long     seq;          // last modification sequence by EA
   bool     be_done;
   ulong    seen_ms;      // ms clock of that record (GetTickCount64)
   double   req_sl, req_tp;  // SL/TP we last asked the server for
   ulong    req_ms;       // ms clock of that request
   bool     pending;      // request sent, its echo has not been seen yet
  };

SPos     g_pos[];
SBasket  g_basket;
SSticker g_st[];

#define GBG "GBG_"

//+------------------------------------------------------------------+
//| Every feature is switched by its own input: one place to decide, no page|
//| of toggles on the chart, so 'attach it and walk away' is literal.|
//+------------------------------------------------------------------+
bool UseMirrorSL()
  {
   return InpMirrorSL;
  }
//+------------------------------------------------------------------+
bool UseMirrorTP()
  {
   return InpMirrorTP;
  }
//+------------------------------------------------------------------+
bool UseAutoApply()
  {
   return (InpAutoApplyOnStart || InpAutoApplyToNew || InpReapplyEveryCycle);
  }
//+------------------------------------------------------------------+
bool UseRiskFree()
  {
   return (InpBeMode != BE_OFF);
  }
//+------------------------------------------------------------------+
bool UseWarn()
  {
   return (InpRiskWarnPct > 0.0);
  }
//+------------------------------------------------------------------+
bool UseKill()
  {
   return InpEnableKillSwitch;
  }
//+------------------------------------------------------------------+
//| Any of the three emergency arms opens the breaker: an account whose only|
//| rule is the margin level used to be unreachable from the panel switch.|
//+------------------------------------------------------------------+
bool UseBreaker()
  {
   return (InpEmergencyFloatLossPct > 0 || InpEmergencyMarginLevelPct > 0 || InpEmergencyStepDown);
  }
//+------------------------------------------------------------------+
bool UseDaily()
  {
   return (InpDailyLossLimitPct > 0.0 || InpDailyProfitTargetPct > 0.0);
  }
//+------------------------------------------------------------------+
bool UseMoney()
  {
   return (InpEnableBasketMoneyExit && (InpBasketTakeMoney > 0.0 || InpBasketStopMoney > 0.0));
  }
//+------------------------------------------------------------------+
bool UseSizing()
  {
   return (InpRiskPctPerBasket > 0.0);
  }
//+------------------------------------------------------------------+
bool UseAdaptive()
  {
   return InpAdaptiveStops;
  }
//+------------------------------------------------------------------+
//| The one thing the chart still toggles: noise, not rules.         |
//+------------------------------------------------------------------+
bool UseAlerts()
  {
   return g_alerts_on;
  }
//+------------------------------------------------------------------+
bool DryOn()
  {
   return InpDryRun;
  }
//+------------------------------------------------------------------+
//| The two runtime toggles start where the inputs leave them, so an untouched|
//| chart behaves exactly like its Inputs.                           |
//+------------------------------------------------------------------+
void RuntimeDefaults()
  {
   g_trailOn      = (InpTrailMode != TRAIL_OFF);
   g_news_enabled = InpNewsEnabled;
   g_alerts_on    = true;
   g_paused       = false;
  }
//+------------------------------------------------------------------+
//| What survives a reattach: the two toggles and the two typed numbers.|
//| A pause is a state of this run, never a setting of the next one. |
//+------------------------------------------------------------------+
void UiSave()
  {
   if(!InpPersistPanel || InTester())
      return;
   GVSet("TRAILUI", g_trailOn ? 1.0 : 0.0);
   GVSet("NEWSUI",  g_news_enabled ? 1.0 : 0.0);
   GVSet("ALERTUI", g_alerts_on ? 1.0 : 0.0);
   GVSet("SLP",     g_slPips);
   GVSet("TPP",     g_tpPips);
  }
//+------------------------------------------------------------------+
void UiLoad()
  {
   if(!InpPersistPanel || InTester())
      return;
   g_trailOn      = (GVGet("TRAILUI", g_trailOn ? 1.0 : 0.0) > 0.5);
   g_news_enabled = (GVGet("NEWSUI",  g_news_enabled ? 1.0 : 0.0) > 0.5);
   g_alerts_on    = (GVGet("ALERTUI", 1.0) > 0.5);
   g_slPips       = MathMax(0.0, GVGet("SLP", g_slPips));
   g_tpPips       = MathMax(0.0, GVGet("TPP", g_tpPips));
   PanelSyncEdits();
  }
//+------------------------------------------------------------------+
//| Key [ - throw the saved panel state away and let the Inputs decide again.|
//+------------------------------------------------------------------+
void UiReset()
  {
   string keys[5] = {"TRAILUI","NEWSUI","ALERTUI","SLP","TPP"};
   if(!InTester() && InpPersistPanel)
      for(int i = 0; i < 5; i++)
         GlobalVariableDel(g_gv_prefix + keys[i]);
   RuntimeDefaults();
   g_slPips    = InpSLPips;
   g_tpPips    = InpTPPips;
   g_beTrigger = InpBeTriggerPips;
   g_beLock    = InpBeLockPips;
   g_trailDist = InpTrailDistPips;
   g_absSl     = InpAbsSLPrice;
   g_absTp     = InpAbsTPPrice;
   g_paused    = false;
   g_last_action = "panel state cleared - the Inputs decide again";
   Log(g_last_action);
   PanelSyncEdits();
  }
//+------------------------------------------------------------------+
//| One place for every loud signal, so the ALERTS switch can hush it |
//+------------------------------------------------------------------+
void Notify(const string txt)
  {
   if(!UseAlerts())
      return;
   Alert("GoldBasketGuard: " + txt);
   if(InpPlaySound)
      PlaySound("alert.wav");
   if(InpPushNotification)
      SendNotification("GoldBasketGuard " + txt);
  }
//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_is_tester = IsTester();
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(g_point <= 0.0)
     {
      Print("GoldBasketGuard: bad symbol settings, EA stopped.");
      return(INIT_FAILED);
     }
   g_pip = (InpPipSize > 0.0) ? InpPipSize : AutoPipSize();
   if(g_pip < g_point)
      g_pip = g_point;

   g_slPips    = InpSLPips;
   g_tpPips    = InpTPPips;
   g_beTrigger = InpBeTriggerPips;
   g_beLock    = InpBeLockPips;
   g_trailDist = InpTrailDistPips;
   g_absSl     = InpAbsSLPrice;
   g_absTp     = InpAbsTPPrice;
   g_start_time= TimeCurrent();
   g_hedging   = (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   g_stop_pad     = InpMinStopsPoints;
   DetectAccountUnits();
   InitAnchors();
   RuntimeDefaults();                // the two runtime toggles start where the Inputs left them
   UiLoad();                         // ... unless the trader already chose something on this chart
   if(g_cent)
      Log(StringFormat("cent account detected (%s): money inputs are multiplied by %.0f", g_acct_ccy, g_money_factor));

   g_trade.SetExpertMagicNumber(InpMagicFilter > 0 ? (ulong)InpMagicFilter : 0);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   if(!g_hedging)
      g_warn = "NETTING account: the group is a single ticket - mirroring is limited.";

   if(InpTimerMs > 0 && !InTester())
     {
      g_timer_ms = MathMax(20, InpTimerMs);
      EventSetMillisecondTimer(g_timer_ms);                 // 100 ms loop: reaction, not 1 s
     }

   if(InpShowPanel && (!InTester() || IsVisual()))
      PanelCreate();

   Log(StringFormat("GoldBasketGuard on %s | pip=%.5f (%.0f pt) | digits=%d | hedging=%s | account=%s%s | risk=%.2f/pip",
                    _Symbol, g_pip, g_pip / g_point, g_digits, g_hedging ? "yes" : "no",
                    g_acct_ccy, g_cent ? " (cent)" : "", MoneyPerPipPerLot(_Symbol) > 0 ? 1.0 : 0.0));
   if(AccountInfoInteger(ACCOUNT_TRADE_EXPERT) == 0)
      g_warn = "the broker account forbids EA trading (ACCOUNT_TRADE_EXPERT = false)";
   RunCycle();
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   UiSave();                             // whatever the trader set on the panel survives a reattach
   EventKillTimer();
   PanelDelete();
   Comment("");
  }
//+------------------------------------------------------------------+
//| Tick                                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   RunCycle();
  }
//+------------------------------------------------------------------+
//| Watchdog (needed when the symbol ticks slowly / weekend)         |
//+------------------------------------------------------------------+
void OnTimer()
  {
   RunCycle();
  }
//+------------------------------------------------------------------+
//| Does this position ticket belong to the group we manage?         |
//+------------------------------------------------------------------+
bool TicketInGroup(const ulong t)
  {
   if(t == 0)
      return false;
   if(StFind(t) >= 0)
      return true;
   if(!PositionSelectByTicket(t))
      return false;
   long   mg    = (long)PositionGetInteger(POSITION_MAGIC);
   int    typ   = (int)PositionGetInteger(POSITION_TYPE);
   datetime op  = (datetime)PositionGetInteger(POSITION_TIME);
   string   cmt = PositionGetString(POSITION_COMMENT);
   string   sym = PositionGetString(POSITION_SYMBOL);
   return MatchPosition(t, sym, mg, cmt, typ, op);
  }
//+------------------------------------------------------------------+
//| Trade events: a new position was opened -> apply group stops     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   SnapReset();                          // quotes, balance and the position list are stale now
   g_panel_force = true;                 // the trader wants to see this one immediately
   if(g_paused || g_killed)
      return;
   if(trans.type == TRADE_TRANSACTION_POSITION)
     {
      bool ours = TicketInGroup(trans.position);
      if(trans.deal_type == DEAL_TYPE_BUY || trans.deal_type == DEAL_TYPE_SELL)
        {
         if(InpAutoApplyToNew && UseAutoApply())
           {
            g_dirty = true;
            g_apply_seq++;
           }
        }
      else
         g_dirty = true;   // position closed -> recompute group
      // A manual SL/TP drag must be mirrored NOW, not on the next timer tick:
      // react inside the event itself (g_in_trade guards against re-entrancy).
      if(ours && InpInstantMirror && !g_in_trade)
        {
         g_in_trade = true;
         RunCycle();
         g_in_trade = false;
        }
     }
   else
      if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
         g_dirty = true;
  }
//+------------------------------------------------------------------+
//| Chart events: panel clicks / hotkeys                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(!InpShowPanel)
     {
      if(id == CHARTEVENT_KEYDOWN)
         OnHotkey((int)lparam);
      return;
     }

   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ChartRedraw();
      if(StringFind(sparam, GBG + "BTN_") == 0)
         OnButton(StringSubstr(sparam, StringLen(GBG) + 4));
      return;
     }

   if(id == CHARTEVENT_OBJECT_ENDEDIT)
     {
      if(StringFind(sparam, GBG + "EDIT_") == 0)
        {
         string which = StringSubstr(sparam, StringLen(GBG) + 5);
         string typed = EditGet(sparam);
         ReadEdits();                    // one reader for every field, incl. the money boxes
         g_dirty = UseAutoApply();       // with AUTO-APPLY on, Enter is enough to send it
         PanelUpdate();
         RunCycle();
         ChartRedraw();
         Log("panel edit " + which + " = " + typed + (StringLen(g_last_action) > 0 ? " | " + g_last_action : ""));
        }
      return;
     }

   if(id == CHARTEVENT_KEYDOWN)
      OnHotkey((int)lparam);
  }
//+------------------------------------------------------------------+
//| Hotkeys: 1 apply both, 2 SL, 3 TP, 4 risk-free, 5 trail, 0 pause |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Keys do what the switch page used to do - the panel itself keeps four|
//| buttons, because everything else runs on its own.                |
//+------------------------------------------------------------------+
void OnHotkey(const int key)
  {
   PanelForce();                        // react visually at once
   switch(key)
     {
      case '1': ReadEdits(); ApplyGroupStops(true,  true,  "hotkey"); break;
      case '2': ReadEdits(); ApplyGroupStops(true,  false, "hotkey"); break;
      case '3': ReadEdits(); ApplyGroupStops(false, true,  "hotkey"); break;
      case '4': ReadEdits(); ForceRiskFree();                          break;
      case '5': g_trailOn = !g_trailOn;
                Log("trailing " + (g_trailOn ? "ON" : "OFF")); UiSave();               break;
      case '6': g_news_enabled = !g_news_enabled;
                Log("news guard " + (g_news_enabled ? "ON" : "OFF")); UiSave();       break;
      case '7': ClearLockout();                                                         break;
      case '8': g_alerts_on = !g_alerts_on;
                Log("alerts " + (g_alerts_on ? "ON" : "OFF")); UiSave();               break;
      case '9': if(ArmConfirm("CLOSE ALL", g_arm_all)) CloseGroup(CLOSE_ALL, "key 9");  break;
      case '0': g_paused = !g_paused;
                Notify(g_paused ? "PAUSED - nothing will be sent" : "RUNNING - automation back on");
                Log("EA " + (g_paused ? "PAUSED" : "ACTIVE"));                           break;
      case '-': if(ArmConfirm("CLEAR SL/TP", g_arm_clear)) ApplyGroupStopsClear();       break;
      case '[': UiReset();                                                              break;
     }
   PanelUpdate();
   RunCycle();
  }
//+------------------------------------------------------------------+
//| A destructive click needs a second one within six seconds. The clock is the|
//| terminal's own milliseconds: TimeCurrent() stands still when the market|
//| does, so a click made before a quiet hour used to stay armed.    |
//+------------------------------------------------------------------+
bool ArmConfirm(string btn, long &arm)
  {
   long now = NowMs();
   if(arm == 0 || now - arm >= 6000)
     {
      arm = now;
      g_last_action = btn + ": press again within 6 s to confirm";
      Log(g_last_action);
      Notify(g_last_action);
      return false;
     }
   arm = 0;
   return true;
  }
//+------------------------------------------------------------------+
//| Four buttons. Each one runs a management cycle at once, so the panel shows|
//| the result of the click instead of waiting for the next tick.    |
//+------------------------------------------------------------------+
void OnButton(string name)
  {
   PanelForce();                        // a click repaints the panel at once
   if(name == "APPLY")
     {
      ReadEdits();
      ApplyGroupStops(true, true, "panel");
     }
   else if(name == "PAUSE")
     {
      g_paused = !g_paused;
      Notify(g_paused ? "PAUSED - nothing will be sent" : "RUNNING - automation back on");
     }
   else if(name == "UNLOCK")
      ClearLockout();
   else if(name == "CLOSEALL")
     {
      if(ArmConfirm("CLOSE ALL", g_arm_all))
         CloseGroup(CLOSE_ALL, "panel close-all");
     }
   PanelUpdate();
   RunCycle();
   ChartRedraw();
  }
//+------------------------------------------------------------------+
//| Auto pip size: gold (2-3 digits) -> 0.10, classic forex -> 10 pts|
//+------------------------------------------------------------------+
double AutoPipSize()
  {
   double pt = g_point;
   int    dg = g_digits;
   if(dg <= 1)  return 0.10;                 // XAUUSD 1 digit
   if(dg == 2)  return 0.10;                 // XAUUSD 2 digits -> 1 pip = 10 cents of gold
   if(dg == 3)  return 0.10;                 // XAUUSD 3 digits
   if(dg == 0)  return 1.0;
   return pt * 10.0;                          // 4/5 digits -> classic
  }
//+------------------------------------------------------------------+
//| One management cycle, timed, so the panel can show the real speed |
//+------------------------------------------------------------------+
void RunCycle()
  {
   long t0 = NowMs();
   // If OnTimer stopped firing (a chart switch or a long sleep can do that), the EA
   // looks dead although it is loaded. Any tick or event re-arms the timer at once.
   if(g_last_cycle > 0 && !InTester() && InpTimerMs > 0 &&
      t0 - g_last_cycle > MathMax(1500, 6 * g_timer_ms) && t0 - g_watch_ms > 30000)
     {
      g_watch_ms = t0;
      EventSetMillisecondTimer(g_timer_ms);
      Log(StringFormat("no cycle for %d ms - the timer was re-armed", (int)(t0 - g_last_cycle)));
     }
   g_last_cycle = t0;
   Manage();
   TuneTimer();
   g_last_ms = (int)(NowMs() - t0);
   if(g_last_ms > g_slow_ms)
      g_slow_ms = g_last_ms;
  }
//+------------------------------------------------------------------+
//| One snapshot per cycle. The terminal accessors are the expensive   |
//| part of a 100 ms loop, so every guard reads from here. After an    |
//| order the snapshot is dropped: nothing stale ever decides a close. |
//+------------------------------------------------------------------+
void SnapRead()
  {
   g_a_bal    = AccountInfoDouble(ACCOUNT_BALANCE);
   g_a_eq     = AccountInfoDouble(ACCOUNT_EQUITY);
   g_a_ml     = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   g_a_fm     = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   g_a_bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   g_a_ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   g_a_spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   g_a_stops  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   g_a_freeze = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   g_a_now    = TimeCurrent();
   g_a_snow   = TimeTradeServer();
   if(g_a_snow <= 0)
      g_a_snow = g_a_now;
   g_a_mpp_sym = "";                       // tick values are re-read once per snapshot
   g_a_mpp_lot = -1.0;
   g_a_fresh  = true;
  }
//+------------------------------------------------------------------+
void SnapReset()
  {
   g_a_fresh = false;
  }
//+------------------------------------------------------------------+
double AcctBal()
  {
   if(!g_a_fresh)
      SnapRead();
   return g_a_bal;
  }
//+------------------------------------------------------------------+
double AcctEq()
  {
   if(!g_a_fresh)
      SnapRead();
   return g_a_eq;
  }
//+------------------------------------------------------------------+
double AcctMarginLevel()
  {
   if(!g_a_fresh)
      SnapRead();
   return g_a_ml;
  }
//+------------------------------------------------------------------+
double AcctFreeMargin()
  {
   if(!g_a_fresh)
      SnapRead();
   return g_a_fm;
  }
//+------------------------------------------------------------------+
//| Static per-cycle symbol properties: they only change on a rebuild  |
//| of the symbol settings, never between two lines of one cycle       |
//+------------------------------------------------------------------+
double PointOf(string sym)
  {
   return (sym == _Symbol) ? g_point : SymbolInfoDouble(sym, SYMBOL_POINT);
  }
//+------------------------------------------------------------------+
int DigitsOf(string sym)
  {
   return (sym == _Symbol) ? g_digits : (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
  }
//+------------------------------------------------------------------+
int StopsOf(string sym)
  {
   if(sym == _Symbol)
     {
      if(!g_a_fresh)
         SnapRead();
      return g_a_stops;
     }
   return (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
  }
//+------------------------------------------------------------------+
int FreezeOf(string sym)
  {
   if(sym == _Symbol)
     {
      if(!g_a_fresh)
         SnapRead();
      return g_a_freeze;
     }
   return (int)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
  }
//+------------------------------------------------------------------+
//| Quotes: the chart symbol comes from the snapshot, any other symbol |
//| is read live, so a multi-symbol group is never served stale data   |
//+------------------------------------------------------------------+
double BidPx(string sym)
  {
   if(g_a_fresh && sym == _Symbol)
      return g_a_bid;
   return SymbolInfoDouble(sym, SYMBOL_BID);
  }
//+------------------------------------------------------------------+
double AskPx(string sym)
  {
   if(g_a_fresh && sym == _Symbol)
      return g_a_ask;
   return SymbolInfoDouble(sym, SYMBOL_ASK);
  }
//+------------------------------------------------------------------+
//| The loop itself: slow down while there is nothing on the account,  |
//| because a new position always wakes it up through the trade event  |
//+------------------------------------------------------------------+
void TuneTimer()
  {
   if(InTester() || InpTimerMs <= 0)
      return;
   bool quiet = (PositionsTotal() == 0 && ArraySize(g_pos) == 0 && !g_paused);
   int  want  = quiet ? (int)MathMax((double)InpTimerMs, (double)InpIdleRefreshMs)
                      : (int)MathMax(20, InpTimerMs);
   if(want != g_timer_ms)
     {
      g_timer_ms = want;
      EventSetMillisecondTimer(want);
     }
  }
//+------------------------------------------------------------------+
void Manage()
  {
   g_cycle++;
   SnapRead();
   TouchRateWindow();
   g_warn        = "";
   g_info_line   = "";
   RiskWarning();                     // read-only: never sends anything

   LockoutTick();
   NewsScan();

   if(InpRequireNewBar)
     {
      datetime bt = iTime(_Symbol, PERIOD_CURRENT, 0);
      if(bt == g_last_bar && !InTester())
        {
         PanelUpdate();
         return;
        }
      g_last_bar = bt;
     }

   if(g_killed)
     {
      CollectGroup();                 // keep the readout honest even while locked
      ComputeBasket();
      PanelUpdate();
      return;
     }

   if(!TradeAllowedNow())
     {
      g_warn = "ALGO TRADING is disabled in the terminal - levels are only calculated, not sent";
      PanelUpdate();
      return;
     }

   int n = CollectGroup();
   ComputeBasket();
   PruneStickers();

   if(n == 0)
     {
      g_be_partial_done = false;        // a fresh group starts a fresh cycle
      g_dirty = InpAutoApplyToNew;      // stay ready for the next ticket
      EmergencyGuard();
      DailyGuard();
      PanelUpdate();
      return;
     }

   ApplyRiskSizing();
   DetectManualEdits();

   if(!g_paused && !(g_news_block_edits && InpNewsPauseAutomation))
     {
      if(g_dirty || InpReapplyEveryCycle)
        {
         if(InpAutoApplyOnStart || g_apply_seq > 0 || InpReapplyEveryCycle)
            ApplyGroupStops(g_slPips > 0.0, g_tpPips > 0.0, "auto");
         g_dirty = false;
        }
      ApplyRiskFree(false);
      ApplyTrailing();
      CheckMoneyExits();
      CheckKillSwitch();
     }

   NewsGuard();
   EmergencyGuard();
   DailyGuard();

   PanelUpdate();
  }
//+------------------------------------------------------------------+
//| Filtering                                                         |
//+------------------------------------------------------------------+
bool SymbolAllowed(string sym)
  {
   if(InpOnlyThisChartSymbol && sym != _Symbol)
      return false;
   if(StringLen(InpSymbolsFilter) > 0)
     {
      string list[];
      int c = StringSplit(InpSymbolsFilter, ',', list);
      for(int i = 0; i < c; i++)
        {
         StringTrimLeft(list[i]);
         StringTrimRight(list[i]);
         string want = list[i];
         string have = sym;
         StringToUpper(want);
         StringToUpper(have);
         if(want == have)
            return true;
        }
      return false;
     }
   return true;
  }
//+------------------------------------------------------------------+
bool MatchPosition(ulong ticket, string sym, long magic, string cmt, int type, datetime opentime)
  {
   if(!SymbolAllowed(sym))
      return false;
   if(InpMagicFilter != 0 && magic != InpMagicFilter)
      return false;
   if(type == POSITION_TYPE_BUY && !InpIncludeBuy)
      return false;
   if(type == POSITION_TYPE_SELL && !InpIncludeSell)
      return false;
   if(InpIgnoreManualTickets && StringLen(cmt) == 0)
      return false;
   if(StringLen(InpCommentFilter) > 0 && StringFind(cmt, InpCommentFilter) < 0)
      return false;
   if(InpOnlyAfterAttach && opentime < g_start_time)
      return false;
   return true;
  }
//+------------------------------------------------------------------+
//| Read the group into g_pos[]                                        |
//+------------------------------------------------------------------+
int CollectGroup()
  {
   int total = PositionsTotal();
   int k     = 0;
   if(ArraySize(g_pos) < total)
      ArrayResize(g_pos, MathMax(1, total));       // reserve once: no resize per ticket
   for(int i = 0; i < total; i++)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      //--- cheap discriminators first: most tickets on the account are not ours,
      //    and every PositionGet* we skip is a terminal call we do not pay for
      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(type != POSITION_TYPE_BUY && type != POSITION_TYPE_SELL)
         continue;
      if(type == POSITION_TYPE_BUY ? !InpIncludeBuy : !InpIncludeSell)
         continue;
      long magic = 0;
      if(InpMagicFilter != 0)
        {
         magic = PositionGetInteger(POSITION_MAGIC);
         if(magic != InpMagicFilter)
            continue;
        }
      datetime ot = 0;
      if(InpOnlyAfterAttach)
        {
         ot = (datetime)PositionGetInteger(POSITION_TIME);
         if(ot < g_start_time)
            continue;
        }
      string sym = PositionGetString(POSITION_SYMBOL);
      if(!SymbolAllowed(sym))
         continue;
      string cmt = PositionGetString(POSITION_COMMENT);
      if(!MatchPosition(t, sym, magic, cmt, type, ot))
         continue;

      g_pos[k].ticket   = t;
      g_pos[k].symbol   = sym;
      g_pos[k].magic    = magic;
      g_pos[k].type     = type;
      g_pos[k].open     = PositionGetDouble(POSITION_PRICE_OPEN);
      g_pos[k].sl       = PositionGetDouble(POSITION_SL);
      g_pos[k].tp       = PositionGetDouble(POSITION_TP);
      g_pos[k].vol      = PositionGetDouble(POSITION_VOLUME);
      g_pos[k].profit   = PositionGetDouble(POSITION_PROFIT);
      g_pos[k].swap     = PositionGetDouble(POSITION_SWAP);
      g_pos[k].time     = ot;
      g_pos[k].comment  = cmt;
      g_pos[k].gain_money = g_pos[k].profit + g_pos[k].swap;
      double cur = (type == POSITION_TYPE_BUY) ? BidPx(sym) : AskPx(sym);
      g_pos[k].gain_pips = (type == POSITION_TYPE_BUY) ? (cur - g_pos[k].open) / g_pip
                                                        : (g_pos[k].open - cur) / g_pip;
      k++;
     }
   ArrayResize(g_pos, k);
   return k;
  }
//+------------------------------------------------------------------+
void ComputeBasket()
  {
   g_basket.cnt = 0;  g_basket.cnt_buy = 0;  g_basket.cnt_sell = 0;
   g_basket.vol_buy = 0; g_basket.vol_sell = 0; g_basket.vol_total = 0;
   g_basket.avg_buy = 0; g_basket.avg_sell = 0; g_basket.avg_signed = 0;
   g_basket.profit = 0;  g_basket.swap = 0;   g_basket.comm = 0;
   g_basket.gain_pips_buy = 0; g_basket.gain_pips_sell = 0; g_basket.gain_pips_net = 0;
   g_basket.pure_buy = false; g_basket.pure_sell = false;

   int n = ArraySize(g_pos);
   double num_buy = 0, num_sell = 0, num_signed = 0, den_abs = 0;
   for(int i = 0; i < n; i++)
     {
      g_basket.cnt++;
      g_basket.profit += g_pos[i].profit;
      g_basket.swap   += g_pos[i].swap;
      g_basket.comm   += g_pos[i].vol * RealMoney(InpEstCommissionPerLot);
      if(g_pos[i].type == POSITION_TYPE_BUY)
        {
         g_basket.cnt_buy++;
         g_basket.vol_buy += g_pos[i].vol;
         num_buy  += g_pos[i].open * g_pos[i].vol;
         num_signed += g_pos[i].open * g_pos[i].vol;
        }
      else
        {
         g_basket.cnt_sell++;
         g_basket.vol_sell += g_pos[i].vol;
         num_sell += g_pos[i].open * g_pos[i].vol;
         num_signed -= g_pos[i].open * g_pos[i].vol;
        }
      den_abs += g_pos[i].vol;
     }
   g_basket.vol_total = g_basket.vol_buy + g_basket.vol_sell;
   if(g_basket.vol_buy  > 0) g_basket.avg_buy  = num_buy  / g_basket.vol_buy;
   if(g_basket.vol_sell > 0) g_basket.avg_sell = num_sell / g_basket.vol_sell;
   g_basket.avg_signed = (den_abs > 0) ? num_signed / den_abs : 0;
   g_basket.pure_buy  = (g_basket.cnt_sell == 0 && g_basket.cnt_buy  > 0);
   g_basket.pure_sell = (g_basket.cnt_buy  == 0 && g_basket.cnt_sell > 0);

   string psym = (ArraySize(g_pos) > 0) ? g_pos[0].symbol : _Symbol;
   if(g_basket.vol_buy > 0)  g_basket.gain_pips_buy  = (SymbolInfoDouble(psym, SYMBOL_BID) - g_basket.avg_buy) / g_pip;
   if(g_basket.vol_sell > 0) g_basket.gain_pips_sell = (g_basket.avg_sell - SymbolInfoDouble(psym, SYMBOL_ASK)) / g_pip;

   // net direction gain in pips (what the group as a whole is doing)
   double bid = SymbolInfoDouble(psym, SYMBOL_BID);
   double ask = SymbolInfoDouble(psym, SYMBOL_ASK);
   double netvol = g_basket.vol_buy - g_basket.vol_sell;
   if(MathAbs(netvol) < 1e-8)
      g_basket.gain_pips_net = 0;
   else
     {
      if(netvol > 0 && g_basket.avg_buy > 0)   g_basket.gain_pips_net = (bid - g_basket.avg_buy) / g_pip;
      else if(netvol < 0 && g_basket.avg_sell > 0) g_basket.gain_pips_net = (g_basket.avg_sell - ask) / g_pip;
      else                                     g_basket.gain_pips_net = 0;
     }
  }
//+------------------------------------------------------------------+
//| Group gain in pips used for basket triggers                       |
//+------------------------------------------------------------------+
double BasketGainPips()
  {
   if(g_basket.pure_buy)  return g_basket.gain_pips_buy;
   if(g_basket.pure_sell) return g_basket.gain_pips_sell;
   return g_basket.gain_pips_net;
  }
//+------------------------------------------------------------------+
double GroupNetMoney()
  {
   return g_basket.profit + g_basket.swap - g_basket.comm;
  }
//+------------------------------------------------------------------+
double AnchorPrice(const int i, const int mode)
  {
   bool buy = (g_pos[i].type == POSITION_TYPE_BUY);
   if(mode == (int)APPLY_FROM_WORST)
     {
      double worst = g_pos[i].open;
      int n = ArraySize(g_pos);
      for(int j = 0; j < n; j++)
        {
         if(g_pos[j].type != g_pos[i].type)
            continue;
         if(buy)  { if(g_pos[j].open < worst) worst = g_pos[j].open; }
         else     { if(g_pos[j].open > worst) worst = g_pos[j].open; }
        }
      return worst;
     }
   if(mode == (int)APPLY_SAME_LEVEL)
     {
      double a = buy ? g_basket.avg_buy : g_basket.avg_sell;
      if(a > 0) return a;
     }
   if(mode == (int)APPLY_PER_TICKET)
      return g_pos[i].open;
   // APPLY_PER_TICKET (or a one-sided basket): every ticket uses its own entry
   return g_pos[i].open;
  }
//+------------------------------------------------------------------+
//| Detect a manual SL/TP edit on ONE ticket and mirror it to the rest|
//+------------------------------------------------------------------+
void DetectManualEdits()
  {
   if(!UseMirrorSL() && !UseMirrorTP())
      return;
   int  n = ArraySize(g_pos);
   bool need_apply = false;
   bool do_sl      = false;          // only the side the trader really touched
   bool do_tp      = false;
   for(int i = 0; i < n; i++)
     {
      int k = StFind(g_pos[i].ticket);
      if(k < 0)
        {
         StRemember(i);                       // new ticket, just record it
         continue;
        }
      double pt = g_point * 0.5;
      bool sl_diff = (MathAbs(g_pos[i].sl - g_st[k].sl) > pt);
      bool tp_diff = (MathAbs(g_pos[i].tp - g_st[k].tp) > pt);
      if(!sl_diff && !tp_diff)
        {
         // nothing to mirror: our memory already equals reality. Close the request as
         // soon as it is matched, or as soon as the echo window has simply passed.
         if(g_st[k].pending && (IsOurEcho(i, k, pt) ||
            NowMs() - (long)g_st[k].req_ms > InpMirrorGuardMs))
            g_st[k].pending = false;
         continue;
        }

      // Something DID change. Only a value we did not ask for counts as a manual
      // edit, so a fast drag right after one of our own modifies is never swallowed
      // by a blind time window (the old bug: such an edit was silently dropped).
      bool echoed = IsOurEcho(i, k, pt);
      if(g_st[k].pending && !echoed && StPendingLive(k))
         continue;                              // request in flight, re-check next cycle
      g_st[k].pending = false;
      if(echoed)
        {
         StRemember(i);
         continue;                              // that one was ours
        }
      StRemember(i);                            // memory now holds the trader's values

      if(sl_diff && UseMirrorSL())
        {
         bool removed = (g_pos[i].sl <= 0.0);
         g_mirrorSlDist  = removed ? -1.0 : MathAbs(g_pos[i].sl - g_pos[i].open) / g_pip;
         g_mirrorSlPrice = removed ? -1.0 : g_pos[i].sl;
         g_mirrorActive  = true;
         need_apply      = true;
         do_sl           = true;
         // remember the trader's choice so the next new ticket inherits it as well
         if(!removed)
           {
            g_slPips = g_mirrorSlDist;
            g_absSl  = (InpMirrorMode == APPLY_SAME_LEVEL) ? g_pos[i].sl : 0.0;
            EditSet("SL",DoubleToString(g_slPips,1));
           }
         else
           {
            g_slPips = 0.0;
            g_absSl  = 0.0;
            EditSet("SL","0.0");
           }
         Log(StringFormat("manual SL on #%s (%.2f pips) -> mirroring to the group",
                          Tk(g_pos[i].ticket), g_mirrorSlDist));
        }
      if(tp_diff && UseMirrorTP())
        {
         bool removed = (g_pos[i].tp <= 0.0);
         g_mirrorTpDist  = removed ? -1.0 : MathAbs(g_pos[i].tp - g_pos[i].open) / g_pip;
         g_mirrorTpPrice = removed ? -1.0 : g_pos[i].tp;
         g_mirrorActive  = true;
         need_apply      = true;
         do_tp           = true;
         if(!removed)
           {
            g_tpPips = g_mirrorTpDist;
            g_absTp  = (InpMirrorMode == APPLY_SAME_LEVEL) ? g_pos[i].tp : 0.0;
            EditSet("TP",DoubleToString(g_tpPips,1));
           }
         else
           {
            g_tpPips = 0.0;
            g_absTp  = 0.0;
            EditSet("TP","0.0");
           }
         Log(StringFormat("manual TP on #%s (%.2f pips) -> mirroring to the group",
                          Tk(g_pos[i].ticket), g_mirrorTpDist));
        }
     }
   if(need_apply && g_mirrorActive)
      ApplyGroupStops(do_sl, do_tp, "mirror");
  }
//+------------------------------------------------------------------+
//| Apply group SL / TP to every ticket of the group                  |
//+------------------------------------------------------------------+
void ApplyGroupStops(const bool doSL, const bool doTP, string reason)
  {
   int n = ArraySize(g_pos);
   if(n == 0)
     {
      g_last_action = "group empty - nothing to apply";
      return;
     }
   double sl_dist = (g_mirrorSlDist  >= 0) ? g_mirrorSlDist  : g_slPips;
   double tp_dist = (g_mirrorTpDist >= 0) ? g_mirrorTpDist : g_tpPips;
   double sl_lvl  = (g_mirrorSlPrice != 0.0) ? g_mirrorSlPrice : g_absSl;
   double tp_lvl  = (g_mirrorTpPrice != 0.0) ? g_mirrorTpPrice : g_absTp;
   int    mode    = (g_mirrorActive ? (int)InpMirrorMode : (int)InpApplyMode);

   int done = 0, skipped = 0;
   for(int i = 0; i < n; i++)
     {
      if(!InpOverwriteExisting && ((doSL && g_pos[i].sl > 0) || (doTP && g_pos[i].tp > 0)))
        { skipped++; continue; }

      double sl, tp;
      if(!DesiredLevels(i, mode, sl_dist, tp_dist, sl_lvl, tp_lvl, sl, tp))
        { skipped++; continue; }
      if(!doSL) sl = g_pos[i].sl;
      if(!doTP) tp = g_pos[i].tp;
      if(TryModify(i, sl, tp, reason)) done++;
     }

   g_mirrorSlDist = -1; g_mirrorTpDist = -1;
   g_mirrorSlPrice = 0; g_mirrorTpPrice = 0;
   g_mirrorActive = false;

   g_last_action = StringFormat("%s -> %d ticket(s)  SL %.1f p / TP %.1f p", reason, done, sl_dist, tp_dist);
   if(InpVerboseLog)
      PrintFormat("GoldBasketGuard: apply [%s] done=%d skipped=%d sl_dist=%.1f tp_dist=%.1f mode=%d",
                  reason, done, skipped, sl_dist, tp_dist, mode);
  }
//+------------------------------------------------------------------+
//| Remove SL/TP from the whole group (manual rescue)                 |
//+------------------------------------------------------------------+
void ApplyGroupStopsClear()
  {
   int n = ArraySize(g_pos);
   for(int i = 0; i < n; i++)
      if(g_pos[i].sl > 0 || g_pos[i].tp > 0)
         TryModify(i, 0.0, 0.0, "clear");
   g_last_action = "SL/TP removed from " + IntegerToString(n) + " tickets";
  }
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| The broker minimum moved the level: say it once, then stay quiet  |
//+------------------------------------------------------------------+
double ClampNotice(const string what, const double raw, const double v, const int i)
  {
   static string last = "";
   if(MathAbs(v - raw) > g_point * 0.5)
     {
      string now = what + DoubleToString(v, g_digits);
      if(now != last)
        {
         last = now;
         Log(StringFormat("%s of #%s sits inside the broker minimum -> moved to %s",
                          what, Tk(g_pos[i].ticket), DoubleToString(v, g_digits)));
        }
     }
   return v;
  }
//+------------------------------------------------------------------+
bool DesiredLevels(const int i, const int mode, const double sl_dist, const double tp_dist,
                   const double sl_level, const double tp_level, double &sl, double &tp)
  {
   sl = g_pos[i].sl;                    // default: leave the ticket alone
   tp = g_pos[i].tp;

   bool   buy  = (g_pos[i].type == POSITION_TYPE_BUY);
   double anch = AnchorPrice(i, mode);
   if(anch <= 0.0)
      return false;

   //--- SL side ------------------------------------------------------
   if(sl_level < 0.0)                          // negative level = remove it
      sl = 0.0;
   else
     {
      double raw_sl = (sl_level > 0.0) ? sl_level
                     : (sl_dist > 0.0 ? (buy ? anch - sl_dist * g_pip : anch + sl_dist * g_pip) : 0.0);
      double v;
      if(raw_sl > 0.0 && FinalizeLevel(g_pos[i].symbol, g_pos[i].type, true, raw_sl, v, true))
        {
         sl = ClampNotice("SL", raw_sl, v, i);
        }
     }

   //--- TP side ------------------------------------------------------
   if(tp_level < 0.0)
      tp = 0.0;
   else
     {
      double raw_tp = (tp_level > 0.0) ? tp_level
                     : (tp_dist > 0.0 ? (buy ? anch + tp_dist * g_pip : anch - tp_dist * g_pip) : 0.0);
      double v;
      if(raw_tp > 0.0 && FinalizeLevel(g_pos[i].symbol, g_pos[i].type, false, raw_tp, v, true))
        {
         tp = ClampNotice("TP", raw_tp, v, i);
        }
     }

   return (MathAbs(sl - g_pos[i].sl) > 0.0 || MathAbs(tp - g_pos[i].tp) > 0.0);
  }
//+------------------------------------------------------------------+
//| Validate / clamp a level against broker stop & freeze rules       |
//+------------------------------------------------------------------+
bool FinalizeLevel(string sym, int type, bool is_sl, double raw, double &out, bool allow_clamp)
  {
   out = 0.0;
   if(raw <= 0.0)
      return false;

   double pt    = PointOf(sym);
   double ask   = AskPx(sym);
   double bid   = BidPx(sym);
   int    dg    = DigitsOf(sym);
   double stops = (double)StopsOf(sym) * pt;
   double min_gap = MathMax(stops, (double)InpMinStopsPoints * pt) + pt * 0.5;
   if(min_gap <= 0.0)
      min_gap = pt * 10.0;

   if(type == POSITION_TYPE_BUY)
     {
      if(is_sl)
        {
         if(raw >= bid)
           { g_warn = "BUY SL rejected: level is not below the market"; return false; }
         if(raw > bid - min_gap && allow_clamp)
            raw = bid - min_gap;
        }
      else
        {
         if(raw <= bid)
           { g_warn = "BUY TP rejected: level is not above the market"; return false; }
         if(raw < ask + min_gap)
            raw = ask + min_gap;
        }
     }
   else
     {
      if(is_sl)
        {
         if(raw <= ask)
           { g_warn = "SELL SL rejected: level is not above the market"; return false; }
         if(raw < ask + min_gap && allow_clamp)
            raw = ask + min_gap;
        }
      else
        {
         if(raw >= ask)
           { g_warn = "SELL TP rejected: level is not below the market"; return false; }
         if(raw > bid - min_gap)
            raw = bid - min_gap;
        }
     }

   out = NormalizeDouble(raw, dg);
   if(out <= 0.0)
      return false;
   return true;
  }
//+------------------------------------------------------------------+
//| Panel / hotkey: force risk-free immediately                        |
//+------------------------------------------------------------------+
void ForceRiskFree()
  {
   ApplyRiskFree(true);
   g_last_action = "risk-free forced on the group";
  }
//+------------------------------------------------------------------+
//| Automatic risk-free (breakeven) of the group                      |
//+------------------------------------------------------------------+
void ApplyRiskFree(const bool force)
  {
   if(!UseRiskFree() && !force)
      return;
   int n = ArraySize(g_pos);
   if(n == 0)
      return;

   double eq = AcctEq();
   bool   group_trig = true;
   if(!force)
     {
      switch(InpBeMode)
        {
         case BE_TICKET_PIPS:    group_trig = true; break;   // evaluated per ticket below
         case BE_BASKET_PIPS:    group_trig = (BasketGainPips() >= g_beTrigger); break;
         case BE_BASKET_MONEY:   group_trig = (GroupNetMoney() >= RealMoney(InpBeTriggerMoney)); break;
         case BE_BASKET_PCT_EQ:  group_trig = (eq > 0 && GroupNetMoney() >= eq * InpBeTriggerPctEquity / 100.0); break;
         default:                group_trig = false; break;
        }
      if(!group_trig)
         return;
     }

   int changed = 0;
   for(int i = 0; i < n; i++)
     {
      int k = StFind(g_pos[i].ticket);
      bool buy = (g_pos[i].type == POSITION_TYPE_BUY);

      if(InpBeMode == BE_TICKET_PIPS && !force)
         if(g_pos[i].gain_pips < g_beTrigger)
            continue;
      if(k >= 0 && InpBeOneShot && g_st[k].be_done && !force)
         continue;
      if(InpBeOnlyIfProfitable && g_pos[i].gain_pips <= 0.0)
         continue;

      double anch = (buy ? g_basket.avg_buy : g_basket.avg_sell);
      if(InpBeLevel != BELVL_GROUP_AVG || anch <= 0.0)
         anch = g_pos[i].open;   // BELVL_OWN_ENTRY (default) or an empty side
      double off = g_beLock * g_pip;

      if(InpBeUseHardTpInstead)
        {
         double raw_tp = buy ? (anch + off) : (anch - off);
         double tp;
         if(!FinalizeLevel(g_pos[i].symbol, g_pos[i].type, false, raw_tp, tp, true))
            continue;
         if(g_pos[i].tp > 0.0 && (buy ? (tp >= g_pos[i].tp) : (tp <= g_pos[i].tp)))
            continue;                                  // do not move TP away
         if(TryModify(i, g_pos[i].sl, tp, "risk-free TP"))
           {
            changed++;
            if(k >= 0) g_st[k].be_done = true;
           }
        }
      else
        {
         double raw_sl = buy ? (anch + off) : (anch - off);
         double sl;
         if(!FinalizeLevel(g_pos[i].symbol, g_pos[i].type, true, raw_sl, sl, true))
            continue;
         if(!IsBetterStop(g_pos[i].type, g_pos[i].sl, sl))
            continue;                                  // SL only moves in favour
         if(TryModify(i, sl, g_pos[i].tp, "risk-free"))
           {
            changed++;
            if(k >= 0) g_st[k].be_done = true;
           }
        }
     }

   if(changed > 0)
     {
      g_be_done_count += changed;
      g_last_action = StringFormat("RISK-FREE: %d ticket(s) moved to entry + %.1f pips", changed, g_beLock);
      if(InpBeClosePartial && !g_be_partial_done)
        {
         ClosePartialGroup(InpBeClosePartialPct, "risk-free partial");
         g_be_partial_done = true;
        }
      string msg = StringFormat("%d ticket(s) are now risk-free on %s (lock %.1f pips)", changed, _Symbol, g_beLock);
      Log(msg);
      if(InpAlertOnRiskFree)
        {
         Notify(msg);
        }
     }
  }
//+------------------------------------------------------------------+
//| SL may only be tightened, never loosened                          |
//+------------------------------------------------------------------+
bool IsBetterStop(int type, double cur, double cand)
  {
   double d = g_point * MathMax(1, InpMinDeltaPoints);
   if(cand <= 0.0)
      return false;
   if(cur <= 0.0)
      return true;
   if(type == POSITION_TYPE_BUY)
      return (cand > cur + d);
   return (cand < cur - d);
  }
//+------------------------------------------------------------------+
//| Trailing stop of the group, active after the risk-free step       |
//+------------------------------------------------------------------+
void ApplyTrailing()
  {
   if(InpTrailMode == TRAIL_OFF || !g_trailOn)
      return;
   int    n   = ArraySize(g_pos);
   double grp = BasketGainPips();
   for(int i = 0; i < n; i++)
     {
      double trig_gain = InpTrailFollowGroup ? grp : g_pos[i].gain_pips;
      if(trig_gain < InpTrailStartPips)
         continue;
      if(g_pos[i].gain_pips <= 0.0)
         continue;                     // never trail a ticket that is under water

      bool   buy = (g_pos[i].type == POSITION_TYPE_BUY);
      double mkt = buy ? BidPx(g_pos[i].symbol) : AskPx(g_pos[i].symbol);
      double own = g_pos[i].gain_pips;
      double raw_sl, d;

      if(InpTrailMode == TRAIL_STEP)
        {
         double step = MathMax(1.0, InpTrailStepPips);
         double gap  = MathMax(0.0, InpTrailMinPips);
         double locked = MathFloor((own - gap) / step) * step;
         if(locked < 0.0) locked = 0.0;
         raw_sl = buy ? (g_pos[i].open + locked * g_pip)
                      : (g_pos[i].open - locked * g_pip);
        }
      else
        {
         if(InpTrailMode == TRAIL_LINEAR)
           {
            d = InpTrailMaxPips - (own - InpTrailStartPips) * InpTrailCoefPct / 100.0;
            d = MathMax(InpTrailMinPips, MathMin(d, InpTrailMaxPips));
           }
         else
           {
            // TRAIL_FIXED (and any distance-based mode added later)
            double fixed_pips = (InpTrailMode == TRAIL_FIXED ? g_trailDist : InpTrailDistPips);
            d = MathMax(1.0, fixed_pips);
           }
         raw_sl = buy ? (mkt - d * g_pip) : (mkt + d * g_pip);
        }

      double sl;
      if(FinalizeLevel(g_pos[i].symbol, g_pos[i].type, true, raw_sl, sl, true))
         if(IsBetterStop(g_pos[i].type, g_pos[i].sl, sl))
            TryModify(i, sl, g_pos[i].tp, "trailing");

      if(InpTrailMoveTpToo)
        {
         double raw_tp = buy ? (mkt + InpTrailTpDistPips * g_pip)
                             : (mkt - InpTrailTpDistPips * g_pip);
         double tp;
         if(FinalizeLevel(g_pos[i].symbol, g_pos[i].type, false, raw_tp, tp, true))
            if(g_pos[i].tp <= 0.0 || (buy ? (tp < g_pos[i].tp - g_point) : (tp > g_pos[i].tp + g_point)))
               TryModify(i, g_pos[i].sl, tp, "trailing TP");
        }
     }
  }
//+------------------------------------------------------------------+
//| Group money target / money stop                                    |
//+------------------------------------------------------------------+
void CheckMoneyExits()
  {
   if(!UseMoney())
      return;
   double pl  = GroupNetMoney();
   double tgt = RealMoney(InpBasketTakeMoney);
   double stp = RealMoney(InpBasketStopMoney);
   if(tgt > 0 && pl >= tgt)
     {
      Log(StringFormat("group take-profit reached: %.2f >= %.2f", pl, tgt));
      CloseGroup(CLOSE_ALL, "basket take " + DoubleToString(pl, 2));
     }
   else
      if(stp > 0 && pl <= -stp)
        {
         Log(StringFormat("group money-stop reached: %.2f <= -%.2f", pl, stp));
         CloseGroup(CLOSE_ALL, "basket money stop");
        }
  }
//+------------------------------------------------------------------+
void CheckKillSwitch()
  {
   if(!UseKill() || g_killed)
      return;
   double eq = AcctEq();
   if(eq <= 0.0)
      return;
   double loss = -GroupNetMoney();
   if(loss < eq * InpMaxDrawdownPctEquity / 100.0)
      return;
   g_killed = true;
   g_warn = StringFormat("KILL SWITCH: floating loss %.2f >= %.2f%% equity", loss, InpMaxDrawdownPctEquity);
   Log(g_warn);
   if(InpCloseAllOnKill)
      CloseGroup(CLOSE_ALL, "KILL SWITCH");
   Notify(g_warn + " - EA disabled, re-enable manually.");
  }
//+------------------------------------------------------------------+
//| Close part of the group (percent of total volume)                 |
//+------------------------------------------------------------------+
void ClosePartialGroup(double pct, string reason)
  {
   if(pct <= 0.0)
      return;
   int n = ArraySize(g_pos);
   if(n == 0)
      return;
   double total = 0;
   for(int i = 0; i < n; i++) total += g_pos[i].vol;
   if(total <= 0.0)
      return;
   double target = MathMin(total, total * pct / 100.0);
   if(target <= 0.0)
      return;
   for(int i = n - 1; i >= 0 && target > 0.0; i--)
     {
      double share = g_pos[i].vol * (target / total);
      double v = VolumeStepFloor(g_pos[i].symbol, share);
      double vmin = SymbolInfoDouble(g_pos[i].symbol, SYMBOL_VOLUME_MIN);
      double rest = g_pos[i].vol - v;
      if(v < vmin)
         continue;
      if(rest < vmin - 1e-8)
        {
         v = g_pos[i].vol;                    // remainder would be illegal -> close the ticket
         rest = 0.0;
        }
      if(DryOn())
        {
         Log(StringFormat("[dry] partial close #%s %.2f of %.2f lot", Tk(g_pos[i].ticket), v, g_pos[i].vol));
         target -= v;
         continue;
        }
      bool okp = (rest <= 0.0) ? g_trade.PositionClose(g_pos[i].ticket, (ulong)InpDeviationPoints)
                               : g_trade.PositionClosePartial(g_pos[i].ticket, v, (ulong)InpDeviationPoints);
      if(okp)
        {
         g_last_action = StringFormat("%s: closed %.2f lot of #%s", reason, v, Tk(g_pos[i].ticket));
         target -= v;
         g_dirty = true;
         SnapReset();
        }
      else
         PrintFormat("GoldBasketGuard: partial close failed #%s (%d)", Tk(g_pos[i].ticket), (int)g_trade.ResultRetcode());
     }
  }
//+------------------------------------------------------------------+
double VolumeStepFloor(string sym, double v)
  {
   double stp = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(stp <= 0.0)
      return v;
   return NormalizeDouble(MathFloor(v / stp + 1e-8) * stp, 8);
  }
//+------------------------------------------------------------------+
//| Close the group (or only losers / only winners)                   |
//+------------------------------------------------------------------+
void CloseGroup(int mode, string reason)
  {
   int n = ArraySize(g_pos);
   if(n == 0)
     {
      g_last_action = "group already flat";
      return;
     }
   int closed = 0, failed = 0;
   for(int i = n - 1; i >= 0; i--)
     {
      bool want = (mode == CLOSE_ALL);
      if(!want && mode == CLOSE_LOSING)  want = (g_pos[i].gain_money < 0.0);
      if(!want && mode == CLOSE_WINNING) want = (g_pos[i].gain_money > 0.0);
      if(!want)
         continue;
      if(DryOn())
        {
         Log("[dry] would close #" + Tk(g_pos[i].ticket));
         closed++;
         continue;
        }
      if(CloseSingle(g_pos[i].ticket, reason))
         closed++;
      else
         failed++;
     }
   g_last_action = StringFormat("%s: closed %d, failed %d", reason, closed, failed);
   Log(g_last_action);
   Notify(g_last_action);
   g_dirty = false;
   SnapReset();                          // the account numbers just moved
   CollectGroup();
   ComputeBasket();
   PanelUpdate();
  }
//---------------------------------------------------------------------
//| Send protection. A rejected request used to be repeated on every 100 ms|
//| cycle, for every ticket, with up to four OrderSend calls and a Sleep() in|
//| between - which is exactly how an EA ends up refused by the server or|
//| stopped by the terminal. Now a rejection is remembered, the same request|
//| waits (doubling, max 60 s), and a run of rejections pauses automatic|
//| sending for a while. Closing is never delayed and never fused: an|
//| unwanted position is more dangerous than a slow retry.           |
//---------------------------------------------------------------------
void ClampToPad(string sym, bool buy, double &sl, double &tp, int dg)
  {
   if(g_stop_pad <= 0 || (sl <= 0.0 && tp <= 0.0))
      return;
   double pad = (double)g_stop_pad * PointOf(sym);
   double bid = BidPx(sym);
   double ask = AskPx(sym);
   if(sl > 0.0)
      sl = buy ? MathMin(sl, bid - pad) : MathMax(sl, ask + pad);
   if(tp > 0.0)
      tp = buy ? MathMax(tp, ask + pad) : MathMin(tp, bid - pad);
   sl = NormalizeDouble(sl, dg);
   tp = NormalizeDouble(tp, dg);
  }
//+------------------------------------------------------------------+
int BoFind(const ulong tk)
  {
   for(int i = 0; i < g_bo_n; i++)
      if(g_bo_tk[i] == tk)
         return i;
   return -1;
  }
//---------------------------------------------------------------------
void BoDrop(const int i)
  {
   if(i < 0 || i >= g_bo_n)
      return;
   for(int k = i; k < g_bo_n - 1; k++)
     {
      g_bo_tk[k]    = g_bo_tk[k+1];
      g_bo_until[k] = g_bo_until[k+1];
      g_bo_sig[k]   = g_bo_sig[k+1];
      g_bo_fails[k] = g_bo_fails[k+1];
     }
   g_bo_n--;
  }
//---------------------------------------------------------------------
//| Is this exact request still in its cool-down? A different level for the|
//| same ticket, or a move that only tightens protection, never waits.|
//---------------------------------------------------------------------
bool BoHeld(const ulong tk, const string sig)
  {
   if(InpSendBackoffMs <= 0)
      return false;
   int i = BoFind(tk);
   if(i < 0 || g_bo_sig[i] != sig)
      return false;
   if(NowMs() >= g_bo_until[i])
     {
      BoDrop(i);
      return false;
     }
   return true;
  }
//---------------------------------------------------------------------
void BoHold(const ulong tk, const string sig)
  {
   int i = BoFind(tk);
   if(i < 0)
     {
      i = (g_bo_n < 16 ? g_bo_n : g_bo_n - 1);   // small rolling table on purpose
      g_bo_n = MathMin(16, g_bo_n + 1);
      g_bo_fails[i] = 0;
     }
   g_bo_tk[i]    = tk;
   g_bo_sig[i]   = sig;
   g_bo_fails[i]++;
   long ms = MathMax(InpSendBackoffMs, InpRetryDelayMs);
   for(int k = 1; k < g_bo_fails[i] && ms < 60000; k++)
      ms *= 2;
   g_bo_until[i] = NowMs() + MathMin(60000L, ms);
  }
//---------------------------------------------------------------------
void BoForget(const ulong tk)
  {
   int i = BoFind(tk);
   if(i >= 0)
      BoDrop(i);
  }
//---------------------------------------------------------------------
//| The fuse: a run of rejections means the server or the terminal is refusing|
//| us; pushing harder only gets the EA stopped. Automatic sends wait it out.|
//---------------------------------------------------------------------
bool FusePending()
  {
   return (g_fuse_until > 0 && NowMs() < g_fuse_until);
  }
//+------------------------------------------------------------------+
bool FuseOn()
  {
   if(g_fuse_until <= 0)
      return false;
   if(NowMs() >= g_fuse_until)
     {
      g_fuse_until = 0;
      g_fuse_step  = 0;
      g_last_action = "sending cooldown over - the EA sends again";
      Log(g_last_action);
      return false;
     }
   return true;
  }
//---------------------------------------------------------------------
void FuseTrip(const uint rc)
  {
   if(InpErrorFuseCount <= 0)
      return;
   g_fuse_cnt++;
   if(g_fuse_cnt < InpErrorFuseCount)
      return;
   g_fuse_cnt = 0;
   int secs   = 30 << g_fuse_step;
   if(secs > 300)
      secs = 300;
   g_fuse_step++;
   g_fuse_until = NowMs() + (long)secs * 1000;
   g_warn = StringFormat("%d requests in a row refused (last retcode %d) - automatic sending pauses %d s (closes still go out; APPLY overrides)",
                          InpErrorFuseCount, (int)rc, secs);
   Log(g_warn);
   Notify(g_warn);
  }
//+------------------------------------------------------------------+
//| The single point of truth: send SL/TP for one ticket              |
//+------------------------------------------------------------------+
bool TryModify(const int i, double sl_req, double tp_req, string reason)
  {
   if(i < 0 || i >= ArraySize(g_pos))
      return false;
   if(g_paused || g_killed)
      return false;

   string sym = g_pos[i].symbol;
   double pt  = PointOf(sym);
   double dlt = pt * MathMax(1, InpMinDeltaPoints) * 0.5;
   int    dg  = DigitsOf(sym);

   // widen the guard if this broker is stricter than its own STOPS_LEVEL suggests
   double sl = sl_req;
   double tp = tp_req;
   ClampToPad(sym, (g_pos[i].type == POSITION_TYPE_BUY), sl, tp, dg);

   bool sl_change = (MathAbs(sl - g_pos[i].sl) > dlt);
   bool tp_change = (MathAbs(tp - g_pos[i].tp) > dlt);
   if(!sl_change && !tp_change)
      return false;

   // a move that only tightens protection must never wait for the cool-down;
   // the cool-down exists to stop useless back-and-forth edits
   bool buy_side = (g_pos[i].type == POSITION_TYPE_BUY);
   bool protective = (g_pos[i].sl <= 0.0 ||
                      (buy_side ? (sl > g_pos[i].sl) : (sl < g_pos[i].sl)) ||
                      (g_pos[i].tp > 0.0 && (buy_side ? (tp < g_pos[i].tp) : (tp > g_pos[i].tp))));
   int    kk       = StFind(g_pos[i].ticket);
   bool   is_clear = (sl <= 0.0 && tp <= 0.0);
   if(!protective && kk >= 0 && StPendingLive(kk))
      return false;                    // our previous request for this ticket is in flight
   if(!protective && !is_clear && kk >= 0 && InpMinMsPerTicket > 0 &&
      NowMs() - (long)g_st[kk].seen_ms < InpMinMsPerTicket)
      return false;                    // anti-spam cool-down for this ticket

   double frz = (double)FreezeOf(sym) * pt;
   if(frz > 0.0)
     {
      double bid = BidPx(sym);
      double ask = AskPx(sym);
      bool   buy = (g_pos[i].type == POSITION_TYPE_BUY);
      if(g_pos[i].sl > 0.0 && MathAbs((buy ? bid - g_pos[i].sl : g_pos[i].sl - ask)) < frz)
        {
         g_warn = StringFormat("#%s inside broker freeze level (SL)", Tk(g_pos[i].ticket));
         return false;
        }
      if(g_pos[i].tp > 0.0 && MathAbs((buy ? g_pos[i].tp - ask : bid - g_pos[i].tp)) < frz)
        {
         g_warn = StringFormat("#%s inside broker freeze level (TP)", Tk(g_pos[i].ticket));
         return false;
        }
     }

   string sig = StringFormat("%s|%s|%s", DoubleToString(sl,dg), DoubleToString(tp,dg), reason);
   if(FuseOn() && !g_fuse_clear)
     {
      g_info_line = StringFormat("automatic sending on cooldown for %d s (%d requests refused in a row)",
                                 (int)((g_fuse_until - NowMs()) / 1000 + 1), InpErrorFuseCount);
      return false;
     }
   g_fuse_clear = false;               // a manual APPLY bought exactly one attempt
   if(!protective && BoHeld(g_pos[i].ticket, sig))
      return false;                     // this exact request was refused a moment ago

   if(!RateLimitOk())
      return false;

   if(DryOn())
     {
      Log(StringFormat("[dry] #%s %s SL %s -> %s | TP %s -> %s",
                       Tk(g_pos[i].ticket), reason,
                       DoubleToString(g_pos[i].sl, dg), DoubleToString(sl, dg),
                       DoubleToString(g_pos[i].tp, dg), DoubleToString(tp, dg)));
      g_pos[i].sl = sl;
      g_pos[i].tp = tp;
      StRemember(i);
      return true;
     }

   for(int r = 0; r <= InpRetryCount; r++)
     {
      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);
      req.action    = TRADE_ACTION_SLTP;
      req.position  = g_pos[i].ticket;
      req.symbol    = sym;
      req.sl        = sl;
      req.tp        = tp;
      req.deviation = (ulong)InpDeviationPoints;
      req.magic     = (InpMagicFilter > 0 ? (ulong)InpMagicFilter : 0);

      bool sent = OrderSend(req, res);
      uint rc   = res.retcode;
      if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL))
        {
         double old_sl = g_pos[i].sl;
         double old_tp = g_pos[i].tp;
         // take the level the server ACCEPTED (it can snap to the minimum distance):
         // memory then never disagrees with reality, so no correction loop can start
         double srv_sl = sl, srv_tp = tp;
         if(PositionSelectByTicket(g_pos[i].ticket))
           {
            srv_sl = PositionGetDouble(POSITION_SL);
            srv_tp = PositionGetDouble(POSITION_TP);
           }
         g_pos[i].sl = srv_sl;
         g_pos[i].tp = srv_tp;
         g_send_ok++;
         g_fuse_cnt = 0;                 // an accepted request ends the bad run
         BoForget(g_pos[i].ticket);
         SnapReset();                    // the server answered: equity and levels moved
         StRemember(i);
         if(MathAbs(srv_sl - sl) <= g_point * 0.5 && MathAbs(srv_tp - tp) <= g_point * 0.5)
            StMarkSent(i, sl, tp);      // wait for the echo of exactly this level
         if(InpVerboseLog)
            PrintFormat("GoldBasketGuard: #%s %s | SL %s -> %s | TP %s -> %s",
                        Tk(g_pos[i].ticket), reason,
                        DoubleToString(old_sl, dg), DoubleToString(sl, dg),
                        DoubleToString(old_tp, dg), DoubleToString(tp, dg));
         return true;
        }
      // A price that moved is retried at once, and retried with a FRESH price -
      // the old code slept 120 ms and sent the same stale level again.
      // "too many requests" and timeouts are not retried inside the cycle at all:
      // that is the one answer a server does not want, and it is how an EA gets
      // stopped. They wait for the next cycle, behind the cool-down below.
      bool reprice = (rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED ||
                      rc == TRADE_RETCODE_PRICE_OFF);
      if(r < InpRetryCount && reprice)
        {
         SnapRead();                     // new quotes, then clamp again
         ClampToPad(sym, (g_pos[i].type == POSITION_TYPE_BUY), sl, tp, dg);
         continue;
        }
      if(r < InpRetryCount && !sent)
        {
         Sleep(50);                      // the request never left: one short breather
         continue;
        }
      if(rc == TRADE_RETCODE_INVALID_STOPS && UseAdaptive())
        {
         int next = (g_stop_pad <= 0 ? MathMax(10, InpMinStopsPoints) : g_stop_pad * 2);
         if(next > InpAdaptiveStopsCapPoints)
            next = InpAdaptiveStopsCapPoints;
         if(next != g_stop_pad)
           {
            g_stop_pad = next;
            g_warn = StringFormat("broker rejected the level -> stop guard widened to %d pt", g_stop_pad);
            Log(g_warn);
            if(r < InpRetryCount)
               continue;                    // retry with the wider guard
           }
        }
      g_warn = StringFormat("#%s modify rejected: retcode %d", Tk(g_pos[i].ticket), (int)rc);
      Print("GoldBasketGuard: " + g_warn + " (sl=" + DoubleToString(sl, dg) +
            " tp=" + DoubleToString(tp, dg) + ")");
      g_send_fail++;
      BoHold(g_pos[i].ticket, sig);       // the same level will not be pushed again for a while
      FuseTrip(rc);
      break;
     }
   return false;
  }
//+------------------------------------------------------------------+
//| Per-ticket memory (used for mirroring and one-shot flags)         |
//+------------------------------------------------------------------+
int StFind(ulong t)
  {
   for(int i = 0; i < ArraySize(g_st); i++)
      if(g_st[i].ticket == t)
         return i;
   return -1;
  }
//+------------------------------------------------------------------+
void StRemember(const int i)
  {
   ulong t = g_pos[i].ticket;
   int   k = StFind(t);
   if(k < 0)
     {
      k = ArraySize(g_st);
      ArrayResize(g_st, k + 1);
      g_st[k].ticket  = t;
      g_st[k].be_done = false;
      g_st[k].seq     = 0;
     }
   g_st[k].sl       = g_pos[i].sl;
   g_st[k].tp       = g_pos[i].tp;
   g_st[k].seen     = TimeCurrent();
   g_st[k].seen_ms  = NowMs();
   g_st[k].seq      = g_apply_seq;
   g_st[k].pending  = false;      // our memory now equals what the server has
  }
//+------------------------------------------------------------------+
long NowMs()
  {
   return (long)GetTickCount64();
  }
//+------------------------------------------------------------------+
//| Remember exactly what we asked the server for: its echo is then   //|
//| recognised by value, not by guessing how long a modify may take   //|
//+------------------------------------------------------------------+
void StMarkSent(const int i, const double sl, const double tp)
  {
   int k = StFind(g_pos[i].ticket);
   if(k < 0)
      StRemember(i);
   k = StFind(g_pos[i].ticket);
   if(k < 0)
      return;
   g_st[k].req_sl  = sl;
   g_st[k].req_tp  = tp;
   g_st[k].req_ms  = NowMs();
   g_st[k].pending = true;
  }
//+------------------------------------------------------------------+
//| Does the live value of ticket i equal exactly what we asked for?  //|
//+------------------------------------------------------------------+
bool IsOurEcho(const int i, const int k, const double pt)
  {
   if(k < 0 || k >= ArraySize(g_st) || !g_st[k].pending)
      return false;
   double dsl = MathAbs(g_pos[i].sl - g_st[k].req_sl);
   double dtp = MathAbs(g_pos[i].tp - g_st[k].req_tp);
   return (dsl <= pt && dtp <= pt);
  }
//+------------------------------------------------------------------+
//| True while one of our requests is still in flight for this slot   //|
//+------------------------------------------------------------------+
bool StPendingLive(const int k)
  {
   if(k < 0 || k >= ArraySize(g_st) || !g_st[k].pending)
      return false;
   if(NowMs() - (long)g_st[k].req_ms > MathMax(500, 4 * InpMirrorGuardMs))
     {
      g_st[k].pending = false;      // the echo never arrived: stop blocking the ticket
      return false;
     }
   return true;
  }
//+------------------------------------------------------------------+
void PruneStickers()
  {
   for(int k = ArraySize(g_st) - 1; k >= 0; k--)
     {
      bool alive = false;
      for(int i = 0; i < ArraySize(g_pos); i++)
         if(g_pos[i].ticket == g_st[k].ticket)
           { alive = true; break; }
      if(alive)
         continue;
      int last = ArraySize(g_st) - 1;
      if(k != last)
         g_st[k] = g_st[last];        // whole struct: nothing can be forgotten
      ArrayResize(g_st, last);
     }
  }
//+------------------------------------------------------------------+
//| Rate limiting of modification requests                            |
//+------------------------------------------------------------------+
void TouchRateWindow()
  {
   long sec = (long)(GetTickCount() / 1000);
   if(sec != g_sec_stamp)
     {
      g_sec_stamp    = sec;
      g_mod_this_sec = 0;
     }
  }
//+------------------------------------------------------------------+
bool RateLimitOk()
  {
   TouchRateWindow();
   if(InpMaxModsPerSecond > 0 && g_mod_this_sec >= InpMaxModsPerSecond)
     {
      g_warn = "rate limit hit - modification deferred to next cycle";
      return false;
     }
   g_mod_this_sec++;
   return true;
  }
//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+
string Tk(ulong t)
  {
   return IntegerToString((long)t);
  }
//+------------------------------------------------------------------+
void Log(string msg)
  {
   if(!InpVerboseLog)
      return;
   Print("GoldBasketGuard: " + msg);
  }
//+------------------------------------------------------------------+
//| The tester flag never changes while the EA lives: read it        |
//| once in OnInit, not once per guard                               |
//+------------------------------------------------------------------+
bool InTester()
  {
   return g_is_tester;
  }
bool IsVisual()
  {
   return (MQLInfoInteger(MQL_VISUAL_MODE) != 0);
  }
//+------------------------------------------------------------------+
string MoneyStr(double v)
  {
   return DoubleToString(v, 2);
  }
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Chart panel                                                       |//---------------------------------------------------------------------
//| One frame for every object on the card: top-left corner, sized, never|
//| clickable, absent from the object list. The four writers below used to|
//| repeat these nine lines each.                                    |
//---------------------------------------------------------------------
void ObjFrame(string n,const int dx,const int dy,const int w,const int h,const int z)
  {
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,dx);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,dy);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,n,OBJPROP_ZORDER,z);
  }
//---------------------------------------------------------------------
void ORect(string name,int dx,int dy,int w,int h)
  {
   string n = GBG + name;
   if(ObjectFind(0,n) < 0)
      ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjFrame(n,dx,dy,w,h,0);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,InpClrPanelBg);
   ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,n,OBJPROP_COLOR,InpClrAccent);
   ObjectSetInteger(0,n,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,n,OBJPROP_BACK,false);
  }
//---------------------------------------------------------------------
//| A label. Its place never moves while the EA lives - changing the panel|
//| inputs re-inits it, which recreates the objects - so the skip check only|
//| has to look at text and colour.                                  |
//---------------------------------------------------------------------
void OLabel(string name,int dx,int dy,string txt,color clr,int fs)
  {
   string n = GBG + name;
   if(ObjectFind(0,n) < 0)
      ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   else if(ObjectGetString(0,n,OBJPROP_TEXT) == txt && (color)ObjectGetInteger(0,n,OBJPROP_COLOR) == clr)
      return;                       // identical: no writes, no flicker
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,dx);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,dy);
   ObjectSetInteger(0,n,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);
   ObjectSetInteger(0,n,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,n,OBJPROP_BACK,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,n,OBJPROP_ZORDER,1);
   ObjectSetString(0,n,OBJPROP_FONT,"Arial");
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
   g_obj_dirty = true;
  }
//---------------------------------------------------------------------
void OButton(string name,int dx,int dy,int w,int h,string txt,string tip)
  {
   string n = GBG + "BTN_" + name;
   if(ObjectFind(0,n) < 0)
      ObjectCreate(0,n,OBJ_BUTTON,0,0,0);
   ObjFrame(n,dx,dy,w,h,2);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,InpFontSize);
   ObjectSetInteger(0,n,OBJPROP_COLOR,InpClrText);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,C'40,48,62');
   ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR,C'70,80,100');
   ObjectSetInteger(0,n,OBJPROP_STATE,false);
   ObjectSetString(0,n,OBJPROP_FONT,"Arial");
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
   ObjectSetString(0,n,OBJPROP_TOOLTIP,tip);
  }
//---------------------------------------------------------------------
void OEdit(string name,int dx,int dy,int w,int h,string txt,string tip)
  {
   string n = GBG + "EDIT_" + name;
   if(ObjectFind(0,n) < 0)
      ObjectCreate(0,n,OBJ_EDIT,0,0,0);
   ObjFrame(n,dx,dy,w,h,2);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,InpFontSize);
   ObjectSetInteger(0,n,OBJPROP_COLOR,InpClrAccent);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,C'12,16,22');
   ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR,C'90,100,120');
   ObjectSetInteger(0,n,OBJPROP_ALIGN,ALIGN_CENTER);
   ObjectSetInteger(0,n,OBJPROP_READONLY,false);
   ObjectSetString(0,n,OBJPROP_FONT,"Consolas");
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
   ObjectSetString(0,n,OBJPROP_TOOLTIP,tip);
  }
//+------------------------------------------------------------------+
string EditGet(string fullname)
  {
   return ObjectGetString(0,fullname,OBJPROP_TEXT);
  }
//+------------------------------------------------------------------+
void EditSet(string name,string txt)
  {
   string n = GBG + "EDIT_" + name;
   if(ObjectFind(0,n) >= 0)
      ObjectSetString(0,n,OBJPROP_TEXT,txt);
  }
//+------------------------------------------------------------------+
//| Eight lines, two numbers, four buttons: the panel reports and lets you|
//| override - the rules themselves live in the Inputs, so there is nothing|
//| here to press before the EA starts working.                      |
//+------------------------------------------------------------------+
int PanelRows()
  {
   return 8;
  }
//+------------------------------------------------------------------+
int PanelH()
  {
   return (42 + PanelRows() * 14 + 6 + 18 + 6 + 22 + 6);
  }
//+------------------------------------------------------------------+
void PanelCreate()
  {
   int x = InpPanelX, y = InpPanelY;
   int w = 430, rows = PanelRows(), rowh = 14, bh = 22, gap = 4;
   ORect("BG",x,y,w,PanelH());
   OLabel("TITLE",x+10,y+7,"GOLD BASKET GUARD",InpClrAccent,10);
   OLabel("SUB",  x+10,y+24,_Symbol + " | pip " + DoubleToString(g_pip/g_point,0) + " pt" +
          " | " + (DryOn() ? "DRY RUN" : (UseAutoApply() ? "auto" : "manual")) +
          (g_cent ? " | cent" : ""),InpClrText,InpFontSize);
   for(int i = 0; i < rows; i++)
      OLabel("L" + IntegerToString(i),x+10,y+42+i*rowh,"",InpClrText,InpFontSize);
   int ey = y + 42 + rows*rowh + 6;
   OLabel("K1",x+10,ey+3,"SL pips",InpClrText,InpFontSize);
   OEdit ( "SL",x+62,ey,56,18,DoubleToString(g_slPips,1),
           "Group stop distance in pips. 0 = do not touch SL. Enter applies it when AUTO is on");
   OLabel("K2",x+128,ey+3,"TP pips",InpClrText,InpFontSize);
   OEdit ( "TP",x+180,ey,56,18,DoubleToString(g_tpPips,1),
           "Group take-profit distance in pips. 0 = do not touch TP");
   OLabel("K3",x+248,ey+3,"keys 1-9, 0, [, ]",InpClrText,InpFontSize);
   int by = ey + 24;
   OButton("APPLY",   x+8,            by,102,bh,"APPLY TP+SL",
           "Send the group levels now. Normally never needed: the EA keeps them glued by itself");
   OButton("PAUSE",   x+8+(102+gap),  by,102,bh,
           (g_paused || g_killed) ? "RESUME" : "PAUSE / RUN",
           "Stop / resume every automatic action. The readout keeps working");
   OButton("UNLOCK",  x+8+2*(102+gap),by,102,bh,"UNLOCK",
           "Clear the lockout or the breaker lock and run again");
   OButton("CLOSEALL",x+8+3*(102+gap),by,102,bh,"CLOSE ALL",
           "Close every ticket of the group - press twice within 6 seconds");
   ObjectSetString(0,GBG + "BG",OBJPROP_TOOLTIP,
                   "1 apply  2 SL  3 TP  4 risk-free now  5 trail  6 news  7 unlock  8 alerts  9 close all  0 pause  - clear SL/TP  [ reset");
   PanelForgetRows();
   g_panel_force = true;                // fresh objects hold no text yet
   ChartRedraw();
  }
//+------------------------------------------------------------------+
void PanelSyncEdits()
  {
   if(!InpShowPanel)
      return;
   EditSet("SL",DoubleToString(g_slPips,1));
   EditSet("TP",DoubleToString(g_tpPips,1));
  }
//+------------------------------------------------------------------+
void PanelDelete()
  {
   ObjectsDeleteAll(0,GBG,-1,-1);
   ChartRedraw();
  }
//+------------------------------------------------------------------+
//| Two fields, read once, and they never fight the Inputs: what you type is|
//| kept for this chart and re-applied from here on.                 |
//+------------------------------------------------------------------+
void ReadEdits()
  {
   if(!InpShowPanel)
      return;
   string a = GBG + "EDIT_SL", b = GBG + "EDIT_TP";
   double new_sl = (ObjectFind(0,a) >= 0) ? MathMax(0.0,StringToDouble(EditGet(a))) : g_slPips;
   double new_tp = (ObjectFind(0,b) >= 0) ? MathMax(0.0,StringToDouble(EditGet(b))) : g_tpPips;
   if(ObjectFind(0,a) >= 0 && MathAbs(new_sl - g_slPips) > 1e-9)
     {
      g_slPips = new_sl;
      g_absSl  = 0.0;                 // an explicit distance wins over an absolute price
     }
   if(ObjectFind(0,b) >= 0 && MathAbs(new_tp - g_tpPips) > 1e-9)
     {
      g_tpPips = new_tp;
      g_absTp  = 0.0;
     }
   g_fuse_clear  = true;               // what the trader asks for is never held back
   g_dirty       = true;               // ... and it is worth applying at once
   UiSave();
  }
//+------------------------------------------------------------------+
//| A fingerprint of everything the panel shows. Building the 12 rows |
//| costs more than comparing this, so compare first                 |
//+------------------------------------------------------------------+
long StrHash(const string s)
  {
   long h = 0;
   int  l = StringLen(s);
   for(int i = 0; i < l; i++)
      h = h * 31 + StringGetCharacter(s, i);
   return h;
  }
//+------------------------------------------------------------------+
long PanelSig()
  {
   int n = ArraySize(g_pos);
   long s = (long)n * 1000003;
   s = s * 131 + (long)MathRound(g_basket.vol_total * 1000.0);
   s = s * 131 + (long)MathRound(g_slPips * 10.0);
   s = s * 131 + (long)MathRound(g_tpPips * 10.0);
   s = s * 131 + (long)MathRound(g_beTrigger * 10.0);
   s = s * 131 + (long)MathRound(g_beLock * 10.0);
   s = s * 131 + (long)MathRound(g_trailDist * 10.0);
   s = s * 131 + (long)MathRound(g_absSl * 100.0);
   s = s * 131 + (long)MathRound(g_absTp * 100.0);
   s = s * 131 + (long)g_be_done_count * 3 + (long)g_be_partial_done;
   s = s * 131 + (g_trailOn ? 1 : 0) + (g_news_enabled ? 2 : 0) + (g_paused ? 4 : 0)
       + (g_killed ? 8 : 0) + (g_alerts_on ? 16 : 0) + (DryOn() ? 64 : 0)
       + (g_news_active ? 128 : 0) + (g_news_calendar ? 256 : 0);
   s = s * 131 + (long)MathRound(g_risk_pct * 10.0) * 977
       + (long)MathRound(g_risk_money * 100.0) + g_news_errno * 13 + g_stop_pad * 7
       + (long)g_lockout_until / 60 + g_last_ms / 5 * 3 + g_slow_ms / 5
       + g_send_ok * 31 + g_send_fail * 53 + g_timer_ms
       + (FusePending() ? (long)((g_fuse_until - NowMs()) / 1000) : 0);
   s = s * 131 + 3 * StrHash(g_last_action) + 11 * StrHash(g_warn)
       + 17 * StrHash(g_info_line) + 23 * StrHash(g_news_desc);
   if(n > 0)                                   // market-sensitive rows only matter with tickets
     {
      s = s * 131 + (long)MathRound(GroupNetMoney() * 100.0);
      s = s * 131 + (long)MathRound(g_basket.avg_buy * 100.0) + (long)MathRound(g_basket.avg_sell * 100.0);
      s = s * 131 + (long)MathRound(g_basket.gain_pips_buy * 10.0) + (long)MathRound(g_basket.gain_pips_sell * 10.0);
      s = s * 131 + (long)MathRound(g_basket.swap * 100.0);
     }
   else
      s = s * 131 + (long)MathRound(AcctEq() * 100.0) + (long)MathRound(AcctMarginLevel()) * 13;
   s = s * 131 + (long)(NowMs() / 1000) % 997;   // the timing row ages once a second
   return s;
  }
//+------------------------------------------------------------------+
//| One panel row. The cache in front of it is what keeps a quiet      |
//| chart at zero object writes instead of 12 labels per repaint.      |
//+------------------------------------------------------------------+
void RowSet(const int i, string txt, color clr)
  {
   if(i < 0 || i >= 14)
      return;
   if(g_row_known[i] && g_row_txt[i] == txt && g_row_clr[i] == clr)
      return;
   g_row_known[i] = true;
   g_row_txt[i] = txt;
   g_row_clr[i] = clr;
   OLabel("L" + IntegerToString(i),InpPanelX+10,InpPanelY+42+i*14,txt,clr,InpFontSize);
  }
//+------------------------------------------------------------------+
void PanelForgetRows()
  {
   for(int i = 0; i < 14; i++)
      g_row_known[i] = false;              // fresh objects hold no text yet
  }
//+------------------------------------------------------------------+
void PanelForce()
  {
   g_panel_ms = 0;
   g_panel_force = true;
  }
//+------------------------------------------------------------------+
//| Button caption, written only when the text really changed          |
//+------------------------------------------------------------------+
void BtnText(string name, string txt)
  {
   string o = GBG + "BTN_" + name;
   if(ObjectGetString(0,o,OBJPROP_TEXT) != txt)
     {
      ObjectSetString(0,o,OBJPROP_TEXT,txt);
      g_obj_dirty = true;
     }
  }
//+------------------------------------------------------------------+
//| The panel lines. Everything the rows show is already computed in this|
//| cycle; a fingerprint of them (PanelSig) decides whether anything is|
//| written at all, so a chart where nothing moved costs no object calls.|
//+------------------------------------------------------------------+
void PanelUpdate()
  {
   if(!InpShowPanel || InTester() && !IsVisual())
      return;
   if(InpPanelRefreshMs > 0 && NowMs() - (long)g_panel_ms < InpPanelRefreshMs)
      return;                          // repaint at most every N ms; the loop is faster
   g_panel_ms = NowMs();
   if(ObjectFind(0,GBG + "BG") < 0)
     {
      PanelCreate();
      return;
     }
   long sig = PanelSig();
   if(!g_panel_force && sig == g_panel_sig)
      return;                          // nothing changed: no formatting, no writes, no redraw
   g_panel_sig = sig;
   g_panel_force = false;
   int    n = ArraySize(g_pos);
   double pl = GroupNetMoney();
   color  c  = (pl >= 0.0 ? InpClrOk : clrIndianRed);
   string s[8];
   s[0] = StringFormat("group: %d (%d buy / %d sell)  vol %.2f lot  |  %s%s",
                        n, g_basket.cnt_buy, g_basket.cnt_sell, g_basket.vol_total,
                        g_acct_ccy, g_cent ? " (cent)" : "");
   s[1] = StringFormat("avg BUY %s (%+.1f p)  |  avg SELL %s (%+.1f p)",
                        (g_basket.avg_buy  > 0.0 ? DoubleToString(g_basket.avg_buy,g_digits)  : "-"),
                        g_basket.gain_pips_buy,
                        (g_basket.avg_sell > 0.0 ? DoubleToString(g_basket.avg_sell,g_digits) : "-"),
                        g_basket.gain_pips_sell);
   s[2] = StringFormat("basket P/L %s  (swap %s)  |  equity %s",
                        MoneyStr(pl), MoneyStr(g_basket.swap), MoneyStr(AcctEq()));
   s[3] = StringFormat("risk at SL %s (%.2f%% bal) = %.1f pips  |  %s/pip",
                        MoneyStr(g_risk_money),
                        AcctBal() > 0.0 ? g_risk_money / AcctBal() * 100.0 : 0.0,
                        g_slPips, MoneyStr(GroupMoneyPerPip()));
   s[4] = StringFormat("SL %.1f p -> %s  |  TP %.1f p -> %s  |  stops %d pt (+%d)",
                        g_slPips, LevelHint(true), g_tpPips, LevelHint(false),
                        StopsOf(_Symbol), g_stop_pad);
   s[5] = StringFormat("risk-free %s (arm %.0f, lock %.0f, done %d)  |  trail %s  |  news %s",
                        UseRiskFree() ? "ON" : "off", g_beTrigger, g_beLock, g_be_done_count,
                        g_trailOn ? "ON" : "OFF",
                        (!g_news_enabled ? "off" : (g_news_active ? "ACTIVE" : "armed")));
   s[6] = StringFormat("margin %.0f%%  free %s  |  float -%.1f%% bal  |  day %s",
                        AcctMarginLevel(), MoneyStr(AcctFreeMargin()), g_risk_pct, MoneyStr(DayPnl()));
   if(g_paused || g_killed || g_lockout_until > 0 || FusePending() ||
      StringLen(g_warn) > 0 || StringLen(g_info_line) > 0)
     {
      string st = (g_killed  ? "KILL/LOCK ACTIVE - UNLOCK (key 7) to resume"
                              : (g_paused ? "PAUSED - nothing is sent, key 0 or PAUSE resumes" : ""))
                  + (StringLen(g_warn) > 0 ? " " + g_warn : "")
                  + (StringLen(g_info_line) > 0 ? " " + g_info_line : "");
      if(FusePending())
         st = st + StringFormat(" [sending cooldown %d s]", (int)((g_fuse_until - NowMs()) / 1000 + 1));
      if(g_news_errno != 0)
         st = st + StringFormat(" [calendar err %d]", g_news_errno);
      s[7] = st;
      RowSet(7,s[7],InpClrWarn);
     }
   else
     {
      // the loop period shown is the one actually in force, so the idle back-off is visible
      string cad = (InpTimerMs > 0 && !InTester()) ? StringFormat("loop %d ms", g_timer_ms)
                                                   : "loop OnTick only";
      s[7] = (n == 0 ? StringFormat("%s | waiting for the group  |  act: %s", cad, g_last_action)
                      : StringFormat("%s | cycle %d ms (max %d) | sent %d, refused %d | %s",
                                     cad, g_last_ms, g_slow_ms, g_send_ok, g_send_fail, g_last_action));
      RowSet(7,s[7],InpClrText);
     }
   for(int i = 0; i < 7; i++)
      RowSet(i,s[i],(i == 2 ? c : (i == 5 && g_news_active ? InpClrWarn : InpClrText)));
   BtnText("PAUSE",(g_paused || g_killed) ? "RESUME" : "PAUSE / RUN");
   if(g_obj_dirty)
     {
      g_obj_dirty = false;
      ChartRedraw();
     }
  }
//+------------------------------------------------------------------+
string LevelHint(bool is_sl)
  {
   int n = ArraySize(g_pos);
   if(n == 0)
      return "-";
   double d = (is_sl ? g_slPips : g_tpPips);
   if(is_sl && g_mirrorSlPrice > 0)  return DoubleToString(g_mirrorSlPrice,g_digits);
   if(!is_sl && g_mirrorTpPrice > 0) return DoubleToString(g_mirrorTpPrice,g_digits);
   if(is_sl && g_absSl > 0)          return DoubleToString(g_absSl,g_digits);
   if(!is_sl && g_absTp > 0)         return DoubleToString(g_absTp,g_digits);
   if(d <= 0.0)
      return "off";
   bool buy = (g_pos[0].type == POSITION_TYPE_BUY);
   double anch = AnchorPrice(0,(int)InpApplyMode);
   double lvl  = (is_sl ? (buy ? anch - d*g_pip : anch + d*g_pip)
                        : (buy ? anch + d*g_pip : anch - d*g_pip));
   return DoubleToString(lvl,g_digits);
  }
//+------------------------------------------------------------------+
//| Money units: cent / dollar / any broker currency                  |
//+------------------------------------------------------------------+
void DetectAccountUnits()
  {
   g_acct_ccy = AccountInfoString(ACCOUNT_CURRENCY);
   string up  = g_acct_ccy;
   StringToUpper(up);
   g_cent = (up == "USC" || up == "EUC" || up == "GBC" || up == "RUC" ||
             up == "AUC" || up == "JYC" || up == "CHC" || up == "BRC" ||
             StringFind(up, "CENT") >= 0);

   double div = MathMax(1.0, InpCentDivisor);
   switch(InpMoneyBasis)
     {
      case MONEY_ACCOUNT_CCY:                              // typed values are cents / account units
         g_money_factor = 1.0;
         break;
      case MONEY_REAL_USD:                                 // typed values are always real account money
         g_money_factor = div;
         break;
      default:                                             // MONEY_AUTO
         g_money_factor = (g_cent ? div : 1.0);
         break;
     }
  }
//+------------------------------------------------------------------+
double RealMoney(const double v)
  {
   return v * g_money_factor;
  }
//+------------------------------------------------------------------+
//| Account currency value of 1 pip for 1.0 lot                       |
//+------------------------------------------------------------------+
double MoneyPerPipPerLot(string sym)
  {
   if(sym == g_a_mpp_sym && g_a_mpp_lot >= 0.0)
      return g_a_mpp_lot;            // once per snapshot: this is three accessor calls
   double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   if(tv <= 0.0)
      tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0.0)
      tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_PROFIT);
   double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0.0)
      ts = g_point;
   if(tv <= 0.0 || ts <= 0.0)
      return 0.0;
   g_a_mpp_sym = sym;
   g_a_mpp_lot = (g_pip / ts) * tv;
   return g_a_mpp_lot;
  }
//+------------------------------------------------------------------+
double GroupMoneyPerPip()
  {
   double mpp = g_basket.vol_total * MoneyPerPipPerLot(_Symbol);
   g_money_per_pip = mpp;
   return mpp;
  }
//+------------------------------------------------------------------+
//| Risk sizing: turn "% of balance I am ready to lose" into group SL |
//+------------------------------------------------------------------+
void ApplyRiskSizing()
  {
   double old_sl = g_slPips;
   double old_tp = g_tpPips;
   double mpp = GroupMoneyPerPip();
   if(mpp <= 0.0)
     {
      g_risk_money = 0.0;
      return;
     }

   double bal = AcctBal();
   if(bal <= 0.0)
      return;

   if(!UseSizing())
     {
      g_risk_money = g_slPips * mpp;                       // report only
      return;
     }
   if(g_absSl > 0.0)
     {
      g_risk_money = g_slPips * mpp;                        // a manual level wins, just report
      return;
     }

   double risk_money = bal * InpRiskPctPerBasket / 100.0;
   double pips       = risk_money / mpp;
   if(InpRiskCapPips > 0.0 && pips > InpRiskCapPips)
      pips = InpRiskCapPips;
   if(InpRiskFloorPips > 0.0 && pips < InpRiskFloorPips)
      pips = InpRiskFloorPips;

   g_slPips     = pips;
   g_risk_money = pips * mpp;
   if(InpRiskRewardRatio > 0.0)
      g_tpPips = pips * InpRiskRewardRatio;

   // only touch the edit boxes when the number really moved, so a half-typed value is not eaten
   if(MathAbs(g_slPips - old_sl) > 0.1)
      EditSet("SL", DoubleToString(g_slPips, 1));
   if(InpRiskRewardRatio > 0.0 && MathAbs(g_tpPips - old_tp) > 0.1)
      EditSet("TP", DoubleToString(g_tpPips, 1));
  }
//+------------------------------------------------------------------+
//| Global-variable anchors so that restarts cannot bypass the guards |
//+------------------------------------------------------------------+
void InitAnchors()
  {
   g_gv_prefix = StringFormat("GBG_%s_%s_", IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)), _Symbol);
   g_peak_equity = GVGet("PEAK", AccountInfoDouble(ACCOUNT_EQUITY));
   g_day         = (int)(ServerNow() / 86400);
   int  saved_day = (int)GVGet("DAY", -1);
   g_day_bal      = GVGet("DAYBAL", AccountInfoDouble(ACCOUNT_BALANCE));
   g_lockout_until= (datetime)GVGet("LOCK", 0);
   if(saved_day != g_day)
      NewTradingDay();
  }
//+------------------------------------------------------------------+
void NewTradingDay()
  {
   g_day = (int)(ServerNow() / 86400);
   g_day_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   GVSet("DAY", (double)g_day);
   GVSet("DAYBAL", g_day_bal);
   if(g_lockout_until > 0 && g_lockout_until < ServerNow())
     {
      g_lockout_until = 0;
      g_paused = false;
      GVSet("LOCK", 0);
      Log("new trading day - lockout expired, EA resumed");
     }
  }
//+------------------------------------------------------------------+
double GVGet(string name, double def)
  {
   string n = g_gv_prefix + name;
   if(GlobalVariableCheck(n))
      return GlobalVariableGet(n);
   return def;
  }
//+------------------------------------------------------------------+
void GVSet(string name, double v)
  {
   GlobalVariableSet(g_gv_prefix + name, v);
  }
//+------------------------------------------------------------------+
datetime ServerNow()
  {
   if(g_a_fresh)
      return g_a_snow;                     // one clock per cycle, not one per guard
   datetime t = TimeTradeServer();
   if(t <= 0)
      t = TimeCurrent();
   return t;
  }
//+------------------------------------------------------------------+
//| The algo-trading switch, checked at most once a second            |
//+------------------------------------------------------------------+
bool TradeAllowedNow()
  {
   if(InTester())
      return true;
   long ms = NowMs();
   if(g_a_allowed_ms >= 0 && ms - g_a_allowed_ms < 1000)
      return g_a_allowed;
   g_a_allowed_ms = ms;
   g_a_allowed = (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0 &&
                  MQLInfoInteger(MQL_TRADE_ALLOWED) != 0);
   return g_a_allowed;
  }
//+------------------------------------------------------------------+
int SecsOfDay(datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   return d.hour * 3600 + d.min * 60 + d.sec;
  }
//+------------------------------------------------------------------+
double TodayCashFlow()
  {
   datetime now = ServerNow();
   datetime day0 = now - (now % 86400);
   if(!HistorySelect(day0, now + 60))
      return 0.0;
   double cash = 0.0;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong dt = HistoryDealGetTicket(i);
      if(dt == 0)
         continue;
      if((int)HistoryDealGetInteger(dt, DEAL_TYPE) == DEAL_TYPE_BALANCE)
         cash += HistoryDealGetDouble(dt, DEAL_PROFIT);
     }
   return cash;
  }
//+------------------------------------------------------------------+
//| P/L of the current trading day, floating included                |
//+------------------------------------------------------------------+
double DayPnl()
  {
   if(g_day_bal <= 0.0)
      return 0.0;
   static datetime last_calc = 0;
   static double   cached    = 0.0;
   datetime now = ServerNow();
   if(last_calc > 0 && (long)(now - last_calc) < 15)      // history queries are not free - 15s cache
      return cached;
   last_calc = now;
   cached    = AccountInfoDouble(ACCOUNT_EQUITY) - (g_day_bal + TodayCashFlow());
   return cached;
  }
//+------------------------------------------------------------------+
//| Economic calendar scan                                            |
//+------------------------------------------------------------------+
string DeriveCurrencies()
  {
   if(StringLen(InpNewsCurrencies) > 0)
      return InpNewsCurrencies;
   string s = _Symbol;
   StringToUpper(s);
   string out = "";
   if(StringFind(s, "USD") >= 0) out = "USD";
   else if(StringFind(s, "EUR") >= 0) out = "EUR";
   else if(StringFind(s, "GBP") >= 0) out = "GBP";
   else if(StringFind(s, "JPY") >= 0) out = "JPY";
   else if(StringFind(s, "AUD") >= 0) out = "AUD";
   else if(StringFind(s, "XAU") >= 0 || StringFind(s, "GOLD") >= 0) out = "USD";
   else if(StringLen(s) >= 6)
      out = StringSubstr(s, 0, 3) + "," + StringSubstr(s, 3, 3);
   if(out == "")
      out = "USD";
   return out;
  }
//+------------------------------------------------------------------+
bool InManualWindow(datetime now)
  {
   if(StringLen(InpNewsManualWindows) <= 0)
      return false;
   string parts[];
   int c = StringSplit(InpNewsManualWindows, ';', parts);
   int secs = SecsOfDay(now);
   MqlDateTime dt;
   TimeToStruct(now, dt);
   for(int i = 0; i < c; i++)
     {
      string w = parts[i];
      StringTrimLeft(w);
      StringTrimRight(w);
      if(StringLen(w) < 5)
         continue;
      string seg[];
      int    n   = StringSplit(w, '-', seg);
      int    dow = -1;
      int    base = 0;
      if(n == 3)
        {
         dow  = (int)StringToInteger(seg[0]);
         base = 1;
        }
      else
         if(n != 2)
            continue;
      if(dow >= 0 && dow != dt.day_of_week)
         continue;
      int    a = ToMinutes(seg[base]);
      int    b = ToMinutes(seg[base + 1]);
      if(a < 0 || b < 0)
         continue;                       // malformed segment - ignore it
      a *= 60;
      b *= 60;
      if(b < a)
        {
         if(secs >= a || secs <= b)
            return true;
        }
      else
         if(secs >= a && secs <= b)
            return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
int ToMinutes(string hm)
  {
   string t[];
   int n = StringSplit(hm, ':', t);
   if(n != 2)
      return -1;
   int h = (int)StringToInteger(t[0]);
   int m = (int)StringToInteger(t[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59)
      return -1;
   return h * 60 + m;
  }
//+------------------------------------------------------------------+
void NewsScan()
  {
   g_news_block_edits = false;
   if(!g_news_enabled)
     {
      g_news_desc = "news guard off";
      g_news_active = false;
      return;
     }

   datetime now = ServerNow();

   //--- cheap re-check between calendar polls
   if(g_news_scan_at > 0 && (long)(now - g_news_scan_at) < MathMax(5, InpNewsRefreshSec))
     {
      if(g_news_active && !g_news_manual && g_news_next_time > 0 &&
         (long)g_news_next_time + (long)InpNewsAfterMin * 60 < (long)now)
        {
         g_news_active = false;
         g_news_desc   = "clear (calendar)";
        }
      if(g_news_active)
         g_news_block_edits = InpNewsPauseAutomation;
      return;
     }
   g_news_scan_at = now;

   //--- manual windows are always honoured (they also work in the tester)
   if(InManualWindow(now))
     {
      g_news_active  = true;
      g_news_manual  = true;
      g_news_desc    = "manual window active: " + InpNewsManualWindows;
      g_news_next_time = now - (now % 86400);   // stable key -> the action fires once per day
      g_news_block_edits = InpNewsPauseAutomation;
      return;
     }
   g_news_manual = false;

   bool was_active = g_news_active;
   g_news_active   = false;
   g_news_next_time= 0;

   if(InTester())
     {
      g_news_calendar = false;
      g_news_desc = "calendar not available in tester - use InpNewsManualWindows";
      if(was_active)
         g_news_handled = 0;
      return;
     }

   int before = MathMax(0, InpNewsBeforeMin) * 60;
   int after  = MathMax(0, InpNewsAfterMin) * 60;
   int need   = (int)(InpNewsIncludeModerate ? CALENDAR_IMPORTANCE_MODERATE : InpNewsImportance);

   string list[];
   string ccy_src = DeriveCurrencies();
   int    ncc = StringSplit(ccy_src, ',', list);
   if(ncc <= 0)
      ncc = 0;

   int best = INT_MAX;
   string best_desc = "";
   int    found = 0;
   for(int ci = 0; ci < ncc; ci++)
     {
      string ccy = list[ci];
      StringTrimLeft(ccy);
      StringTrimRight(ccy);
      if(StringLen(ccy) < 3)
         continue;
      MqlCalendarValue vals[];
      ArrayFree(vals);
      ResetLastError();
      int cnt = CalendarValueHistory(vals, (datetime)(now - after), (datetime)(now + before + 120), NULL, ccy);
      g_news_errno = (cnt < 0 ? GetLastError() : 0);
      if(cnt < 0)
        {
         g_news_calendar = false;
         continue;
        }
      g_news_calendar = true;
      found += cnt;
      for(int i = 0; i < cnt; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(vals[i].event_id, ev))
            continue;
         if((int)ev.importance < need)
            continue;
         if(ev.type == CALENDAR_TYPE_HOLIDAY)
            continue;
         long dt = (long)vals[i].time - (long)now;         // < 0 -> already released
         if(dt > (long)before)
            continue;
         if(-dt > (long)after)
            continue;
         int key = (int)MathAbs(dt);
         if(key < best)
           {
            best = key;
            best_desc = StringFormat("%s %s @ %s (%s)", ccy, ev.name,
                                     TimeToString(vals[i].time, TIME_DATE | TIME_MINUTES),
                                     dt >= 0 ? StringFormat("in %d min", (int)(dt / 60)) : "released");
            g_news_next_time = vals[i].time;
           }
         g_news_active = true;
        }
     }

   if(g_news_active)
     {
      g_news_desc = best_desc;
      g_news_block_edits = InpNewsPauseAutomation;
      Log("RED NEWS window: " + best_desc);
     }
   else
      g_news_desc = StringFormat("clear (%d events checked, server time)", found);

   if(!was_active && g_news_active)
      g_news_handled = 0;
   if(!g_news_active)
      g_news_handled = 0;
  }
//+------------------------------------------------------------------+
//| The action part of the news guard                                 |
//+------------------------------------------------------------------+
void NewsGuard()
  {
   if(!g_news_enabled || !g_news_active)
      return;
   if(InpNewsAction == NEWS_WARN)
     {
      g_info_line = "NEWS: " + g_news_desc;
      return;
     }
   if(g_news_handled == g_news_next_time)
      return;                                  // already acted for this event
   g_news_handled = g_news_next_time;

   if(InpNewsTightenBeforeClose && InpNewsAction != NEWS_RISK_FREE)
      ApplyRiskFree(true);                      // lock whatever is lockable first

   if(InpNewsAction == NEWS_RISK_FREE)
     {
      g_last_action = "NEWS: group switched to risk-free - " + g_news_desc;
      return;
     }

   string why = "NEWS GUARD: " + g_news_desc;
   if(InpNewsAction == NEWS_CLOSE_GROUP)
      CloseGroup(CLOSE_ALL, why);
   else
      if(InpNewsAction == NEWS_CLOSE_LOSING)
         CloseGroup(CLOSE_LOSING, why);
      else
         if(InpNewsAction == NEWS_CLOSE_ACCOUNT)
            CloseAllPositions(why);
         else
            CloseGroup(CLOSE_ALL, why);         // NEWS_CLOSE_GROUP

   Notify(why);
  }
//+------------------------------------------------------------------+
//| Close everything on the account, ignoring the group filters       |
//+------------------------------------------------------------------+
int CloseAllPositions(string reason)
  {
   int total  = PositionsTotal();
   int closed = 0, failed = 0;
   for(int i = total - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(DryOn())
        {
         Log("[dry] would close #" + Tk(t) + " (account-wide)");
         closed++;
         continue;
        }
      bool done = g_trade.PositionClose(t, (ulong)InpDeviationPoints);
      if(done) closed++;
      else
        {
         failed++;
         PrintFormat("GoldBasketGuard: account-wide close failed for #%s (%d)", Tk(t), (int)g_trade.ResultRetcode());
        }
     }
   g_last_action = StringFormat("%s -> closed %d, failed %d", reason, closed, failed);
   Log(g_last_action);
   CollectGroup();
   ComputeBasket();
   return closed;
  }
//+------------------------------------------------------------------+
//| Read-only risk readout: warns early, closes and sends nothing    |
//+------------------------------------------------------------------+
void RiskWarning()
  {
   double bal = AcctBal();
   double eq  = AcctEq();
   g_risk_pct = (bal > 0.0 ? MathMax(0.0, (bal - eq) / bal * 100.0) : 0.0);
   if(!UseWarn() || bal <= 0.0)
      return;
   if(g_risk_pct < InpRiskWarnPct * 0.9)
     {
      g_risk_warned = false;                  // recovered: the alert may fire again
      return;
     }
   if(g_risk_pct < InpRiskWarnPct)
      return;
   if(!g_risk_warned)
     {
      g_risk_warned = true;
      g_warn = StringFormat("RISK WARNING (nothing was closed): floating loss %.1f%% of balance; all positions are closed only at %.0f%%",
                            g_risk_pct, (double)InpEmergencyFloatLossPct);
      Log(g_warn);
      Notify(g_warn);
     }
   else
      g_info_line = StringFormat("risk %.1f%% of balance (warn %.0f%%, close-all at %.0f%%)",
                                 g_risk_pct, InpRiskWarnPct, (double)InpEmergencyFloatLossPct);
  }

//| "60% of the account is at risk" - the hard circuit breaker        |
//+------------------------------------------------------------------+
void EmergencyGuard()
  {
   if(g_killed || !UseBreaker())
      return;

   double bal = AcctBal();
   double eq  = AcctEq();
   double ml  = AcctMarginLevel();
   double fm  = AcctFreeMargin();
   double fl  = eq - bal;                              // account-wide floating P/L

   if(eq > g_peak_equity)
     {
      g_peak_equity = eq;
      GVSet("PEAK", g_peak_equity);
     }

   if(g_day == 0)
      g_day = (int)(ServerNow() / 86400);
   if((int)(ServerNow() / 86400) != g_day)
      NewTradingDay();

   string why = "";
   if(InpEmergencyFloatLossPct > 0 && bal > 0 && fl <= -bal * InpEmergencyFloatLossPct / 100.0)
      why = StringFormat("floating loss %.2f = %.1f%% of balance", fl, -fl / bal * 100.0);

   if(StringLen(why) == 0 && InpEmergencyEquityDdPct > 0 && g_peak_equity > 0 &&
      eq < g_peak_equity * (1.0 - InpEmergencyEquityDdPct / 100.0))
      why = StringFormat("equity drawdown %.1f%% from peak %.2f",
                         (g_peak_equity - eq) / g_peak_equity * 100.0, g_peak_equity);

   if(StringLen(why) == 0 && InpEmergencyMarginLevelPct > 0 && ml > 0 && ml <= (double)InpEmergencyMarginLevelPct)
      why = StringFormat("margin level %.1f%%", ml);

   if(StringLen(why) == 0 && InpEmergencyFreeMarginPct > 0 && eq > 0 && fm <= eq * InpEmergencyFreeMarginPct / 100.0)
      why = StringFormat("free margin %.1f%% of equity", fm / eq * 100.0);

   if(StringLen(why) == 0)
      return;

   bool must_nuke = (ml > 0 && ml < 110.0) || (fm <= 0.0);      // stop-out is at the door

   if(InpEmergencyStepDown && !must_nuke && ArraySize(g_pos) > 0 && !DryOn())
     {
      int    worst = -1;
      double best_loss = 0.0;
      for(int i = 0; i < ArraySize(g_pos); i++)
         if(g_pos[i].gain_money < best_loss)
           { best_loss = g_pos[i].gain_money; worst = i; }
      if(worst >= 0)
        {
         g_warn = "STEP-DOWN: " + why;
         Log(g_warn);
         CloseSingle(g_pos[worst].ticket, "emergency step-down");
         return;
        }
     }

   g_killed = true;
   g_warn   = "ACCOUNT AT RISK - " + why;
   Log(g_warn);
   CloseAllPositions("EMERGENCY: " + why);
   if(InpEmergencyLockHours > 0)
     {
      g_lockout_until = ServerNow() + (datetime)(InpEmergencyLockHours * 3600);
      GVSet("LOCK", (double)g_lockout_until);
     }
   g_paused = true;
   Notify(g_warn + " - everything closed, EA locked");
  }
//+------------------------------------------------------------------+
bool CloseSingle(ulong ticket, string reason)
  {
   if(DryOn())
     {
      Log("[dry] would close #" + Tk(ticket) + " (" + reason + ")");
      return true;
     }
   if(!RateLimitOk())
      return false;                       // the group loop shares the same budget
   if(g_trade.PositionClose(ticket, (ulong)InpDeviationPoints))
     {
      Log("closed #" + Tk(ticket) + " (" + reason + ")");
      g_dirty = true;
      g_send_ok++;
      g_fuse_cnt = 0;
      BoForget(ticket);
      return true;
     }
   uint rc = g_trade.ResultRetcode();
   g_send_fail++;
   FuseTrip(rc);
   g_warn = StringFormat("close refused for #%s (retcode %d) - tried again on the next cycle",
                         Tk(ticket), (int)rc);
   Print("GoldBasketGuard: " + g_warn);
   return false;                          // no Sleep: the cycle that follows is 100 ms away
  }
//+------------------------------------------------------------------+
//| Daily loss limit / profit target - circuit breaker for the day    |
//+------------------------------------------------------------------+
void DailyGuard()
  {
   if(!UseDaily())
      return;
   if(InpDailyLossLimitPct <= 0.0 && InpDailyProfitTargetPct <= 0.0)
      return;
   if(g_day_bal <= 0.0)
      return;
   if(g_lockout_until > 0 && ServerNow() < g_lockout_until)
      return;

   double pl   = DayPnl();
   double lim  = g_day_bal * InpDailyLossLimitPct / 100.0;
   double tgt  = g_day_bal * InpDailyProfitTargetPct / 100.0;

   if(InpDailyLossLimitPct > 0.0 && pl <= -lim)
     {
      g_last_action = StringFormat("daily loss limit hit: %.2f <= -%.2f", pl, lim);
      PauseTillTomorrow(InpDailyCloseOnLimit, g_last_action);
      return;
     }
   if(InpDailyProfitTargetPct > 0.0 && pl >= tgt)
     {
      g_last_action = StringFormat("daily profit target hit: %.2f >= %.2f", pl, tgt);
      PauseTillTomorrow(InpDailyCloseOnLimit, g_last_action);
     }
  }
//+------------------------------------------------------------------+
void PauseTillTomorrow(bool close_now, string why)
  {
   Log(why);
   if(close_now)
      CloseGroup(CLOSE_ALL, why);
   datetime now  = ServerNow();
   datetime day0 = now - (now % 86400);
   g_lockout_until = day0 + 86400;
   GVSet("LOCK", (double)g_lockout_until);
   g_paused = true;
   Notify(why + " - paused until the next trading day");
  }
//+------------------------------------------------------------------+
void LockoutTick()
  {
   if(g_lockout_until <= 0)
      return;
   if(ServerNow() >= g_lockout_until)
     {
      bool was_killed = g_killed;
      g_lockout_until = 0;
      g_paused = false;
      g_killed = false;               // the lock was the only thing holding it: InpEmergencyLockHours
      GVSet("LOCK", 0);
      g_last_action = (was_killed ? "emergency lock over - automation resumed"
                                  : "lockout expired - automation resumed");
      Log(g_last_action);
      Notify("GoldBasketGuard: " + g_last_action);
      return;
     }
   g_paused = true;
   g_info_line = StringFormat("locked for %s", HmsStr((int)(g_lockout_until - ServerNow())));
  }
//+------------------------------------------------------------------+
void ClearLockout()
  {
   g_lockout_until = 0;
   g_paused        = false;
   g_killed        = false;
   GVSet("LOCK", 0);
   g_last_action = "lockout cleared by the trader";
   Log(g_last_action);
  }
//+------------------------------------------------------------------+
string HmsStr(int secs)
  {
   if(secs < 0)
      secs = 0;
   int h = secs / 3600;
   int m = (secs % 3600) / 60;
   int s = secs % 60;
   if(h > 0)
      return StringFormat("%dh %02dm", h, m);
   return StringFormat("%02d:%02d", m, s);
  }
