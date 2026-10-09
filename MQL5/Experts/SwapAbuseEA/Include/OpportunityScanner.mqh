//+------------------------------------------------------------------+
//|                                          OpportunityScanner.mqh  |
//|   Evaluates every configured symbol: projected hold swap for BUY  |
//|   and SELL, trading costs, stress loss, sizing, and the entry     |
//|   window. Produces a ranked list with an accept/reject reason.    |
//+------------------------------------------------------------------+
#ifndef SAEA_OPPORTUNITY_SCANNER_MQH
#define SAEA_OPPORTUNITY_SCANNER_MQH

#include "Defines.mqh"
#include "SymbolUniverse.mqh"
#include "SwapCalculator.mqh"
#include "SessionSchedule.mqh"
#include "CostModel.mqh"
#include "RiskManager.mqh"
#include "TrendFilter.mqh"

class COpportunityScanner
  {
private:
   CSymbolUniverse  *m_universe;
   CSwapCalculator  *m_swap;
   CCostModel       *m_cost;
   CRiskManager     *m_risk;
   CTrendFilter     *m_trend;
   SAEAAnalysis      m_items[];
   int               m_order[];
   datetime          m_lastScan;

   //--- Projected hold starting at 'entry': exit estimate and rollover multiplier
   bool              ProjectHold(SAEAAnalysis &a, const datetime entry)
     {
      a.exitTime = CSessionSchedule::EstimateExit(a.symbol, entry, g_cfg.holdRollovers,
                                                  g_cfg.rolloverOffsetMinutes, g_cfg.exitDelayMinutes);
      if(a.exitTime <= 0)
         return false;
      a.rollMult = CSessionSchedule::RolloverMultiplier(a.swap, entry, a.exitTime,
                                                       g_cfg.rolloverOffsetMinutes, a.rollCount);
      return true;
     }

   //--- Day whose swap is booked by the rollover instant 'roll'
   int               RolledDay(const datetime roll) const
     {
      return SAEA_DayOfWeek(roll - (datetime)(SAEA_SECONDS_PER_DAY + g_cfg.rolloverOffsetMinutes * 60));
     }

   bool              TradeModeAllows(const long mode, const int dir) const
     {
      if(mode == SYMBOL_TRADE_MODE_FULL)
         return true;
      if(mode == SYMBOL_TRADE_MODE_LONGONLY)
         return (dir > 0);
      if(mode == SYMBOL_TRADE_MODE_SHORTONLY)
         return (dir < 0);
      return false; // CLOSEONLY / DISABLED
     }

   void              Schedule(SAEAAnalysis &a, const datetime now)
     {
      if(!CSessionSchedule::IsOpen(a.symbol, now))
        {
         a.window = SAEA_WIN_CLOSED;
         a.reopenTime = CSessionSchedule::NextOpen(a.symbol, now);
         return;
        }
      a.sessionEnd = CSessionSchedule::SessionEnd(a.symbol, now);
      datetime nextRoll = CSessionSchedule::NextRollover(now, g_cfg.rolloverOffsetMinutes);
      a.targetTime = (a.sessionEnd > 0 && a.sessionEnd < nextRoll) ? a.sessionEnd : nextRoll;
      a.reopenTime = (a.sessionEnd > 0) ? CSessionSchedule::NextOpen(a.symbol, a.sessionEnd) : 0;
      long closedSecs = (a.reopenTime > a.sessionEnd) ? (long)(a.reopenTime - a.sessionEnd) : 0;
      bool weekendClose = (a.sessionEnd > 0 && a.reopenTime > 0 &&
                           closedSecs >= SAEA_WEEKEND_MIN_GAP_HOURS * 3600);
      if(g_cfg.enableFriday && weekendClose && SAEA_DayOfWeek(now) == FRIDAY)
         a.kind = SAEA_KIND_FRIDAY;
      else
         if(g_cfg.enableMidweek && !weekendClose)
           {
            double r = a.swap.dayRatio[RolledDay(nextRoll)];
            if(!g_cfg.midweekTripleOnly || r >= 2.0)
               a.kind = SAEA_KIND_MIDWEEK;
           }
      a.minutesToTarget = (int)((long)(a.targetTime - now) / 60);
      if(a.minutesToTarget > g_cfg.prepMinutes)
         a.window = SAEA_WIN_IDLE;
      else
         if(a.minutesToTarget >= g_cfg.cutoffMinutes)
            a.window = SAEA_WIN_ACTIVE;
         else
            a.window = SAEA_WIN_CUTOFF;
     }

   bool              Better(const int i, const int j) const
     {
      if(m_items[i].entryReady != m_items[j].entryReady)
         return m_items[i].entryReady;
      if(m_items[i].qualifies != m_items[j].qualifies)
         return m_items[i].qualifies;
      if(m_items[i].qualifies)
         return (m_items[i].netAdvantage > m_items[j].netAdvantage);
      return (m_items[i].netPerLot > m_items[j].netPerLot);
     }

   void              Rank()
     {
      int n = ArraySize(m_items);
      ArrayResize(m_order, n);
      for(int i = 0; i < n; i++)
         m_order[i] = i;
      for(int i = 1; i < n; i++)
        {
         int key = m_order[i];
         int j = i - 1;
         while(j >= 0 && Better(key, m_order[j]))
           {
            m_order[j + 1] = m_order[j];
            j--;
           }
         m_order[j + 1] = key;
        }
     }

   int               TicksLast5Min(const string sym, const datetime now) const
     {
      MqlTick ticks[];
      ulong to = (ulong)now * 1000;
      ulong from = to - 300 * 1000;
      int n = CopyTicksRange(sym, ticks, COPY_TICKS_ALL, from, to);
      return (n < 0) ? 0 : n;
     }

public:
                     COpportunityScanner() : m_universe(NULL), m_swap(NULL), m_cost(NULL),
                     m_risk(NULL), m_trend(NULL), m_lastScan(0) {}

   void              Init(CSymbolUniverse *u, CSwapCalculator *s, CCostModel *c, CRiskManager *r, CTrendFilter *t)
     {
      m_universe = u;
      m_swap = s;
      m_cost = c;
      m_risk = r;
      m_trend = t;
      ArrayResize(m_items, m_universe.Total());
      ArrayResize(m_order, 0);
     }

   void              Analyze(const int idx, const datetime now, SAEAAnalysis &a)
     {
      a.Reset();
      a.symbol = m_universe.Name(idx);
      int ovr = m_universe.MaxSpreadOverride(idx);
      a.maxSpreadPts = (ovr >= 0) ? ovr : g_cfg.maxSpread;

      //--- 1. broker swap specification (fail safe on anything unverifiable)
      if(!m_swap.Read(a.symbol, a.swap))
        {
         a.reason = "UNVERIFIED: " + a.swap.error;
         return;
        }
      a.point = SymbolInfoDouble(a.symbol, SYMBOL_POINT);
      a.digits = (int)SymbolInfoInteger(a.symbol, SYMBOL_DIGITS);
      a.pointValue = m_swap.PointValue(a.symbol);
      a.tradeMode = SymbolInfoInteger(a.symbol, SYMBOL_TRADE_MODE);
      a.weekendMult = a.swap.dayRatio[FRIDAY] + a.swap.dayRatio[SATURDAY] + a.swap.dayRatio[SUNDAY];
      if(a.point <= 0.0 || a.pointValue <= 0.0)
        {
         a.reason = "UNVERIFIED: point / tick value unavailable";
         return;
        }
      MqlTick tick;
      if(!SymbolInfoTick(a.symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
        {
         a.reason = "UNVERIFIED: no quotes";
         return;
        }
      a.bid = tick.bid;
      a.ask = tick.ask;
      a.quoteTime = tick.time;
      a.spreadPts = (int)MathRound((a.ask - a.bid) / a.point);
      if(!CSessionSchedule::HasSchedule(a.symbol))
        {
         a.reason = "UNVERIFIED: no trading-session schedule";
         return;
        }

      //--- 2. schedule and projected hold
      Schedule(a, now);
      datetime entry = (a.window == SAEA_WIN_CLOSED) ? a.reopenTime : now;
      if(entry <= 0 || !ProjectHold(a, entry))
        {
         a.window = SAEA_WIN_UNKNOWN;
         a.reason = "UNVERIFIED: cannot project next session / exit time";
         return;
        }
      a.verified = true;

      //--- 3. economics per lot (deposit currency)
      a.holdLongPerLot = m_swap.HoldValue(a.swap, 1, a.rollMult);
      a.holdShortPerLot = m_swap.HoldValue(a.swap, -1, a.rollMult);
      if(a.holdLongPerLot >= a.holdShortPerLot)
        {
         a.favDir = 1;
         a.favPerLot = a.holdLongPerLot;
         a.oppPerLot = a.holdShortPerLot;
        }
      else
        {
         a.favDir = -1;
         a.favPerLot = a.holdShortPerLot;
         a.oppPerLot = a.holdLongPerLot;
        }
      a.spreadCostPerLot = m_cost.SpreadCostPerLot(a.spreadPts, a.pointValue);
      a.commissionPerLot = m_cost.CommissionPerLot(a.symbol);
      a.costPerLot = a.spreadCostPerLot + a.commissionPerLot + MathMax(0.0, g_cfg.otherCostsPerLot);
      a.netPerLot = a.favPerLot - a.costPerLot;
      a.breakevenPts = (a.netPerLot > 0.0) ? a.netPerLot / a.pointValue : 0.0;

      //--- 4. stress move: historical gap/range percentile, floored at a % of price
      m_cost.GapStats(a.symbol, a.gap);
      double floorPts = ((a.bid + a.ask) * 0.5) * g_cfg.minStressPercent / 100.0 / a.point;
      double histPts = 0.0;
      if(a.gap.valid)
         histPts = ((a.kind == SAEA_KIND_MIDWEEK) ? a.gap.dailyStressPts : a.gap.weekendStressPts) * g_cfg.gapMultiplier;
      a.stressPts = MathMax(histPts, floorPts);

      //--- 5. sizing and totals
      a.lots = m_risk.PlannedLots(a, a.sizingNote);
      a.expectedSwap = a.favPerLot * a.lots;
      a.expectedCost = a.costPerLot * a.lots;
      a.netAdvantage = a.netPerLot * a.lots;
      a.stressLoss = (a.stressPts * a.pointValue + a.costPerLot) * a.lots;

      //--- 6. qualification (economics), first failure wins
      if(a.swap.mode == SYMBOL_SWAP_MODE_DISABLED)
        { a.reason = "swaps disabled for symbol"; return; }
      if(a.rollCount == 0 || a.rollMult <= 0.0)
        { a.reason = "no swap booked in projected hold"; return; }
      if(a.favPerLot <= 0.0)
        { a.reason = "no direction earns positive swap"; return; }
      if(g_cfg.requireOppositeSigns && a.oppPerLot >= 0.0)
        { a.reason = "opposite direction is not charged (no swap asymmetry)"; return; }
      if(!TradeModeAllows(a.tradeMode, a.favDir))
        { a.reason = "symbol trade mode blocks " + SAEA_DirName(a.favDir); return; }
      if(a.netPerLot <= 0.0)
        {
         a.reason = "swap " + SAEA_Money(a.favPerLot) + " <= costs " + SAEA_Money(a.costPerLot) + " per lot";
         return;
        }
      if(!a.gap.valid)
        { a.reason = "gap history unavailable (" + a.gap.note + ")"; return; }
      if(a.lots <= 0.0)
        { a.reason = "size: " + a.sizingNote; return; }
      if(a.netAdvantage < g_cfg.minNetAdvantage)
        {
         a.reason = "net " + SAEA_Money(a.netAdvantage) + " < MinimumNetSwapAdvantage " + SAEA_Money(g_cfg.minNetAdvantage);
         return;
        }
      if(g_cfg.maxWeekendLoss > 0.0 && a.stressLoss > g_cfg.maxWeekendLoss + 0.005)
        {
         a.reason = "stress loss " + SAEA_Money(a.stressLoss) + " > MaximumWeekendLoss";
         return;
        }
      a.qualifies = true;

      //--- 7. entry readiness (timing and live market conditions)
      if(a.kind == SAEA_KIND_NONE)
        { a.reason = "qualifies; not a configured entry day"; return; }
      if(a.window == SAEA_WIN_CLOSED)
        { a.reason = "qualifies; market closed"; return; }
      if(a.window == SAEA_WIN_IDLE)
        {
         a.reason = "qualifies; window opens " + SAEA_TimeHM(a.targetTime - (datetime)(g_cfg.prepMinutes * 60));
         return;
        }
      if(a.window == SAEA_WIN_CUTOFF)
        { a.reason = "qualifies; past entry cutoff"; return; }
      if(a.maxSpreadPts > 0 && a.spreadPts > a.maxSpreadPts)
        {
         a.reason = "spread " + IntegerToString(a.spreadPts) + " > max " + IntegerToString(a.maxSpreadPts);
         return;
        }
      if(g_cfg.maxQuoteAgeSeconds > 0 && (long)(now - a.quoteTime) > g_cfg.maxQuoteAgeSeconds)
        { a.reason = "stale quote (" + IntegerToString((long)(now - a.quoteTime)) + "s)"; return; }
      if(g_cfg.minTicksLast5Min > 0)
        {
         int ticks = TicksLast5Min(a.symbol, now);
         if(ticks < g_cfg.minTicksLast5Min)
           { a.reason = "thin market: " + IntegerToString(ticks) + " ticks/5min"; return; }
        }
      if(g_cfg.useTrendFilter)
        {
         string note = "";
         a.trendDir = m_trend.Direction(a.symbol, note);
         if(a.trendDir != a.favDir)
           {
            a.reason = "trend filter: " + (note != "" ? note : "trend " + SAEA_DirName(a.trendDir));
            return;
           }
        }
      string err = "";
      double price = (a.favDir > 0) ? a.ask : a.bid;
      if(!m_risk.MarginOk(a.symbol, a.favDir, a.lots, price, err))
        { a.reason = err; return; }
      a.entryReady = true;
      a.reason = "ENTRY " + SAEA_DirName(a.favDir) + " " + DoubleToString(a.lots, 2) + " lots, net " + SAEA_Money(a.netAdvantage);
     }

   void              Scan(const datetime now)
     {
      int n = m_universe.Total();
      if(ArraySize(m_items) != n)
         ArrayResize(m_items, n);
      for(int i = 0; i < n; i++)
         Analyze(i, now, m_items[i]);
      Rank();
      m_lastScan = now;
     }

   //--- Re-evaluate a single symbol (used right before sending an order)
   void              Refresh(const int idx, const datetime now)
     {
      if(idx >= 0 && idx < ArraySize(m_items))
         Analyze(idx, now, m_items[idx]);
     }

   int               Total() const { return ArraySize(m_items); }
   int               RankedIndex(const int rank) const { return m_order[rank]; }
   int               RankedTotal() const { return ArraySize(m_order); }
   datetime          LastScan() const { return m_lastScan; }
   int               Find(const string sym) const
     {
      for(int i = 0; i < ArraySize(m_items); i++)
         if(m_items[i].symbol == sym)
            return i;
      return -1;
     }
   void              Get(const int idx, SAEAAnalysis &out) const { out = m_items[idx]; }

   //--- True if any symbol is near its entry target (scan more often)
   bool              AnyWindowNear() const
     {
      for(int i = 0; i < ArraySize(m_items); i++)
         if(m_items[i].kind != SAEA_KIND_NONE &&
            (m_items[i].window == SAEA_WIN_ACTIVE || m_items[i].window == SAEA_WIN_CUTOFF ||
             (m_items[i].window == SAEA_WIN_IDLE && m_items[i].minutesToTarget <= g_cfg.prepMinutes + 15)))
            return true;
      return false;
     }
  };

#endif
//+------------------------------------------------------------------+
