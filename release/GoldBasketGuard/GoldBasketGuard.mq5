//+------------------------------------------------------------------+
//|                                              GoldBasketGuard.mq5 |
//|   Group (basket) TP/SL manager + automatic risk-free engine     |
//|   Target instrument: XAUUSD (Gold) on MetaTrader 5              |
//+------------------------------------------------------------------+
#property copyright   "my-new-trading-system"
#property link        "https://github.com/umberlla19733/my-new-trading-system"
#property version     "1.10"
#property description "Group (basket) stop-loss / take-profit manager with automatic risk-free for MT5"
#property description "Gold / XAUUSD: set TP-SL on ONE ticket, the whole group is aligned to it"
#property description "News guard (red-folder), risk-percent position sizing, cent/dollar auto-detect, 50% account breaker"
#property description "Test on a demo account first. Not investment advice."

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
input bool     InpAutoApplyOnStart         = true;      // Apply group TP/SL to existing positions at startup
input bool     InpReapplyEveryCycle      = false;     // Re-apply every cycle (keeps levels glued to avg entry)
input double   InpAbsSLPrice             = 0.0;      // Absolute group SL price (0 = use pips)
input double   InpAbsTPPrice             = 0.0;      // Absolute group TP price (0 = use pips)

input group "3) Mirror one manual edit to the whole group (core feature)"
input bool     InpMirrorSL               = true;     // If I edit SL on one ticket -> apply to all
input bool     InpMirrorTP               = true;     // If I edit TP on one ticket -> apply to all
input ENUM_APPLY_MODE InpMirrorMode      = APPLY_SAME_LEVEL; // Mirror as: same price / same distance
input int      InpMirrorGuardSec         = 4;        // Ignore changes made by EA itself (seconds)

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

input group "6) Group money targets / kill-switch"
input bool     InpEnableBasketMoneyExit  = false;     // Close group on money target / money stop
input double   InpBasketTakeMoney        = 500.0;     // Group take-profit in money
input double   InpBasketStopMoney        = 500.0;     // Group stop-loss in money (positive number)
input double   InpEstCommissionPerLot    = 0.0;        // Est. round-turn commission per 1.0 lot (for calc)
input bool     InpEnableKillSwitch       = false;     // Hard equity guard: close all + stop EA
input double   InpMaxDrawdownPctEquity   = 15.0;      // If floating loss of group > % equity -> kill switch
input bool     InpCloseAllOnKill         = true;      // Kill switch also closes the group

input group "7) Broker safety"
input double   InpPipSize                = 0.0;       // Price value of 1 pip (0 = auto: 0.10 on gold)
input int      InpMinStopsPoints         = 0;         // Extra guard distance in points (on top of broker)
input int      InpMinDeltaPoints         = 2;         // Skip modify if change < N points (anti-spam)
input int      InpDeviationPoints        = 30;        // Max deviation / slippage in points
input int      InpMaxModsPerSecond       = 4;         // Rate limit of modification requests
input int      InpMinSecPerTicket        = 2;         // Min seconds between 2 mods of same ticket
input int      InpRetryCount             = 3;         // Retries on requote/busy
input int      InpRetryDelayMs           = 350;       // Delay between retries (ms, ignored in tester)
input bool     InpRequireNewBar          = false;     // Evaluate only once per new bar
input int      InpTimerSeconds           = 1;         // Watchdog timer (seconds, 0 = only OnTick)
input bool     InpDryRun                 = false;     // Dry run: log decisions, send nothing

input group "8) News guard - red-folder protection"
input bool     InpNewsEnabled            = true;      // Use the MT5 economic calendar
input ENUM_CALENDAR_EVENT_IMPORTANCE InpNewsImportance = CALENDAR_IMPORTANCE_HIGH; // Minimum importance to react to
input bool     InpNewsIncludeModerate    = false;     // Also react to orange (moderate) events
input int      InpNewsBeforeMin          = 20;        // Minutes before the release to react
input int      InpNewsAfterMin           = 15;        // Minutes after the release to stay defensive
input string   InpNewsCurrencies         = "";        // Currencies to watch, e.g. "USD,EUR" (empty = from symbol)
input ENUM_NEWS_ACTION InpNewsAction     = NEWS_CLOSE_GROUP; // What to do inside the window
input bool     InpNewsPauseAutomation    = true;      // Also suspend SL/TP editing inside the window
input bool     InpNewsTightenBeforeClose  = true;      // Move to risk-free first, then close (if action closes)
input string   InpNewsManualWindows      = "";        // Fallback windows "[DOW-]HH:MM-HH:MM;..." server time, DOW 0=Sun
input int      InpNewsRefreshSec         = 30;        // Calendar polling period (seconds, server limit 5204)

