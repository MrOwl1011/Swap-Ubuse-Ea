//+------------------------------------------------------------------+
//|                                                Swap_Abuse_EA.mq5 |
//|                                                                  |
//|  Scans broker swap specifications, projects the swap booked over |
//|  a planned hold (Friday weekend or a chosen daily rollover),      |
//|  subtracts spread / commission / other costs, sizes against a     |
//|  historical gap stress loss, and optionally trades the favourable |
//|  direction. Positive swap is NOT a guaranteed profit: price risk  |
//|  over the hold, especially weekend gaps, usually dominates.       |
//|                                                                  |
//|  Standalone project. Live trading is OFF by default.              |
//+------------------------------------------------------------------+
#property copyright   "Swap Abuse EA"
#property version     "1.00"
#property description "Swap asymmetry scanner and weekend/rollover swap strategy."
#property description "Defaults: analysis only, no orders. Read README before enabling trading."

#include "Include/Defines.mqh"
#include "Include/SymbolUniverse.mqh"
#include "Include/SwapCalculator.mqh"
#include "Include/SessionSchedule.mqh"
#include "Include/CostModel.mqh"
#include "Include/RiskManager.mqh"
#include "Include/TrendFilter.mqh"
#include "Include/OpportunityScanner.mqh"
#include "Include/TradeExecutor.mqh"
#include "Include/TradeLogger.mqh"
#include "Include/PositionManager.mqh"
#include "Include/Dashboard.mqh"

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Mode ==="
input bool   EnableTrading            = false;  // EnableTrading: allow the EA to send orders
input bool   AnalysisOnlyMode         = true;   // AnalysisOnlyMode: scan, display and log only (overrides EnableTrading)
input bool   EnableFridayStrategy     = true;   // EnableFridayStrategy: enter before the Friday close, hold over the weekend
input bool   EnableSwapScanner        = true;   // EnableSwapScanner: scan SymbolsToScan (false = chart symbol only)
input bool   EnableMidweekRollover    = false;  // Also enter before weekday rollovers
input bool   MidweekTripleSwapOnly    = true;   // Weekday entries only before a triple-swap rollover

input group "=== Symbols ==="
input string SymbolsToScan            = "CURRENT,XAUUSD,EURUSD,GBPUSD,USDJPY,AUDUSD,NZDUSD,USDCAD,USDCHF,EURJPY,GBPJPY"; // SymbolsToScan: CURRENT, MARKETWATCH, ALL or names; NAME:maxSpread overrides spread
input int    MaxSymbolsToScan         = 60;     // Cap on scanned symbols (MARKETWATCH / ALL)

input group "=== Position sizing ==="
input double FixedLotSize             = 0.01;   // FixedLotSize (lots)
input bool   UseRiskBasedSizing       = false;  // UseRiskBasedSizing: size from RiskPercent and stress loss per lot
input double RiskPercent              = 0.5;    // RiskPercent of equity at stress loss
input double MinimumNetSwapAdvantage  = 1.0;    // MinimumNetSwapAdvantage: projected swap minus costs, deposit ccy per trade
input bool   RequireOppositeSwapSigns = true;   // Require favoured side positive AND opposite side negative

input group "=== Friday / rollover timing (broker server time) ==="
input int    FridayPreparationMinutes = 60;     // FridayPreparationMinutes: entry window opens this long before close/rollover
input int    FridayEntryCutoffMinutes = 10;     // FridayEntryCutoffMinutes: no new entries this close to close/rollover
input int    RolloverTimeOffsetMinutes = 0;     // Rollover time vs server midnight (e.g. -5 = 23:55)
input int    HoldRollovers            = 1;      // Calendar rollovers to hold (Friday entry: 1-3 all exit Monday)
input ENUM_SAEA_EXIT_MODE ExitMode    = SAEA_EXIT_AFTER_ROLLOVERS; // Exit mode
input int    ExitDelayMinutes         = 15;     // Minutes after reopen / rollover before scheduled exit
input int    ExitMaxWaitMinutes       = 120;    // Close anyway this long after exit is due, even if spread is wide

