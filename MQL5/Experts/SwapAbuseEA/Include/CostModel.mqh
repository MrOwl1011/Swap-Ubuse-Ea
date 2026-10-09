//+------------------------------------------------------------------+
//|                                                   CostModel.mqh  |
//|   Trading-cost and adverse-move estimates:                        |
//|   - round-trip spread cost (entry spread + widened exit spread)   |
//|   - commission (input, optionally raised by account history)      |
//|   - historical weekend gaps and daily ranges (stress move)        |
//+------------------------------------------------------------------+
#ifndef SAEA_COST_MODEL_MQH
#define SAEA_COST_MODEL_MQH

#include "Defines.mqh"

class CCostModel
  {
private:
   string            m_gapSym[];
   SAEAGapStats      m_gap[];
   string            m_comSym[];
   double            m_comValue[];
   datetime          m_comTime[];

   static double     Percentile(double &values[], const double pct)
     {
      int n = ArraySize(values);
      if(n <= 0)
         return 0.0;
      ArraySort(values);
      int idx = (int)MathCeil(pct / 100.0 * n) - 1;
      if(idx < 0)
         idx = 0;
      if(idx > n - 1)
         idx = n - 1;
      return values[idx];
     }

   bool              ComputeGaps(const string sym, SAEAGapStats &g)
     {
      g.Reset();
      g.computedAt = TimeCurrent();
      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      if(point <= 0.0)
        {
         g.note = "point size unavailable";
         return false;
        }
      //--- weekend gaps from H1: a jump of >= 36h between bars is a weekend / holiday closure
      MqlRates h1[];
      int want = g_cfg.gapLookbackWeeks * 5 * 24 + 72;
      int n = CopyRates(sym, PERIOD_H1, 0, want, h1);
      if(n < 48)
        {
         g.note = "H1 history not loaded yet";
         return false;
        }
      double gaps[];
      for(int i = 1; i < n; i++)
        {
         if((long)(h1[i].time - h1[i - 1].time) >= 36 * 3600)
           {
            int k = ArraySize(gaps);
            ArrayResize(gaps, k + 1);
            gaps[k] = MathAbs(h1[i].open - h1[i - 1].close) / point;
           }
        }
      //--- daily ranges from D1 (stress for single-night holds)
      MqlRates d1[];
      int nd = CopyRates(sym, PERIOD_D1, 1, g_cfg.gapLookbackWeeks * 5, d1);
      double ranges[];
      for(int i = 0; i < nd; i++)
        {
         double r = (d1[i].high - d1[i].low) / point;
         if(r <= 0.0)
            continue;
         int k = ArraySize(ranges);
         ArrayResize(ranges, k + 1);
         ranges[k] = r;
        }
      g.samples = ArraySize(gaps);
      if(g.samples < 4 || ArraySize(ranges) < 10)
        {
         g.note = "insufficient history (" + IntegerToString(g.samples) + " weekend gaps, " +
                  IntegerToString(ArraySize(ranges)) + " daily bars)";
         return false;
        }
      g.weekendMedianPts = Percentile(gaps, 50.0);
      g.weekendStressPts = Percentile(gaps, g_cfg.gapPercentile);
      g.dailyMedianPts = Percentile(ranges, 50.0);
      g.dailyStressPts = Percentile(ranges, g_cfg.gapPercentile);
      g.valid = true;
      g.note = IntegerToString(g.samples) + " weekend gaps";
      return true;
     }

public:
   //--- Cached per symbol, refreshed every 12 hours or while invalid (every 5 minutes)
   void              GapStats(const string sym, SAEAGapStats &out)
     {
      int idx = -1;
      for(int i = 0; i < ArraySize(m_gapSym); i++)
         if(m_gapSym[i] == sym)
           {
            idx = i;
            break;
           }
      datetime now = TimeCurrent();
      if(idx >= 0)
        {
         int ttl = m_gap[idx].valid ? 12 * 3600 : 300;
         if((long)(now - m_gap[idx].computedAt) < ttl)
           {
            out = m_gap[idx];
            return;
           }
        }
      else
        {
         idx = ArraySize(m_gapSym);
         ArrayResize(m_gapSym, idx + 1);
         ArrayResize(m_gap, idx + 1);
         m_gapSym[idx] = sym;
        }
      ComputeGaps(sym, m_gap[idx]);
      out = m_gap[idx];
     }

   //--- Round trip relative to mid: half the entry spread + half the (widened) exit spread
   double            SpreadCostPerLot(const int spreadPts, const double pointValue) const
     {
      double exitSpread = spreadPts * MathMax(1.0, g_cfg.exitSpreadMultiplier);
      return (spreadPts + exitSpread) * 0.5 * pointValue;
     }

   //--- Round-trip commission per lot: max(input, observed in recent account history)
   double            CommissionPerLot(const string sym)
     {
      double configured = MathMax(0.0, g_cfg.commissionPerLotRT);
      if(!g_cfg.autoDetectCommission)
         return configured;
      int idx = -1;
      for(int i = 0; i < ArraySize(m_comSym); i++)
         if(m_comSym[i] == sym)
           {
            idx = i;
            break;
           }
      datetime now = TimeCurrent();
      if(idx >= 0 && (long)(now - m_comTime[idx]) < 24 * 3600)
         return MathMax(configured, m_comValue[idx]);
      double detected = 0.0;
      if(HistorySelect(now - 90 * SAEA_SECONDS_PER_DAY, now))
        {
         for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
           {
            ulong deal = HistoryDealGetTicket(i);
            if(deal == 0 || HistoryDealGetString(deal, DEAL_SYMBOL) != sym)
               continue;
            double vol = HistoryDealGetDouble(deal, DEAL_VOLUME);
            double com = HistoryDealGetDouble(deal, DEAL_COMMISSION);
            if(vol <= 0.0 || com == 0.0)
               continue;
            //--- per-side charge doubled: conservative if the broker charges round trip at entry
            detected = MathAbs(com) / vol * 2.0;
            break;
           }
        }
      if(idx < 0)
        {
         idx = ArraySize(m_comSym);
         ArrayResize(m_comSym, idx + 1);
         ArrayResize(m_comValue, idx + 1);
         ArrayResize(m_comTime, idx + 1);
         m_comSym[idx] = sym;
        }
      m_comValue[idx] = detected;
      m_comTime[idx] = now;
      return MathMax(configured, detected);
     }
  };

#endif
//+------------------------------------------------------------------+