input group "9) Risk sizing, money units, broker adaptation"
input double   InpRiskPctPerBasket       = 0.0;        // Auto group SL from risk % of balance (0 = off)
input double   InpRiskRewardRatio        = 0.0;        // Auto TP = risk * ratio (0 = keep InpTPPips)
input double   InpRiskCapPips            = 0.0;        // Max SL pips the auto sizing may use (0 = no cap)
input double   InpRiskFloorPips          = 80.0;       // Min SL pips the auto sizing may use
input int      InpEmergencyFloatLossPct  = 50;          // Account floating loss >= percent of balance -> close all (0 = off)
input double   InpEmergencyEquityDdPct   = 0.0;         // Drawdown from peak equity >= percent -> close all (0 = off)
input int      InpEmergencyMarginLevelPct= 150;         // Margin level below this percent -> close all (0 = off)
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
  };

SPos     g_pos[];
SBasket  g_basket;
SSticker g_st[];

#define GBG "GBG_"

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
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
   g_trailOn   = (InpTrailMode != TRAIL_OFF);
   g_start_time= TimeCurrent();
   g_hedging   = (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   g_news_enabled = InpNewsEnabled;
   g_stop_pad     = InpMinStopsPoints;
   DetectAccountUnits();
   InitAnchors();
   if(g_cent)
      Log(StringFormat("cent account detected (%s): money inputs are multiplied by %.0f", g_acct_ccy, g_money_factor));

   g_trade.SetExpertMagicNumber(InpMagicFilter > 0 ? (ulong)InpMagicFilter : 0);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   if(!g_hedging)
      g_warn = "NETTING account: the group is a single ticket - mirroring is limited.";

   if(InpTimerSeconds > 0 && !IsTester())
      EventSetTimer(MathMax(1, InpTimerSeconds));

   if(InpShowPanel && (!IsTester() || IsVisual()))
      PanelCreate();

   Log(StringFormat("GoldBasketGuard on %s | pip=%.5f (%.0f pt) | digits=%d | hedging=%s | account=%s%s | risk=%.2f/pip",
                    _Symbol, g_pip, g_pip / g_point, g_digits, g_hedging ? "yes" : "no",
                    g_acct_ccy, g_cent ? " (cent)" : "", MoneyPerPipPerLot(_Symbol) > 0 ? 1.0 : 0.0));
   if(AccountInfoInteger(ACCOUNT_TRADE_EXPERT) == 0)
      g_warn = "the broker account forbids EA trading (ACCOUNT_TRADE_EXPERT = false)";
   Manage();
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   PanelDelete();
   Comment("");
  }
//+------------------------------------------------------------------+
//| Tick                                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   Manage();
  }
//+------------------------------------------------------------------+
//| Watchdog (needed when the symbol ticks slowly / weekend)         |
//+------------------------------------------------------------------+
void OnTimer()
  {
   Manage();
  }
//+------------------------------------------------------------------+
//| Trade events: a new position was opened -> apply group stops     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(g_paused || g_killed)
      return;
   if(trans.type == TRADE_TRANSACTION_POSITION)
     {
      if(trans.deal_type == DEAL_TYPE_BUY || trans.deal_type == DEAL_TYPE_SELL)
        {
         if(InpAutoApplyToNew)
           {
            g_dirty = true;
            g_apply_seq++;
           }
        }
      else
         g_dirty = true;   // position closed -> recompute group
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
         double v = StringToDouble(EditGet(sparam));
         if(v < 0.0) v = 0.0;
         if(which == "SL")          g_slPips = v;
         else if(which == "TP")     g_tpPips = v;
         else if(which == "BE")     g_beTrigger = v;
         else if(which == "LOCK")   g_beLock = v;
         else if(which == "TRAIL")  g_trailDist = v;
         PanelUpdate();
         Log("panel edit " + which + " = " + DoubleToString(v, 1) + " pips");
        }
      return;
     }

   if(id == CHARTEVENT_KEYDOWN)
      OnHotkey((int)lparam);
  }