input group "=== Costs and market filters ==="
input int    MaximumSpread            = 50;     // MaximumSpread (points, 0 = off); per-symbol via NAME:points
input double ExitSpreadMultiplier     = 2.0;    // Assumed exit spread = current spread x this (reopen spreads are wider)
input double CommissionPerLotRoundTrip = 0.0;   // Commission per lot round trip (deposit ccy) - set from your broker
input bool   AutoDetectCommission     = true;   // Raise commission estimate from recent account deals
input double OtherCostsPerLot         = 0.0;    // Other costs per lot (fees), deposit ccy
input int    MaxQuoteAgeSeconds       = 120;    // Reject entries on quotes older than this (0 = off)
input int    MinTicksLast5Min         = 0;      // Minimum ticks in last 5 minutes (liquidity proxy, 0 = off)

input group "=== Risk limits ==="
input double MaximumWeekendLoss       = 100.0;  // MaximumWeekendLoss: max stress loss per trade, deposit ccy (0 = off)
input double MaximumTotalLots         = 0.10;   // MaximumTotalLots across EA positions (0 = off)
input int    MaximumOpenPositions     = 3;      // MaximumOpenPositions across symbols
input double MaxMarginUsePercent      = 30.0;   // Max % of free margin one entry may use
input int    GapLookbackWeeks         = 52;     // History used for weekend gap / daily range statistics
input double GapPercentile            = 95.0;   // Percentile of gaps used as stress move
input double GapRiskMultiplier        = 1.0;    // Multiplier on the historical stress move
input double MinStressPercentOfPrice  = 0.3;    // Stress move floor as % of price
input bool   CloseIfSwapTurnsNegative = true;   // Close if the held direction starts paying swap
input bool   ReduceToLimits           = true;   // Reduce positions that exceed lot / weekend-loss limits

input group "=== Trend filter ==="
input bool            UseTrendFilter  = false;  // UseTrendFilter: favoured direction must match EMA trend
input ENUM_TIMEFRAMES TrendTimeframe  = PERIOD_H4; // Trend timeframe
input int             TrendFastPeriod = 20;     // Fast EMA
input int             TrendSlowPeriod = 50;     // Slow EMA

input group "=== Stops (do NOT protect against gaps) ==="
input bool   UseStopLoss              = false;  // UseStopLoss
input int    StopLossPoints           = 3000;   // StopLossPoints
input bool   UseTakeProfit            = false;  // UseTakeProfit
input int    TakeProfitPoints         = 3000;   // TakeProfitPoints

input group "=== Execution ==="
input long   MagicNumber              = 20261009; // MagicNumber
input int    MaximumSlippage          = 30;     // MaximumSlippage (points)
input int    TimerSeconds             = 5;      // Timer period (seconds)
input int    ScanIntervalSeconds      = 60;     // Full scan interval outside entry windows (seconds)

input group "=== Dashboard and logging ==="
input bool   ShowDashboard            = true;   // Show on-chart dashboard
input int    DashboardRows            = 12;     // Opportunity rows on dashboard
input int    DashboardX               = 10;     // Dashboard X offset (px)
input int    DashboardY               = 25;     // Dashboard Y offset (px)
input int    DashboardFontSize        = 9;      // Dashboard font size
input bool   WriteCsvLogs             = true;   // Write CSV logs to MQL5\Files
input bool   VerboseLogging           = false;  // Log every decision change to the journal
input ENUM_SAEA_OPT_CRITERION OptimizationCriterion = SAEA_OPT_RECOVERY; // OnTester custom criterion

//+------------------------------------------------------------------+
//| Modules                                                          |
//+------------------------------------------------------------------+
CSymbolUniverse     g_universe;
CSwapCalculator     g_swapCalc;
CCostModel          g_cost;
CRiskManager        g_risk;
CTrendFilter        g_trend;
COpportunityScanner g_scan;
CTradeExecutor      g_exec;
CTradeLogger        g_log;
CPositionManager    g_pos;
CDashboard          g_dash;

