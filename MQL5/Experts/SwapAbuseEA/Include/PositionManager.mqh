//+------------------------------------------------------------------+
//|                                             PositionManager.mqh  |
//|   Decides HOLD / REDUCE / CLOSE for every position of this EA.    |
//+------------------------------------------------------------------+
#ifndef SAEA_POSITION_MANAGER_MQH
#define SAEA_POSITION_MANAGER_MQH

#include "Defines.mqh"
#include "SwapCalculator.mqh"
#include "SessionSchedule.mqh"
#include "RiskManager.mqh"
#include "OpportunityScanner.mqh"
#include "TradeExecutor.mqh"
#include "TradeLogger.mqh"

class CPositionManager
  {
private:
   CSwapCalculator     *m_swap;
   CRiskManager        *m_risk;
   COpportunityScanner *m_scan;
   CTradeExecutor      *m_exec;
   CTradeLogger        *m_log;
   ulong                m_stateTicket[];
   string               m_stateText[];
   string               m_lastAction;
   ulong                m_tryTicket[];
   datetime             m_tryTime[];

   //--- At most one close/reduce request per position every 30 seconds
   bool              CanAttempt(const ulong ticket)
     {
      datetime now = TimeCurrent();
      for(int i = 0; i < ArraySize(m_tryTicket); i++)
         if(m_tryTicket[i] == ticket)
           {
            if((long)(now - m_tryTime[i]) < 30)
               return false;
            m_tryTime[i] = now;
            return true;
           }
      int n = ArraySize(m_tryTicket);
      ArrayResize(m_tryTicket, n + 1);
      ArrayResize(m_tryTime, n + 1);
      m_tryTicket[n] = ticket;
      m_tryTime[n] = now;
      return true;
     }

   //--- Log a HOLD reason only when it changes for that ticket
   void              NoteState(const SAEAPosition &p, const string text)
     {
      for(int i = 0; i < ArraySize(m_stateTicket); i++)
         if(m_stateTicket[i] == p.ticket)
           {
            if(m_stateText[i] != text)
              {
               m_stateText[i] = text;
               SAEA_Log("HOLD " + p.symbol + " #" + IntegerToString((long)p.ticket) + " | " + text);
              }
            return;
           }
      int n = ArraySize(m_stateTicket);
      ArrayResize(m_stateTicket, n + 1);
      ArrayResize(m_stateText, n + 1);
      m_stateTicket[n] = p.ticket;
      m_stateText[n] = text;
      SAEA_Log("HOLD " + p.symbol + " #" + IntegerToString((long)p.ticket) + " | " + text);
     }

   void              DoClose(const SAEAPosition &p, const string why)
     {
      if(!CanAttempt(p.ticket))
         return;
      string res = "";
      bool ok = m_exec.Close(p, res);
      m_lastAction = (ok ? "CLOSE " : "CLOSE FAILED ") + p.symbol + ": " + why;
      m_log.Action(p.symbol, ok ? "CLOSE" : "CLOSE_FAILED", why + " | " + res);
     }

   void              DoReduce(const SAEAPosition &p, const double volume, const string why)
     {
      if(!CanAttempt(p.ticket))
         return;
      string res = "";
      bool ok = m_exec.Reduce(p, volume, res);
      m_lastAction = (ok ? "REDUCE " : "REDUCE FAILED ") + p.symbol + " by " + DoubleToString(volume, 2) + ": " + why;
      m_log.Action(p.symbol, ok ? "REDUCE" : "REDUCE_FAILED",
                   why + " | by " + DoubleToString(volume, 2) + " | " + res);
     }

public:
                     CPositionManager() : m_swap(NULL), m_risk(NULL), m_scan(NULL), m_exec(NULL), m_log(NULL), m_lastAction("") {}

   void              Init(CSwapCalculator *s, CRiskManager *r, COpportunityScanner *sc, CTradeExecutor *e, CTradeLogger *l)
     {
      m_swap = s;
      m_risk = r;
      m_scan = sc;
      m_exec = e;
      m_log = l;
     }

   string            LastAction() const { return m_lastAction; }

   int               Collect(SAEAPosition &out[]) const
     {
      ArrayResize(out, 0);
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0 || PositionGetInteger(POSITION_MAGIC) != g_cfg.magic)
            continue;
         int n = ArraySize(out);
         ArrayResize(out, n + 1);
         out[n].ticket = t;
         out[n].symbol = PositionGetString(POSITION_SYMBOL);
         out[n].dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         out[n].volume = PositionGetDouble(POSITION_VOLUME);
         out[n].openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         out[n].openTime = (datetime)PositionGetInteger(POSITION_TIME);
         out[n].swap = PositionGetDouble(POSITION_SWAP);
         out[n].profit = PositionGetDouble(POSITION_PROFIT);
        }
      return ArraySize(out);
     }

   //--- Any EA position on this symbol (returns its direction)
   bool              HasPosition(const string sym, int &dir) const
     {
      dir = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0 || PositionGetInteger(POSITION_MAGIC) != g_cfg.magic || PositionGetString(POSITION_SYMBOL) != sym)
            continue;
         dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         return true;
        }
      return false;
     }

   //--- Netting accounts hold one position per symbol: never trade into someone else's position
   bool              ForeignPositionOn(const string sym) const
     {
      if(SAEA_IsHedging())
         return false;
      if(!PositionSelect(sym))
         return false;
      return (PositionGetInteger(POSITION_MAGIC) != g_cfg.magic);
     }

   void              Manage(const datetime now)
     {
      SAEAPosition pos[];
      int n = Collect(pos);
      for(int i = 0; i < n; i++)
        {
         SAEAPosition p;
         p = pos[i];
         if(!CSessionSchedule::IsOpen(p.symbol, now))
           {
            NoteState(p, "market closed, holding");
            continue;
           }
         SAEASwapSpec spec;
         bool specOk = m_swap.Read(p.symbol, spec);
         double perRoll = specOk ? ((p.dir > 0) ? spec.longPerLot : spec.shortPerLot) : 0.0;
         int passed = CSessionSchedule::CountRollovers(p.openTime, now, g_cfg.rolloverOffsetMinutes);

         //--- 1. swap turned against the position
         if(specOk && g_cfg.closeOnSwapFlip && perRoll < 0.0)
           {
            DoClose(p, "held direction now pays swap (" + SAEA_Money(perRoll) + "/lot/rollover)");
            continue;
           }

         //--- 2. scheduled exit after the planned rollovers
         if(g_cfg.exitMode == SAEA_EXIT_AFTER_ROLLOVERS)
           {
            datetime exitAt = CSessionSchedule::EstimateExit(p.symbol, p.openTime, g_cfg.holdRollovers,
                                                             g_cfg.rolloverOffsetMinutes, g_cfg.exitDelayMinutes);
            if(exitAt > 0 && now >= exitAt)
              {
               int idx = m_scan.Find(p.symbol);
               int spread = (int)SymbolInfoInteger(p.symbol, SYMBOL_SPREAD);
               int maxSpread = g_cfg.maxSpread;
               if(idx >= 0)
                 {
                  SAEAAnalysis a;
                  m_scan.Get(idx, a);
                  maxSpread = a.maxSpreadPts;
                 }
               bool forced = (now >= exitAt + (datetime)(g_cfg.exitMaxWaitMinutes * 60));
               if(maxSpread <= 0 || spread <= maxSpread || forced)
                 {
                  DoClose(p, IntegerToString(passed) + " rollover(s) booked, swap " + SAEA_Money(p.swap) +
                          (forced ? " (forced after ExitMaxWaitMinutes, spread " + IntegerToString(spread) + ")" : ""));
                  continue;
                 }
               NoteState(p, "exit due, waiting for spread " + IntegerToString(spread) + " <= " + IntegerToString(maxSpread));
               continue;
              }
           }

         //--- 3. exposure limits
         if(g_cfg.reduceToLimits)
           {
            double total = m_risk.TotalLots();
            if(g_cfg.maxTotalLots > 0.0 && total > g_cfg.maxTotalLots + 1e-9)
              {
               double excess = MathMin(total - g_cfg.maxTotalLots, p.volume);
               double step = SymbolInfoDouble(p.symbol, SYMBOL_VOLUME_STEP);
               if(step > 0.0)
                  excess = MathCeil(excess / step - 1e-9) * step;
               DoReduce(p, excess, "total lots " + DoubleToString(total, 2) + " > MaximumTotalLots");
               continue;
              }
            int idx = m_scan.Find(p.symbol);
            if(idx >= 0 && g_cfg.maxWeekendLoss > 0.0)
              {
               SAEAAnalysis a;
               m_scan.Get(idx, a);
               bool beforeWeekend = (a.kind == SAEA_KIND_FRIDAY &&
                                     (a.window == SAEA_WIN_ACTIVE || a.window == SAEA_WIN_CUTOFF));
               double gapPerLot = a.stressPts * a.pointValue;
               if(beforeWeekend && gapPerLot > 0.0 && gapPerLot * p.volume > g_cfg.maxWeekendLoss + 0.005)
                 {
                  double keep = m_risk.NormalizeVolume(p.symbol, g_cfg.maxWeekendLoss / gapPerLot);
                  double cut = p.volume - keep;
                  if(cut > 0.0)
                    {
                     DoReduce(p, cut, "weekend stress loss " + SAEA_Money(gapPerLot * p.volume) + " > MaximumWeekendLoss");
                     continue;
                    }
                 }
              }
           }

         //--- 4. hold
         string why = specOk ? "collecting " + SAEA_Money(perRoll * p.volume) + "/rollover" : "swap unverifiable, holding";
         if(g_cfg.exitMode == SAEA_EXIT_AFTER_ROLLOVERS)
            why += ", " + IntegerToString(passed) + "/" + IntegerToString(g_cfg.holdRollovers) + " rollovers";
         NoteState(p, why);
        }
     }
  };

#endif
//+------------------------------------------------------------------+