//+------------------------------------------------------------------+
//| Hotkeys: 1 apply both, 2 SL, 3 TP, 4 risk-free, 5 trail, 0 pause |
//+------------------------------------------------------------------+
void OnHotkey(const int key)
  {
   switch(key)
     {
      case '1': ApplyGroupStops(true,  true,  "hotkey");  break;
      case '2': ApplyGroupStops(true,  false, "hotkey");  break;
      case '3': ApplyGroupStops(false, true,  "hotkey");  break;
      case '4': ForceRiskFree();                          break;
      case '5': g_trailOn = !g_trailOn; Log("trailing " + (g_trailOn ? "ON" : "OFF")); break;
      case '6': g_news_enabled = !g_news_enabled; Log("news guard " + (g_news_enabled ? "ON" : "OFF")); break;
      case '7': ClearLockout();                                      break;
      case '0': g_paused = !g_paused;   Log("EA " + (g_paused ? "PAUSED" : "ACTIVE")); break;
     }
   PanelUpdate();
  }
//+------------------------------------------------------------------+
//| Panel button dispatcher                                           |
//+------------------------------------------------------------------+
void OnButton(string name)
  {
   static datetime last_close_arm = 0;
   if(name == "APPLY")       { ReadEdits(); ApplyGroupStops(true,  true,  "panel"); }
   else if(name == "SL")     { ReadEdits(); ApplyGroupStops(true,  false, "panel"); }
   else if(name == "TP")     { ReadEdits(); ApplyGroupStops(false, true,  "panel"); }
   else if(name == "BE")     { ReadEdits(); ForceRiskFree(); }
   else if(name == "TRAIL")  { g_trailOn = !g_trailOn; g_last_action = "trail " + (g_trailOn ? "on" : "off"); }
   else if(name == "CLEAR")  { ApplyGroupStopsClear(); }
   else if(name == "CLOSEALL")
     {
      if(TimeCurrent() - last_close_arm < 6)
        {
         last_close_arm = 0;
         CloseGroup(CLOSE_ALL, "panel close-all");
        }
      else
        {
         last_close_arm = TimeCurrent();
         g_last_action = "CLOSE ALL? click again within 6s";
         Log("close-all armed - press again to confirm");
        }
     }
   else if(name == "CLOSELOSE")
     {
      if(TimeCurrent() - last_close_arm < 6)
        {
         last_close_arm = 0;
         CloseGroup(CLOSE_LOSING, "panel close-losers");
        }
      else
        {
         last_close_arm = TimeCurrent();
         g_last_action = "CLOSE LOSERS? click again within 6s";
        }
     }
   else if(name == "PAUSE")    { g_paused = !g_paused; }
   else if(name == "NEWS")     { g_news_enabled = !g_news_enabled; Log("news guard " + (g_news_enabled ? "ON" : "OFF")); }
   else if(name == "UNLOCK")   { ClearLockout(); }
   PanelUpdate();
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
//| main cycle                                                        |
//+------------------------------------------------------------------+
void Manage()
  {
   TouchRateWindow();
   g_warn        = "";
   g_info_line   = "";

   LockoutTick();
   NewsScan();

   if(InpRequireNewBar)
     {
      datetime bt = iTime(_Symbol, PERIOD_CURRENT, 0);
      if(bt == g_last_bar && !IsTester())
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

   if(!IsTester() && (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == 0 || MQLInfoInteger(MQL_TRADE_ALLOWED) == 0))
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
   ArrayResize(g_pos, 0);
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      string sym   = PositionGetString(POSITION_SYMBOL);
      long   magic = PositionGetInteger(POSITION_MAGIC);
      int    type  = (int)PositionGetInteger(POSITION_TYPE);
      string cmt   = PositionGetString(POSITION_COMMENT);
      datetime ot  = (datetime)PositionGetInteger(POSITION_TIME);
      if(type != POSITION_TYPE_BUY && type != POSITION_TYPE_SELL)
         continue;
      if(!MatchPosition(t, sym, magic, cmt, type, ot))
         continue;

      int k = ArraySize(g_pos);
      ArrayResize(g_pos, k + 1);
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
      double cur = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_BID)
                                               : SymbolInfoDouble(sym, SYMBOL_ASK);
      g_pos[k].gain_pips = (type == POSITION_TYPE_BUY) ? (cur - g_pos[k].open) / g_pip
                                                        : (g_pos[k].open - cur) / g_pip;
     }
   return ArraySize(g_pos);
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
   if(!InpMirrorSL && !InpMirrorTP)
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
         continue;

      bool was_ours = (TimeCurrent() - g_st[k].seen) < MathMax(1, InpMirrorGuardSec);
      StRemember(i);                            // always resync our memory
      if(was_ours)
         continue;                              // this was our own modification

      if(sl_diff && InpMirrorSL)
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
      if(tp_diff && InpMirrorTP)
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
      if(raw_sl > 0.0 && FinalizeLevel(g_pos[i].symbol, g_pos[i].type, true, raw_sl, v, (sl_level != 0.0)))
         sl = v;
     }

   //--- TP side ------------------------------------------------------
   if(tp_level < 0.0)
      tp = 0.0;
   else
     {
      double raw_tp = (tp_level > 0.0) ? tp_level
                     : (tp_dist > 0.0 ? (buy ? anch + tp_dist * g_pip : anch - tp_dist * g_pip) : 0.0);
      double v;
      if(raw_tp > 0.0 && FinalizeLevel(g_pos[i].symbol, g_pos[i].type, false, raw_tp, v, (tp_level != 0.0)))
         tp = v;
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

   double pt   = SymbolInfoDouble(sym, SYMBOL_POINT);
   double ask  = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid  = SymbolInfoDouble(sym, SYMBOL_BID);
   int    dg   = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double stops = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * pt;
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
   if(InpBeMode == BE_OFF && !force)
      return;
   int n = ArraySize(g_pos);
   if(n == 0)
      return;

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
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
         Alert("GoldBasketGuard: " + msg);
         if(InpPlaySound) PlaySound("alert.wav");
         if(InpPushNotification) SendNotification(msg);
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
      double mkt = buy ? SymbolInfoDouble(g_pos[i].symbol, SYMBOL_BID)
                       : SymbolInfoDouble(g_pos[i].symbol, SYMBOL_ASK);
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
   if(!InpEnableBasketMoneyExit)
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
   if(!InpEnableKillSwitch || g_killed)
      return;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
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
   Alert("GoldBasketGuard: " + g_warn + " - EA disabled, re-enable manually.");
   if(InpPlaySound) PlaySound("alert.wav");
   if(InpPushNotification) SendNotification("GoldBasketGuard KILL SWITCH: " + g_warn);
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
      if(InpDryRun)
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
      if(InpDryRun)
        {
         Log("[dry] would close #" + Tk(g_pos[i].ticket));
         closed++;
         continue;
        }
      bool done = false;
      for(int r = 0; r <= InpRetryCount && !done; r++)
        {
         done = g_trade.PositionClose(g_pos[i].ticket, (ulong)InpDeviationPoints);
         if(!done && r < InpRetryCount && !IsTester())
            Sleep(InpRetryDelayMs);
        }
      if(done) closed++;
      else
        {
         failed++;
         PrintFormat("GoldBasketGuard: close failed #%s retcode=%d", Tk(g_pos[i].ticket), (int)g_trade.ResultRetcode());
        }
     }
   g_last_action = StringFormat("%s: closed %d, failed %d", reason, closed, failed);
   Log(g_last_action);
   if(InpPlaySound) PlaySound("alert.wav");
   if(InpPushNotification) SendNotification("GoldBasketGuard " + _Symbol + ": " + g_last_action);
   g_dirty = false;
   CollectGroup();
   ComputeBasket();
   PanelUpdate();
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
   double pt  = SymbolInfoDouble(sym, SYMBOL_POINT);
   double dlt = pt * MathMax(1, InpMinDeltaPoints) * 0.5;
   int    dg  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   // widen the guard if this broker is stricter than its own STOPS_LEVEL suggests
   double sl = sl_req;
   double tp = tp_req;
   if(g_stop_pad > 0 && (sl > 0.0 || tp > 0.0))
     {
      double pad = (double)g_stop_pad * pt;
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      bool   buy = (g_pos[i].type == POSITION_TYPE_BUY);
      if(sl > 0.0)
         sl = buy ? MathMin(sl, bid - pad) : MathMax(sl, ask + pad);
      if(tp > 0.0)
         tp = buy ? MathMax(tp, ask + pad) : MathMin(tp, bid - pad);
      sl = NormalizeDouble(sl, dg);
      tp = NormalizeDouble(tp, dg);
     }

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
   if(!protective && !is_clear && kk >= 0 && InpMinSecPerTicket > 0 &&
      (TimeCurrent() - g_st[kk].seen) < InpMinSecPerTicket)
      return false;                    // anti-spam cool-down for this ticket

   double frz = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL) * pt;
   if(frz > 0.0)
     {
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
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

   if(!RateLimitOk())
      return false;

   if(InpDryRun)
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
         g_pos[i].sl = sl;
         g_pos[i].tp = tp;
         StRemember(i);
         if(InpVerboseLog)
            PrintFormat("GoldBasketGuard: #%s %s | SL %s -> %s | TP %s -> %s",
                        Tk(g_pos[i].ticket), reason,
                        DoubleToString(old_sl, dg), DoubleToString(sl, dg),
                        DoubleToString(old_tp, dg), DoubleToString(tp, dg));
         return true;
        }
      bool retryable = (rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED ||
                        rc == TRADE_RETCODE_PRICE_OFF || rc == TRADE_RETCODE_TOO_MANY_REQUESTS ||
                        rc == TRADE_RETCODE_TIMEOUT || !sent);
      if(r < InpRetryCount && retryable)
        {
         if(!IsTester())
            Sleep(InpRetryDelayMs);
         continue;
        }
      if(rc == TRADE_RETCODE_INVALID_STOPS && InpAdaptiveStops)
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
   g_st[k].sl   = g_pos[i].sl;
   g_st[k].tp   = g_pos[i].tp;
   g_st[k].seen = TimeCurrent();
   g_st[k].seq  = g_apply_seq;
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
        {
         g_st[k].ticket  = g_st[last].ticket;
         g_st[k].sl      = g_st[last].sl;
         g_st[k].tp      = g_st[last].tp;
         g_st[k].seen    = g_st[last].seen;
         g_st[k].seq     = g_st[last].seq;
         g_st[k].be_done = g_st[last].be_done;
        }
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
bool IsTester()
  {
   return (MQLInfoInteger(MQL_TESTER) != 0);
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
//| Chart panel                                                       |
//+------------------------------------------------------------------+
void ORect(string name,int dx,int dy,int w,int h)
  {
   string n = GBG + name;
   if(ObjectFind(0,n) < 0)
      ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,dx);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,dy);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,InpClrPanelBg);
   ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,n,OBJPROP_COLOR,InpClrAccent);
   ObjectSetInteger(0,n,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,n,OBJPROP_BACK,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,n,OBJPROP_ZORDER,0);
  }