datetime            g_lastRun = 0;
datetime            g_lastFullScan = 0;
string              g_tradeBlock = "";

//--- entry attempts per symbol and target (duplicate / retry protection)
string              g_tryKey[];
int                 g_tryCount[];
datetime            g_tryTime[];

//+------------------------------------------------------------------+
void LoadConfig()
  {
   g_cfg.enableTrading        = EnableTrading;
   g_cfg.analysisOnly         = AnalysisOnlyMode;
   g_cfg.enableFriday         = EnableFridayStrategy;
   g_cfg.enableScanner        = EnableSwapScanner;
   g_cfg.enableMidweek        = EnableMidweekRollover;
   g_cfg.midweekTripleOnly    = MidweekTripleSwapOnly;
   g_cfg.symbolsToScan        = EnableSwapScanner ? SymbolsToScan : "CURRENT";
   g_cfg.maxSymbols           = MaxSymbolsToScan;
   g_cfg.fixedLot             = FixedLotSize;
   g_cfg.useRiskSizing        = UseRiskBasedSizing;
   g_cfg.riskPercent          = RiskPercent;
   g_cfg.minNetAdvantage      = MinimumNetSwapAdvantage;
   g_cfg.requireOppositeSigns = RequireOppositeSwapSigns;
   g_cfg.prepMinutes          = FridayPreparationMinutes;
   g_cfg.cutoffMinutes        = FridayEntryCutoffMinutes;
   g_cfg.rolloverOffsetMinutes = RolloverTimeOffsetMinutes;
   g_cfg.holdRollovers        = HoldRollovers;
   g_cfg.exitMode             = ExitMode;
   g_cfg.exitDelayMinutes     = ExitDelayMinutes;
   g_cfg.exitMaxWaitMinutes   = ExitMaxWaitMinutes;
   g_cfg.maxSpread            = MaximumSpread;
   g_cfg.exitSpreadMultiplier = ExitSpreadMultiplier;
   g_cfg.commissionPerLotRT   = CommissionPerLotRoundTrip;
   g_cfg.autoDetectCommission = AutoDetectCommission;
   g_cfg.otherCostsPerLot     = OtherCostsPerLot;
   g_cfg.maxWeekendLoss       = MaximumWeekendLoss;
   g_cfg.maxTotalLots         = MaximumTotalLots;
   g_cfg.maxOpenPositions     = MaximumOpenPositions;
   g_cfg.maxMarginUsePercent  = MaxMarginUsePercent;
   g_cfg.gapLookbackWeeks     = GapLookbackWeeks;
   g_cfg.gapPercentile        = GapPercentile;
   g_cfg.gapMultiplier        = GapRiskMultiplier;
   g_cfg.minStressPercent     = MinStressPercentOfPrice;
   g_cfg.maxQuoteAgeSeconds   = MaxQuoteAgeSeconds;
   g_cfg.minTicksLast5Min     = MinTicksLast5Min;
   g_cfg.useTrendFilter       = UseTrendFilter;
   g_cfg.trendTimeframe       = TrendTimeframe;
   g_cfg.trendFastPeriod      = TrendFastPeriod;
   g_cfg.trendSlowPeriod      = TrendSlowPeriod;
   g_cfg.useStopLoss          = UseStopLoss;
   g_cfg.stopLossPoints       = StopLossPoints;
   g_cfg.useTakeProfit        = UseTakeProfit;
   g_cfg.takeProfitPoints     = TakeProfitPoints;
   g_cfg.closeOnSwapFlip      = CloseIfSwapTurnsNegative;
   g_cfg.reduceToLimits       = ReduceToLimits;
   g_cfg.magic                = MagicNumber;
   g_cfg.slippage             = MaximumSlippage;
   g_cfg.timerSeconds         = TimerSeconds;
   g_cfg.scanIntervalSeconds  = ScanIntervalSeconds;
   g_cfg.showDashboard        = ShowDashboard;
   g_cfg.dashboardRows        = DashboardRows;
   g_cfg.dashboardX           = DashboardX;
   g_cfg.dashboardY           = DashboardY;
   g_cfg.dashboardFontSize    = DashboardFontSize;
   g_cfg.writeCsv             = WriteCsvLogs;
   g_cfg.verboseLog           = VerboseLogging;
   g_cfg.optCriterion         = OptimizationCriterion;
  }

