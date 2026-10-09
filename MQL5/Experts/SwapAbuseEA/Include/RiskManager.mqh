//+------------------------------------------------------------------+
//|                                                 RiskManager.mqh  |
//|   Position sizing, exposure limits, volume and margin checks.     |
//+------------------------------------------------------------------+
#ifndef SAEA_RISK_MANAGER_MQH
#define SAEA_RISK_MANAGER_MQH

#include "Defines.mqh"

class CRiskManager
  {
public:
   //--- Round DOWN to the volume step; 0 if below the minimum volume
   double            NormalizeVolume(const string sym, const double lots) const
     {
      double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
      double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
      if(vmin <= 0.0 || step <= 0.0)
         return 0.0;
      double v = MathMin(lots, vmax > 0.0 ? vmax : lots);
      v = MathFloor(v / step + 1e-9) * step;
      if(v < vmin - 1e-9)
         return 0.0;
      int stepDigits = 0;
      while(stepDigits < 8 && MathAbs(step * MathPow(10, stepDigits) - MathRound(step * MathPow(10, stepDigits))) > 1e-9)
         stepDigits++;
      return NormalizeDouble(v, stepDigits);
     }

   //--- EA positions / lots (all symbols, this magic number)
   int               OpenPositions() const
     {
      int n = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong t = PositionGetTicket(i);
         if(t != 0 && PositionGetInteger(POSITION_MAGIC) == g_cfg.magic)
            n++;
        }
      return n;
     }

   double            TotalLots() const
     {
      double v = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong t = PositionGetTicket(i);
         if(t != 0 && PositionGetInteger(POSITION_MAGIC) == g_cfg.magic)
            v += PositionGetDouble(POSITION_VOLUME);
        }
      return v;
     }

   //--- Lots already open on a symbol in one direction (all magics) for SYMBOL_VOLUME_LIMIT
   double            SymbolDirectionLots(const string sym, const int dir) const
     {
      double v = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0 || PositionGetString(POSITION_SYMBOL) != sym)
            continue;
         long type = PositionGetInteger(POSITION_TYPE);
         if((dir > 0 && type == POSITION_TYPE_BUY) || (dir < 0 && type == POSITION_TYPE_SELL))
            v += PositionGetDouble(POSITION_VOLUME);
        }
      return v;
     }

   //--- Worst-case loss per 1.0 lot used for sizing: max(stress move, stop distance) + costs.
   //--- A stop-loss does NOT cap a gap: if price opens beyond the stop the fill is at the gap price.
   double            RiskPerLot(const SAEAAnalysis &a) const
     {
      double movePts = a.stressPts;
      if(g_cfg.useStopLoss && g_cfg.stopLossPoints > movePts)
         movePts = g_cfg.stopLossPoints;
      return movePts * a.pointValue + a.costPerLot;
     }

   //--- Planned lot size for a new entry, after all caps. Returns 0 and a note if impossible.
   double            PlannedLots(const SAEAAnalysis &a, string &note) const
     {
      note = "";
      double riskPerLot = RiskPerLot(a);
      if(a.pointValue <= 0.0 || riskPerLot <= 0.0)
        {
         note = "cannot value risk per lot";
         return 0.0;
        }
      double lots = g_cfg.fixedLot;
      if(g_cfg.useRiskSizing)
        {
         double equity = AccountInfoDouble(ACCOUNT_EQUITY);
         lots = equity * g_cfg.riskPercent / 100.0 / riskPerLot;
         note = "risk " + DoubleToString(g_cfg.riskPercent, 2) + "%";
        }
      else
         note = "fixed";

      //--- cap: maximum projected weekend (stress) loss
      double stressPerLot = a.stressPts * a.pointValue + a.costPerLot;
      if(g_cfg.maxWeekendLoss > 0.0 && stressPerLot > 0.0)
        {
         double cap = g_cfg.maxWeekendLoss / stressPerLot;
         if(cap < lots)
           {
            lots = cap;
            note += ", capped by MaximumWeekendLoss";
           }
        }
      //--- cap: total EA lots
      if(g_cfg.maxTotalLots > 0.0)
        {
         double room = g_cfg.maxTotalLots - TotalLots();
         if(room < lots)
           {
            lots = MathMax(0.0, room);
            note += ", capped by MaximumTotalLots";
           }
        }
      //--- cap: broker per-symbol, per-direction volume limit
      double limit = SymbolInfoDouble(a.symbol, SYMBOL_VOLUME_LIMIT);
      if(limit > 0.0)
        {
         double room = limit - SymbolDirectionLots(a.symbol, a.favDir);
         if(room < lots)
           {
            lots = MathMax(0.0, room);
            note += ", capped by SYMBOL_VOLUME_LIMIT";
           }
        }
      double norm = NormalizeVolume(a.symbol, lots);
      if(norm <= 0.0)
         note += ", below minimum volume";
      return norm;
     }

   //--- Margin needed vs. free margin (MaxMarginUsePercent of free margin)
   bool              MarginOk(const string sym, const int dir, const double lots, const double price, string &err) const
     {
      double margin = 0.0;
      ENUM_ORDER_TYPE type = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(!OrderCalcMargin(type, sym, lots, price, margin))
        {
         err = "OrderCalcMargin failed (" + IntegerToString(GetLastError()) + ")";
         return false;
        }
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      double allowed = freeMargin * g_cfg.maxMarginUsePercent / 100.0;
      if(margin > allowed)
        {
         err = "margin " + SAEA_Money(margin) + " > allowed " + SAEA_Money(allowed);
         return false;
        }
      return true;
     }
  };

#endif
//+------------------------------------------------------------------+