//+------------------------------------------------------------------+
void OLabel(string name,int dx,int dy,string txt,color clr,int fs)
  {
   string n = GBG + name;
   if(ObjectFind(0,n) < 0)
      ObjectCreate(0,n,OBJ_LABEL,0,0,0);
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
  }
//+------------------------------------------------------------------+
void OButton(string name,int dx,int dy,int w,int h,string txt,string tip)
  {
   string n = GBG + "BTN_" + name;
   if(ObjectFind(0,n) < 0)
      ObjectCreate(0,n,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,dx);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,dy);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,InpFontSize);
   ObjectSetInteger(0,n,OBJPROP_COLOR,InpClrText);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,C'40,48,62');
   ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR,C'70,80,100');
   ObjectSetInteger(0,n,OBJPROP_STATE,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,n,OBJPROP_ZORDER,2);
   ObjectSetString(0,n,OBJPROP_FONT,"Arial");
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
   ObjectSetString(0,n,OBJPROP_TOOLTIP,tip);
  }
//+------------------------------------------------------------------+
void OEdit(string name,int dx,int dy,int w,int h,string txt,string tip)
  {
   string n = GBG + "EDIT_" + name;
   if(ObjectFind(0,n) < 0)
      ObjectCreate(0,n,OBJ_EDIT,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,dx);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,dy);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,InpFontSize);
   ObjectSetInteger(0,n,OBJPROP_COLOR,InpClrAccent);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,C'12,16,22');
   ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR,C'90,100,120');
   ObjectSetInteger(0,n,OBJPROP_ALIGN,ALIGN_CENTER);
   ObjectSetInteger(0,n,OBJPROP_READONLY,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,n,OBJPROP_ZORDER,2);
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
void PanelCreate()
  {
   int x = InpPanelX, y = InpPanelY;
   int w = 348;
   int h = 400;
   int rowh = 14;
   int rows = 12;
   ORect("BG",x,y,w,h);
   OLabel("TITLE",x+10,y+7,"GOLD BASKET GUARD",InpClrAccent,10);
   OLabel("SUB",  x+10,y+24,_Symbol + " | pip = " + DoubleToString(g_pip,(int)MathMax(1,g_digits)) +
          " (" + DoubleToString(g_pip/g_point,0) + " pt)",InpClrText,InpFontSize);

   for(int i = 0; i < rows; i++)
      OLabel("L" + IntegerToString(i),x+10,y+42+i*rowh,"",InpClrText,InpFontSize);

   int ey = y + 42 + rows*rowh + 6;
   OLabel("K1",x+10,ey+3,"SL  pips",InpClrText,InpFontSize);
   OEdit ("SL",x+74,ey,52,18,DoubleToString(g_slPips,1),"Group stop distance in pips. 0 = do not touch SL");
   OLabel("K2",x+136,ey+3,"TP  pips",InpClrText,InpFontSize);
   OEdit ("TP",x+196,ey,52,18,DoubleToString(g_tpPips,1),"Group take-profit distance in pips. 0 = do not touch TP");
   ey += 22;
   OLabel("K3",x+10,ey+3,"BE arm",InpClrText,InpFontSize);
   OEdit ("BE",x+74,ey,52,18,DoubleToString(g_beTrigger,1),"Pips in profit that switches the group to risk-free");
   OLabel("K4",x+136,ey+3,"BE lock",InpClrText,InpFontSize);
   OEdit ("LOCK",x+196,ey,52,18,DoubleToString(g_beLock,1),"Pips locked beyond entry once risk-free");
   ey += 22;
   OLabel("K5",x+10,ey+3,"Trail dist",InpClrText,InpFontSize);
   OEdit ("TRAIL",x+74,ey,52,18,DoubleToString(g_trailDist,1),"Fixed trailing distance (FIXED mode only)");

   int by = ey + 24;
   int bw = 108, bh = 22, gap = 5;
   OButton("APPLY",    x+8,           by, bw, bh, "APPLY TP+SL",  "Set the group TP and SL on every ticket now");
   OButton("SL",       x+8+(bw+gap),  by, bw, bh, "APPLY SL",     "Set only the group SL");
   OButton("TP",       x+8+2*(bw+gap),by, bw, bh, "APPLY TP",     "Set only the group TP");
   by += bh+gap;
   OButton("BE",       x+8,           by, bw, bh, "RISK-FREE NOW","Move all SLs to entry+lock immediately");
   OButton("TRAIL",    x+8+(bw+gap),  by, bw, bh, "TRAIL ON/OFF", "Enable / disable trailing");
   OButton("CLEAR",    x+8+2*(bw+gap),by, bw, bh, "CLEAR SL/TP",  "Remove SL and TP from every ticket of the group");
   by += bh+gap;
   OButton("CLOSEALL", x+8,           by, bw, bh, "CLOSE ALL",    "Click twice within 6 seconds to close the group");
   OButton("CLOSELOSE",x+8+(bw+gap),  by, bw, bh, "CLOSE LOSERS", "Click twice to close only losing tickets");
   OButton("PAUSE",    x+8+2*(bw+gap),by, bw, bh, "PAUSE / RUN",  "Suspend / resume all automation");
   by += bh+gap;
   OButton("NEWS",     x+8,           by, bw, bh, "NEWS ON",   "Enable / disable the news guard (red-folder events)");
   OButton("UNLOCK",   x+8+(bw+gap),  by, bw, bh, "UNLOCK",    "Clear the lockout / kill-switch and resume");
   ObjectSetString(0,GBG + "BG",OBJPROP_TOOLTIP,"keys: 1 apply  2 SL  3 TP  4 risk-free  5 trail  6 news  7 unlock  0 pause");
   ChartRedraw();
  }