//+------------------------------------------------------------------+
bool ValidateInputs(string &err)
  {
   if(!UseRiskBasedSizing && FixedLotSize <= 0.0)
     { err = "FixedLotSize must be > 0"; return false; }
   if(UseRiskBasedSizing && (RiskPercent <= 0.0 || RiskPercent > 10.0))
     { err = "RiskPercent must be in (0, 10]"; return false; }
   if(FridayPreparationMinutes <= 0 || FridayPreparationMinutes > 24 * 60)
     { err = "FridayPreparationMinutes must be in 1..1440"; return false; }
   if(FridayEntryCutoffMinutes < 0 || FridayEntryCutoffMinutes >= FridayPreparationMinutes)
     { err = "FridayEntryCutoffMinutes must be >= 0 and < FridayPreparationMinutes"; return false; }
   if(RolloverTimeOffsetMinutes < -720 || RolloverTimeOffsetMinutes > 720)
     { err = "RolloverTimeOffsetMinutes must be in -720..720"; return false; }
   if(HoldRollovers < 1 || HoldRollovers > 30)
     { err = "HoldRollovers must be in 1..30"; return false; }
   if(ExitDelayMinutes < 0 || ExitMaxWaitMinutes < 0)
     { err = "exit minutes must be >= 0"; return false; }
   if(MaximumSpread < 0 || MaximumSlippage < 0)
     { err = "MaximumSpread / MaximumSlippage must be >= 0"; return false; }
   if(ExitSpreadMultiplier < 1.0)
     { err = "ExitSpreadMultiplier must be >= 1"; return false; }
   if(MaximumOpenPositions < 1)
     { err = "MaximumOpenPositions must be >= 1"; return false; }
   if(MaxMarginUsePercent <= 0.0 || MaxMarginUsePercent > 100.0)
     { err = "MaxMarginUsePercent must be in (0, 100]"; return false; }
   if(GapLookbackWeeks < 4 || GapPercentile <= 0.0 || GapPercentile > 100.0 || GapRiskMultiplier <= 0.0)
     { err = "gap settings invalid (lookback >= 4, percentile in (0,100], multiplier > 0)"; return false; }
   if(MinStressPercentOfPrice < 0.0)
     { err = "MinStressPercentOfPrice must be >= 0"; return false; }
   if(UseTrendFilter && (TrendFastPeriod < 1 || TrendSlowPeriod <= TrendFastPeriod))
     { err = "trend periods: need 1 <= fast < slow"; return false; }
   if((UseStopLoss && StopLossPoints <= 0) || (UseTakeProfit && TakeProfitPoints <= 0))
     { err = "stop / take-profit points must be > 0 when enabled"; return false; }
   if(MagicNumber <= 0)
     { err = "MagicNumber must be > 0"; return false; }
   if(TimerSeconds < 1 || ScanIntervalSeconds < 1)
     { err = "timer / scan interval must be >= 1 s"; return false; }
   return true;
  }

bool LiveTradingRequested()
  {
   return (g_cfg.enableTrading && !g_cfg.analysisOnly);
  }

string ModeText()
  {
   if(!LiveTradingRequested())
      return "ANALYSIS ONLY (no orders)";
   if(g_tradeBlock != "")
      return "TRADING BLOCKED: " + g_tradeBlock;
   return "LIVE TRADING ENABLED";
  }

//+------------------------------------------------------------------+
//| Duplicate / retry protection                                     |
//+------------------------------------------------------------------+
string TradedVarName(const string sym)
  {
   return "SAEA_" + IntegerToString(g_cfg.magic) + "_" + sym;
  }

