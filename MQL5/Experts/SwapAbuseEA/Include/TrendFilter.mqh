//+------------------------------------------------------------------+
//|                                                 TrendFilter.mqh  |
//|   Optional EMA trend confirmation (fast vs slow, last closed bar) |
//+------------------------------------------------------------------+
#ifndef SAEA_TREND_FILTER_MQH
#define SAEA_TREND_FILTER_MQH

#include "Defines.mqh"

class CTrendFilter
  {
private:
   string            m_sym[];
   int               m_fast[];
   int               m_slow[];

   int               Slot(const string sym)
     {
      for(int i = 0; i < ArraySize(m_sym); i++)
         if(m_sym[i] == sym)
            return i;
      int n = ArraySize(m_sym);
      ArrayResize(m_sym, n + 1);
      ArrayResize(m_fast, n + 1);
      ArrayResize(m_slow, n + 1);
      m_sym[n] = sym;
      m_fast[n] = iMA(sym, g_cfg.trendTimeframe, g_cfg.trendFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
      m_slow[n] = iMA(sym, g_cfg.trendTimeframe, g_cfg.trendSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
      return n;
     }

public:
   //--- +1 up, -1 down, 0 unknown / flat. Handles are created on first use per symbol.
   int               Direction(const string sym, string &note)
     {
      int i = Slot(sym);
      if(m_fast[i] == INVALID_HANDLE || m_slow[i] == INVALID_HANDLE)
        {
         note = "trend indicator unavailable";
         return 0;
        }
      double f[], s[];
      if(CopyBuffer(m_fast[i], 0, 1, 1, f) != 1 || CopyBuffer(m_slow[i], 0, 1, 1, s) != 1)
        {
         note = "trend data not ready";
         return 0;
        }
      if(f[0] > s[0])
         return 1;
      if(f[0] < s[0])
         return -1;
      note = "trend flat";
      return 0;
     }

   void              Release()
     {
      for(int i = 0; i < ArraySize(m_sym); i++)
        {
         if(m_fast[i] != INVALID_HANDLE)
            IndicatorRelease(m_fast[i]);
         if(m_slow[i] != INVALID_HANDLE)
            IndicatorRelease(m_slow[i]);
        }
      ArrayResize(m_sym, 0);
      ArrayResize(m_fast, 0);
      ArrayResize(m_slow, 0);
     }
  };

#endif
//+------------------------------------------------------------------+