//+------------------------------------------------------------------+
void PanelDelete()
  {
   ObjectsDeleteAll(0,GBG,-1,-1);
   ChartRedraw();
  }
//+------------------------------------------------------------------+
void ReadEdits()
  {
   if(!InpShowPanel)
      return;
   string a = GBG + "EDIT_SL", b = GBG + "EDIT_TP", c = GBG + "EDIT_BE", d = GBG + "EDIT_LOCK", e = GBG + "EDIT_TRAIL";
   double new_sl = (ObjectFind(0,a) >= 0) ? MathMax(0.0,StringToDouble(EditGet(a))) : g_slPips;
   double new_tp = (ObjectFind(0,b) >= 0) ? MathMax(0.0,StringToDouble(EditGet(b))) : g_tpPips;
   if(ObjectFind(0,a) >= 0 && MathAbs(new_sl - g_slPips) > 1e-9)
     {
      g_slPips = new_sl;
      g_absSl  = 0.0;                       // an explicit distance wins over a mirrored price
     }
   if(ObjectFind(0,b) >= 0 && MathAbs(new_tp - g_tpPips) > 1e-9)
     {
      g_tpPips = new_tp;
      g_absTp  = 0.0;
     }
   if(ObjectFind(0,c) >= 0) g_beTrigger = MathMax(0.0,StringToDouble(EditGet(c)));
   if(ObjectFind(0,d) >= 0) g_beLock    = StringToDouble(EditGet(d));
   if(ObjectFind(0,e) >= 0) g_trailDist = MathMax(0.0,StringToDouble(EditGet(e)));
  }