bool AlreadyTraded(const string sym, const datetime target)
  {
   string name = TradedVarName(sym);
   return (GlobalVariableCheck(name) && (datetime)(long)GlobalVariableGet(name) == target);
  }

void MarkTraded(const string sym, const datetime target)
  {
   GlobalVariableSet(TradedVarName(sym), (double)(long)target);
  }

//--- max 3 attempts per symbol and target, 60 s apart
bool AttemptAllowed(const string sym, const datetime target, const datetime now)
  {
   string key = sym + "@" + IntegerToString((long)target);
   for(int i = 0; i < ArraySize(g_tryKey); i++)
      if(g_tryKey[i] == key)
        {
         if(g_tryCount[i] >= 3 || (long)(now - g_tryTime[i]) < 60)
            return false;
         g_tryCount[i]++;
         g_tryTime[i] = now;
         return true;
        }
   int n = ArraySize(g_tryKey);
   ArrayResize(g_tryKey, n + 1);
   ArrayResize(g_tryCount, n + 1);
   ArrayResize(g_tryTime, n + 1);
   g_tryKey[n] = key;
   g_tryCount[n] = 1;
   g_tryTime[n] = now;
   return true;
  }

//+------------------------------------------------------------------+
//| Entry engine                                                     |
//+------------------------------------------------------------------+
void TryEntries(const datetime now)
  {
   if(!LiveTradingRequested())
      return;
   string why = "";
   if(!g_exec.TradingPermitted(why))
     {
      if(g_tradeBlock != why)
         SAEA_Log("Trading blocked: " + why);
      g_tradeBlock = why;
      return;
     }
   g_tradeBlock = "";
   for(int r = 0; r < g_scan.RankedTotal(); r++)
     {
      int idx = g_scan.RankedIndex(r);
      SAEAAnalysis a;
      g_scan.Get(idx, a);
      if(!a.entryReady)
         break; // ranking puts entry-ready symbols first
      if(g_risk.OpenPositions() >= g_cfg.maxOpenPositions)
         break;
      if(g_cfg.maxTotalLots > 0.0 && g_risk.TotalLots() >= g_cfg.maxTotalLots - 1e-9)
         break;
      int dir = 0;
      if(g_pos.HasPosition(a.symbol, dir))
         continue; // existing position is managed (hold/reduce/close), never added to
      if(g_pos.ForeignPositionOn(a.symbol))
        {
         SAEA_Debug(a.symbol + ": netting account already holds a non-EA position, skipped");
         continue;
        }
      if(AlreadyTraded(a.symbol, a.targetTime))
         continue;
      if(!AttemptAllowed(a.symbol, a.targetTime, now))
         continue;
      //--- re-evaluate with the freshest quote right before sending
      g_scan.Refresh(idx, now);
      g_scan.Get(idx, a);
      if(!a.entryReady)
        {
         SAEA_Log("Entry " + a.symbol + " cancelled on refresh: " + a.reason);
         continue;
        }
      string res = "";
      bool ok = g_exec.Open(a, res);
      g_log.Entry(a, now, ok, res);
      if(ok)
         MarkTraded(a.symbol, a.targetTime);
     }
  }

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
string Fit(const string s, const int width)
  {
   if(StringLen(s) <= width)
      return s;
   return StringSubstr(s, 0, width - 1) + "~";
  }