//+------------------------------------------------------------------+
void PanelUpdate()
  {
   if(!InpShowPanel || IsTester() && !IsVisual())
      return;
   if(ObjectFind(0,GBG + "BG") < 0)
     {
      PanelCreate();
      return;
     }
   int    rowh = 14;

   int    n  = ArraySize(g_pos);
   double pl = GroupNetMoney();
   color  c  = (pl >= 0.0 ? InpClrOk : clrIndianRed);
   string s[12];

   s[0] = StringFormat("group: %d tickets  (%d buy / %d sell)  vol %.2f  |  %s %s",
                        n, g_basket.cnt_buy, g_basket.cnt_sell, g_basket.vol_total,
                        g_acct_ccy, g_cent ? "(cent)" : "");
   if(g_basket.avg_buy > 0)
      s[1] = StringFormat("avg BUY  %s   %+.1f pips", DoubleToString(g_basket.avg_buy,g_digits), g_basket.gain_pips_buy);
   else
      s[1] = "avg BUY  -";
   if(g_basket.avg_sell > 0)
      s[2] = StringFormat("avg SELL %s   %+.1f pips", DoubleToString(g_basket.avg_sell,g_digits), g_basket.gain_pips_sell);
   else
      s[2] = "avg SELL -";
   s[3] = StringFormat("basket P/L: %s  (swap %s)  |  eq %s", MoneyStr(pl), MoneyStr(g_basket.swap),
                       MoneyStr(AccountInfoDouble(ACCOUNT_EQUITY)));
   s[4] = StringFormat("risk at SL: %s (%.2f%% bal)  =  %.1f pips  |  %.2f/pip",
                       MoneyStr(g_risk_money),
                       AccountInfoDouble(ACCOUNT_BALANCE) > 0 ? g_risk_money / AccountInfoDouble(ACCOUNT_BALANCE) * 100.0 : 0.0,
                       g_slPips, GroupMoneyPerPip());
   s[5] = StringFormat("SL %.1f p -> %s | TP %.1f p -> %s", g_slPips, LevelHint(true), g_tpPips, LevelHint(false));
   s[6] = StringFormat("risk-free: arm %.1f p, lock %.1f p, done %d | trail %s",
                       g_beTrigger, g_beLock, g_be_done_count, g_trailOn ? "ON" : "OFF");
   if(g_news_enabled)
      s[7] = (g_news_active ? StringFormat("NEWS: %s", g_news_desc)
                            : StringFormat("news: %s", g_news_desc));
   else
      s[7] = "news: guard OFF";
   s[8] = StringFormat("margin %.1f%% | free %s | day P/L %s | dd %.1f%%",
                       AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), MoneyStr(AccountInfoDouble(ACCOUNT_MARGIN_FREE)),
                       MoneyStr(DayPnl()),
                       g_peak_equity > 0 ? (g_peak_equity - AccountInfoDouble(ACCOUNT_EQUITY)) / g_peak_equity * 100.0 : 0.0);
   s[9] = StringFormat("spread %d pt | stops %d pt (+%d ad) | freeze %d pt | %s",
                       (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD),
                       (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                       g_stop_pad, (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL),
                       g_hedging ? "hedging" : "netting");
   s[10]= "act: " + g_last_action;
   if(g_paused || g_killed || g_lockout_until > 0 || StringLen(g_warn) > 0 || StringLen(g_info_line) > 0)
     {
      string st = (g_killed ? "KILL-SWITCH ACTIVE  " : (g_paused ? "PAUSED  " : "")) + g_warn + " " + g_info_line;
      if(g_news_errno != 0)
         st = st + StringFormat(" [calendar err %d]", g_news_errno);
      s[11] = st;
      OLabel("L11",InpPanelX+10,InpPanelY+42+11*rowh,s[11],InpClrWarn,InpFontSize);
     }
   else
     {
      s[11] = (n == 0 ? "waiting for positions of the group"
                      : StringFormat("live | dry-run %s | %s", InpDryRun ? "ON" : "off",
                                      g_news_calendar ? "calendar ok" : "calendar unavailable"));
      OLabel("L11",InpPanelX+10,InpPanelY+42+11*rowh,s[11],InpClrText,InpFontSize);
     }

   for(int i = 0; i < 11; i++)
      OLabel("L" + IntegerToString(i),InpPanelX+10,InpPanelY+42+i*rowh,s[i],
             (i == 3 ? c : (i == 7 && g_news_active ? InpClrWarn : InpClrText)),InpFontSize);

   ObjectSetString(0,GBG + "BTN_TRAIL",OBJPROP_TEXT,g_trailOn ? "TRAIL ON" : "TRAIL OFF");
   ObjectSetString(0,GBG + "BTN_PAUSE",OBJPROP_TEXT,(g_paused || g_killed) ? "RESUME" : "PAUSE");
   ObjectSetString(0,GBG + "BTN_NEWS",OBJPROP_TEXT,g_news_enabled ? "NEWS ON" : "NEWS OFF");
   ChartRedraw();
  }