void BuildDashboard(const datetime now)
  {
   if(!CDashboard::Enabled())
      return;
   color cHead = C'120,190,255';
   color cText = C'220,220,220';
   color cDim = C'140,140,150';
   color cGood = C'90,210,120';
   color cWarn = C'240,180,70';
   color cBad = C'235,95,95';
   string ccy = AccountInfoString(ACCOUNT_CURRENCY);

   g_dash.Begin();
   color modeClr = !LiveTradingRequested() ? cWarn : (g_tradeBlock != "" ? cBad : cGood);
   g_dash.Add(SAEA_NAME + " v" + SAEA_VERSION + "  |  " + ModeText(), modeClr);
   g_dash.Add("Server " + TimeToString(now, TIME_DATE | TIME_SECONDS) + " " + SAEA_DayName(SAEA_DayOfWeek(now)) +
              "  |  " + (SAEA_IsHedging() ? "HEDGING" : "NETTING") + " " + ccy +
              "  |  magic " + IntegerToString(g_cfg.magic) +
              "  |  Friday " + (g_cfg.enableFriday ? "ON" : "OFF") + ", weekday " + (g_cfg.enableMidweek ? "ON" : "OFF"), cText);

   //--- chart symbol detail (or the best ranked symbol)
   int idx = g_scan.Find(_Symbol);
   if(idx < 0 && g_scan.RankedTotal() > 0)
      idx = g_scan.RankedIndex(0);
   if(idx >= 0)
     {
      SAEAAnalysis a;
      g_scan.Get(idx, a);
      g_dash.Add("", cText);
      g_dash.Add(a.symbol + "  swap LONG " + DoubleToString(a.swap.swapLong, 3) + "  SHORT " +
                 DoubleToString(a.swap.swapShort, 3) + "  mode " + SAEA_SwapModeName(a.swap.mode) +
                 "  triple " + SAEA_DayName(a.swap.tripleDay) + "  spread " + IntegerToString(a.spreadPts), cHead);
      if(!a.swap.valid)
         g_dash.Add("  " + a.reason, cBad);
      else
        {
         g_dash.Add("  1 rollover, 1 lot: LONG " + SAEA_Money(a.swap.longPerLot) + "  SHORT " + SAEA_Money(a.swap.shortPerLot) +
                    " " + ccy + "  [" + a.swap.basis + "]", cText);
         g_dash.Add("  day ratios " + g_swapCalc.DayRatioText(a.swap), cDim);
         g_dash.Add("  weekend Fri->Mon (x" + DoubleToString(a.weekendMult, 0) + "): LONG " +
                    SAEA_Money(a.swap.longPerLot * a.weekendMult) + "  SHORT " +
                    SAEA_Money(a.swap.shortPerLot * a.weekendMult) + " per lot", cText);
         g_dash.Add("  planned hold x" + DoubleToString(a.rollMult, 1) + " (" + IntegerToString(a.rollCount) +
                    " rollovers, exit ~" + TimeToString(a.exitTime, TIME_DATE | TIME_MINUTES) + "): LONG " +
                    SAEA_Money(a.holdLongPerLot) + "  SHORT " + SAEA_Money(a.holdShortPerLot) + " per lot", cText);
         g_dash.Add("  costs/lot: spread " + SAEA_Money(a.spreadCostPerLot) + " + commission " +
                    SAEA_Money(a.commissionPerLot) + " = " + SAEA_Money(a.costPerLot) + "  |  net " +
                    SAEA_DirName(a.favDir) + " " + SAEA_Money(a.netPerLot) + "/lot  |  " +
                    DoubleToString(a.lots, 2) + " lots -> net " + SAEA_Money(a.netAdvantage), a.netPerLot > 0 ? cGood : cDim);
         g_dash.Add("  gap risk: median weekend gap " + DoubleToString(a.gap.weekendMedianPts, 0) + " pts, stress " +
                    DoubleToString(a.stressPts, 0) + " pts -> loss " + SAEA_Money(a.stressLoss) +
                    "  |  edge covers " + DoubleToString(a.breakevenPts, 0) + " pts", a.stressLoss > a.netAdvantage ? cWarn : cText);
         string sched = "  schedule " + SAEA_KindName(a.kind) + " / " + SAEA_WindowName(a.window);
         if(a.window == SAEA_WIN_CLOSED)
            sched += "  |  reopens " + TimeToString(a.reopenTime, TIME_DATE | TIME_MINUTES);
         else
            sched += "  |  target " + TimeToString(a.targetTime, TIME_DATE | TIME_MINUTES) + " (" +
                     IntegerToString(a.minutesToTarget) + " min)  |  entries " +
                     SAEA_TimeHM(a.targetTime - (datetime)(g_cfg.prepMinutes * 60)) + "-" +
                     SAEA_TimeHM(a.targetTime - (datetime)(g_cfg.cutoffMinutes * 60)) +
                     "  |  session end " + SAEA_TimeHM(a.sessionEnd) +
                     "  reopen " + TimeToString(a.reopenTime, TIME_DATE | TIME_MINUTES);
         g_dash.Add(sched, a.window == SAEA_WIN_ACTIVE ? cGood : cText);
         g_dash.Add("  decision: " + a.reason, a.entryReady ? cGood : (a.qualifies ? cWarn : cDim));
        }
     }

   //--- exposure
   SAEAPosition pos[];
   int n = g_pos.Collect(pos);
   double lots = 0.0, flt = 0.0, swp = 0.0;
   for(int i = 0; i < n; i++)
     {
      lots += pos[i].volume;
      flt += pos[i].profit;
      swp += pos[i].swap;
     }
   g_dash.Add("", cText);
   g_dash.Add("Positions " + IntegerToString(n) + "/" + IntegerToString(g_cfg.maxOpenPositions) + "  lots " +
              DoubleToString(lots, 2) + "/" + DoubleToString(g_cfg.maxTotalLots, 2) + "  floating " +
              SAEA_Money(flt) + "  swap accrued " + SAEA_Money(swp) + " " + ccy, cHead);
   for(int i = 0; i < n && i < 5; i++)
      g_dash.Add("  #" + IntegerToString((long)pos[i].ticket) + " " + pos[i].symbol + " " + SAEA_DirName(pos[i].dir) +
                 " " + DoubleToString(pos[i].volume, 2) + "  P/L " + SAEA_Money(pos[i].profit) + "  swap " +
                 SAEA_Money(pos[i].swap) + "  open " + TimeToString(pos[i].openTime, TIME_DATE | TIME_MINUTES), cText);

   //--- ranked opportunities
   g_dash.Add("", cText);
   g_dash.Add(StringFormat("%-12s %-4s %5s %9s %8s %9s %5s %8s %8s  %s", "SYMBOL", "DIR", "ROLLx", "SWAP/LOT",
                           "COST/LOT", "NET/LOT", "LOTS", "NET", "STRESS", "STATUS"), cHead);
   int rows = MathMin(g_cfg.dashboardRows, g_scan.RankedTotal());
   for(int r = 0; r < rows; r++)
     {
      SAEAAnalysis a;
      g_scan.Get(g_scan.RankedIndex(r), a);
      color c = a.entryReady ? cGood : (a.qualifies ? cWarn : (a.verified ? cDim : cBad));
      g_dash.Add(StringFormat("%-12s %-4s %5.1f %9.2f %8.2f %9.2f %5.2f %8.2f %8.2f  %s",
                              Fit(a.symbol, 12), SAEA_DirName(a.favDir), a.rollMult, a.favPerLot, a.costPerLot,
                              a.netPerLot, a.lots, a.netAdvantage, a.stressLoss, Fit(a.reason, 64)), c);
     }
   if(g_pos.LastAction() != "")
     {
      g_dash.Add("", cText);
      g_dash.Add("Last action: " + g_pos.LastAction(), cDim);
     }
   g_dash.Render();
  }