//+------------------------------------------------------------------+
//| Human hint of what the group level currently is                   |
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
//| Account currency                                                   |
//+------------------------------------------------------------------+
string AccountCurrency()
  {
   return AccountInfoString(ACCOUNT_CURRENCY);
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
   return (g_pip / ts) * tv;
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

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal <= 0.0)
      return;

   if(InpRiskPctPerBasket <= 0.0)
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
   datetime t = TimeTradeServer();
   if(t <= 0)
      t = TimeCurrent();
   return t;
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

   if(IsTester())
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

   Alert("GoldBasketGuard: " + why);
   if(InpPlaySound) PlaySound("alert.wav");
   if(InpPushNotification) SendNotification("GoldBasketGuard " + why);
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
      if(InpDryRun)
        {
         Log("[dry] would close #" + Tk(t) + " (account-wide)");
         closed++;
         continue;
        }
      bool done = false;
      for(int r = 0; r <= InpRetryCount && !done; r++)
        {
         done = g_trade.PositionClose(t, (ulong)InpDeviationPoints);
         if(!done && r < InpRetryCount && !IsTester())
            Sleep(InpRetryDelayMs);
        }
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
//| "50% of the account is at risk" - the hard circuit breaker        |
//+------------------------------------------------------------------+
void EmergencyGuard()
  {
   if(g_killed)
      return;

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double ml  = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   double fm  = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
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

   if(InpEmergencyStepDown && !must_nuke && ArraySize(g_pos) > 0 && !InpDryRun)
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
   Alert("GoldBasketGuard: " + g_warn + " - everything closed, EA locked");
   if(InpPlaySound) PlaySound("alert.wav");
   if(InpPushNotification) SendNotification("GoldBasketGuard EMERGENCY on " + _Symbol + ": " + why);
  }