//+------------------------------------------------------------------+
//| Main cycle                                                       |
//+------------------------------------------------------------------+
void Run()
  {
   datetime now = SAEA_ServerNow();
   if(g_lastRun > 0 && (long)(now - g_lastRun) < g_cfg.timerSeconds)
      return;
   g_lastRun = now;

   bool scanDue = (g_lastFullScan == 0 || (long)(now - g_lastFullScan) >= g_cfg.scanIntervalSeconds ||
                   g_scan.AnyWindowNear());
   if(scanDue)
     {
      g_scan.Scan(now);
      g_lastFullScan = now;
      for(int i = 0; i < g_scan.Total(); i++)
        {
         SAEAAnalysis a;
         g_scan.Get(i, a);
         g_log.Decision(a, now);
        }
     }
   if(LiveTradingRequested())
      g_pos.Manage(now);
   TryEntries(now);
   BuildDashboard(now);
  }

//+------------------------------------------------------------------+
//| Init / deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   LoadConfig();
   string err = "";
   if(!ValidateInputs(err))
     {
      SAEA_Log("Invalid inputs: " + err);
      return INIT_PARAMETERS_INCORRECT;
     }
   int count = g_universe.Build(g_cfg.symbolsToScan, g_cfg.maxSymbols);
   if(count <= 0)
     {
      SAEA_Log("No tradable symbols resolved from SymbolsToScan='" + g_cfg.symbolsToScan + "'");
      return INIT_FAILED;
     }
   g_scan.Init(&g_universe, &g_swapCalc, &g_cost, &g_risk, &g_trend);
   g_exec.Init(&g_risk);
   g_log.Init();
   g_pos.Init(&g_swapCalc, &g_risk, &g_scan, &g_exec, &g_log);

   SAEA_Log(SAEA_NAME + " v" + SAEA_VERSION + " | account " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) +
            " " + AccountInfoString(ACCOUNT_CURRENCY) + " | " + (SAEA_IsHedging() ? "HEDGING" : "NETTING") +
            " | leverage 1:" + IntegerToString(AccountInfoInteger(ACCOUNT_LEVERAGE)) +
            " | " + IntegerToString(count) + " symbols | mode: " + (LiveTradingRequested() ? "LIVE TRADING" : "ANALYSIS ONLY"));
   string why = "";
   if(LiveTradingRequested() && !g_exec.TradingPermitted(why))
      SAEA_Log("WARNING: live trading requested but not permitted: " + why + ". Running analysis only until allowed.");

   //--- print every symbol's verified swap basis once
   for(int i = 0; i < count; i++)
     {
      string sym = g_universe.Name(i);
      SAEASwapSpec spec;
      if(!g_swapCalc.Read(sym, spec))
        {
         SAEA_Log(sym + ": swap UNVERIFIED - " + spec.error);
         continue;
        }
      SAEA_Log(sym + ": mode " + SAEA_SwapModeName(spec.mode) + " | raw L " + DoubleToString(spec.swapLong, 4) +
               " S " + DoubleToString(spec.swapShort, 4) + " | per lot/rollover L " + SAEA_Money(spec.longPerLot) +
               " S " + SAEA_Money(spec.shortPerLot) + " " + AccountInfoString(ACCOUNT_CURRENCY) +
               " | triple " + SAEA_DayName(spec.tripleDay) + " | " + g_swapCalc.DayRatioText(spec) +
               " | " + spec.basis + (spec.approximate ? " (approximation)" : ""));
     }

   EventSetTimer(g_cfg.timerSeconds);
   g_lastRun = 0;
   Run();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(!SAEA_IsTester())
     {
      SAEAStats s;
      g_log.ComputeStats(s);
      if(s.trades > 0)
         g_log.WriteSummary(s, 0.0, 0.0);
     }
   g_trend.Release();
   g_dash.Remove();
  }

void OnTimer()
  {
   Run();
  }

void OnTick()
  {
   Run();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   g_log.OnTransaction(trans);
  }

//+------------------------------------------------------------------+
//| Strategy Tester: statistics and custom optimisation criterion    |
//+------------------------------------------------------------------+
double OnTester()
  {
   SAEAStats s;
   g_log.ComputeStats(s);
   double dd = TesterStatistics(STAT_EQUITY_DD);
   double ddPct = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   g_log.WriteSummary(s, dd, ddPct);
   switch(g_cfg.optCriterion)
     {
      case SAEA_OPT_NET_PROFIT:
         return s.netProfit;
      case SAEA_OPT_PROFIT_FACTOR:
         return (s.trades > 0) ? s.ProfitFactor() : 0.0;
      case SAEA_OPT_RECOVERY:
         return (dd > 0.0) ? s.netProfit / dd : s.netProfit;
      case SAEA_OPT_NET_SWAP:
         return s.swapTotal + s.commission + s.fees;
     }
   return 0.0;
  }
//+------------------------------------------------------------------+