//+------------------------------------------------------------------+
bool CloseSingle(ulong ticket, string reason)
  {
   if(InpDryRun)
     {
      Log("[dry] would close #" + Tk(ticket) + " (" + reason + ")");
      return true;
     }
   for(int r = 0; r <= InpRetryCount; r++)
     {
      if(g_trade.PositionClose(ticket, (ulong)InpDeviationPoints))
        {
         Log("closed #" + Tk(ticket) + " (" + reason + ")");
         g_dirty = true;
         return true;
        }
      if(!IsTester())
         Sleep(InpRetryDelayMs);
     }
   return false;
  }
//+------------------------------------------------------------------+
//| Daily loss limit / profit target - circuit breaker for the day    |
//+------------------------------------------------------------------+
void DailyGuard()
  {
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
   Alert("GoldBasketGuard: " + why + " - paused until the next trading day");
   if(InpPlaySound) PlaySound("alert.wav");
  }
//+------------------------------------------------------------------+
void LockoutTick()
  {
   if(g_lockout_until <= 0)
      return;
   if(ServerNow() >= g_lockout_until)
     {
      if(!g_killed)
        {
         g_lockout_until = 0;
         g_paused = false;
         GVSet("LOCK", 0);
         Log("lockout expired - automation resumed");
        }
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
