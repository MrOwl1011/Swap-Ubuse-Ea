//+------------------------------------------------------------------+
//|                                              SwapCalculator.mqh  |
//|   Reads broker swap specifications and converts them to the       |
//|   deposit-currency value of ONE rollover for 1.0 lot.             |
//+------------------------------------------------------------------+
#ifndef SAEA_SWAP_CALCULATOR_MQH
#define SAEA_SWAP_CALCULATOR_MQH

#include "Defines.mqh"

//+------------------------------------------------------------------+
//| Converts an amount in any currency to the account currency using |
//| a forex symbol offered by the broker. Fails (returns false)       |
//| instead of guessing when no conversion path exists.               |
//+------------------------------------------------------------------+
class CCurrencyConverter
  {
private:
   string            m_ccy[];      // cached currency
   string            m_target[];   // currency it converts into
   string            m_symbol[];   // symbol used ("" = none found)
   bool              m_inverse[];  // true if symbol is TARGET/CCY

   //--- Spot-style symbols whose price is "target per 1 unit of base" (forex, metals as forex or CFD)
   bool              IsForex(const string sym) const
     {
      ENUM_SYMBOL_CALC_MODE m = (ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(sym, SYMBOL_TRADE_CALC_MODE);
      return (m == SYMBOL_CALC_MODE_FOREX || m == SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE ||
              m == SYMBOL_CALC_MODE_CFD || m == SYMBOL_CALC_MODE_CFDLEVERAGE);
     }

   int               Lookup(const string ccy, const string target)
     {
      for(int i = 0; i < ArraySize(m_ccy); i++)
         if(m_ccy[i] == ccy && m_target[i] == target)
            return i;
      //--- not cached yet: search the broker's symbol list once
      string found = "";
      bool inverse = false;
      int total = SymbolsTotal(false);
      for(int i = 0; i < total && found == ""; i++)
        {
         string s = SymbolName(i, false);
         if(!IsForex(s))
            continue;
         string base = SymbolInfoString(s, SYMBOL_CURRENCY_BASE);
         string prof = SymbolInfoString(s, SYMBOL_CURRENCY_PROFIT);
         if(base == ccy && prof == target)
           {
            found = s;
            inverse = false;
           }
         else
            if(base == target && prof == ccy)
              {
               found = s;
               inverse = true;
              }
        }
      if(found != "")
         SymbolSelect(found, true);
      int n = ArraySize(m_ccy);
      ArrayResize(m_ccy, n + 1);
      ArrayResize(m_target, n + 1);
      ArrayResize(m_symbol, n + 1);
      ArrayResize(m_inverse, n + 1);
      m_ccy[n] = ccy;
      m_target[n] = target;
      m_symbol[n] = found;
      m_inverse[n] = inverse;
      return n;
     }

   //--- rate = units of target per 1 unit of ccy (single hop)
   bool              DirectRate(const string ccy, const string target, double &rate, string &via)
     {
      if(ccy == target)
        {
         rate = 1.0;
         via = "";
         return true;
        }
      int k = Lookup(ccy, target);
      if(m_symbol[k] == "")
         return false;
      MqlTick t;
      if(!SymbolInfoTick(m_symbol[k], t) || t.bid <= 0.0 || t.ask <= 0.0)
         return false;
      double mid = (t.bid + t.ask) * 0.5;
      rate = m_inverse[k] ? 1.0 / mid : mid;
      via = m_symbol[k];
      return true;
     }

public:
   bool              ToDeposit(const string ccy, const double amount, double &out, string &err)
     {
      string dep = AccountInfoString(ACCOUNT_CURRENCY);
      double r1 = 0.0, r2 = 0.0;
      string v1 = "", v2 = "";
      if(DirectRate(ccy, dep, r1, v1))
        {
         out = amount * r1;
         return true;
        }
      //--- one cross via USD (e.g. XAU -> USD -> EUR)
      if(ccy != "USD" && dep != "USD" &&
         DirectRate(ccy, "USD", r1, v1) && DirectRate("USD", dep, r2, v2))
        {
         out = amount * r1 * r2;
         return true;
        }
      err = "no conversion path " + ccy + "->" + dep;
      return false;
     }
  };

//+------------------------------------------------------------------+
//| Swap specification reader                                        |
//+------------------------------------------------------------------+
class CSwapCalculator
  {
private:
   CCurrencyConverter m_conv;

   bool              ReadDayRatios(const string sym, SAEASwapSpec &spec)
     {
      ENUM_SYMBOL_INFO_DOUBLE props[7] =
        {
         SYMBOL_SWAP_SUNDAY, SYMBOL_SWAP_MONDAY, SYMBOL_SWAP_TUESDAY, SYMBOL_SWAP_WEDNESDAY,
         SYMBOL_SWAP_THURSDAY, SYMBOL_SWAP_FRIDAY, SYMBOL_SWAP_SATURDAY
        };
      double sum = 0.0;
      bool ok = true;
      for(int d = 0; d < 7; d++)
        {
         double r = 0.0;
         if(!SymbolInfoDouble(sym, props[d], r))
            ok = false;
         if(r < 0.0)
            ok = false;
         spec.dayRatio[d] = r;
         sum += r;
        }
      if(ok && sum > 0.0)
        {
         spec.brokerDayRatios = true;
         return true;
        }
      //--- Broker did not publish per-day ratios: use the classic MT5 model
      //--- (one swap per weekday rollover, triple on SYMBOL_SWAP_ROLLOVER3DAYS,
      //---  no rollover booked from Saturday or Sunday).
      for(int d = 0; d < 7; d++)
         spec.dayRatio[d] = (d == SATURDAY || d == SUNDAY) ? 0.0 : 1.0;
      if(spec.tripleDay >= 0 && spec.tripleDay <= 6)
         spec.dayRatio[spec.tripleDay] = 3.0;
      spec.brokerDayRatios = false;
      return true;
     }

   bool              MoneyMode(const string sym, const string ccy, SAEASwapSpec &spec)
     {
      double l = 0.0, s = 0.0;
      string err = "";
      if(ccy == "")
        {
         spec.error = "swap currency not reported by broker";
         return false;
        }
      if(!m_conv.ToDeposit(ccy, spec.swapLong, l, err) || !m_conv.ToDeposit(ccy, spec.swapShort, s, err))
        {
         spec.error = err;
         return false;
        }
      spec.longPerLot = l;
      spec.shortPerLot = s;
      spec.basis = "money per lot in " + ccy + (ccy == AccountInfoString(ACCOUNT_CURRENCY) ? "" : " (converted)");
      return true;
     }

public:
   //--- Value of one point for 1.0 lot in deposit currency (0 if unverifiable)
   double            PointValue(const string sym)
     {
      double point = 0.0, tickSize = 0.0, tickValue = 0.0;
      if(!SymbolInfoDouble(sym, SYMBOL_POINT, point) ||
         !SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE, tickSize) ||
         !SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE, tickValue))
         return 0.0;
      if(point <= 0.0 || tickSize <= 0.0 || tickValue <= 0.0)
         return 0.0;
      return tickValue * point / tickSize;
     }

   bool              Read(const string sym, SAEASwapSpec &spec)
     {
      spec.Reset();
      long modeL = 0, tri = 0;
      if(!SymbolInfoInteger(sym, SYMBOL_SWAP_MODE, modeL))
        {
         spec.error = "SYMBOL_SWAP_MODE unavailable";
         return false;
        }
      spec.mode = (ENUM_SYMBOL_SWAP_MODE)modeL;
      if(!SymbolInfoDouble(sym, SYMBOL_SWAP_LONG, spec.swapLong) ||
         !SymbolInfoDouble(sym, SYMBOL_SWAP_SHORT, spec.swapShort))
        {
         spec.error = "swap rates unavailable";
         return false;
        }
      if(!SymbolInfoInteger(sym, SYMBOL_SWAP_ROLLOVER3DAYS, tri))
        {
         spec.error = "triple-swap day unavailable";
         return false;
        }
      spec.tripleDay = (int)tri;
      ReadDayRatios(sym, spec);

      double pointValue = PointValue(sym);
      double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      MqlTick tick;
      bool haveTick = (SymbolInfoTick(sym, tick) && tick.bid > 0.0 && tick.ask > 0.0);

      switch(spec.mode)
        {
         case SYMBOL_SWAP_MODE_DISABLED:
            spec.longPerLot = 0.0;
            spec.shortPerLot = 0.0;
            spec.basis = "swaps disabled by broker";
            break;

         case SYMBOL_SWAP_MODE_POINTS:
         case SYMBOL_SWAP_MODE_REOPEN_CURRENT:
         case SYMBOL_SWAP_MODE_REOPEN_BID:
            if(pointValue <= 0.0)
              {
               spec.error = "tick value/size unavailable, cannot value swap points";
               return false;
              }
            spec.longPerLot = spec.swapLong * pointValue;
            spec.shortPerLot = spec.swapShort * pointValue;
            spec.basis = "points x point value (" + DoubleToString(pointValue, 4) + "/pt/lot)";
            if(spec.mode != SYMBOL_SWAP_MODE_POINTS)
              {
               //--- Reopen modes shift the reopen price by N points: the P&L effect equals N points,
               //--- but it is booked in the position price, not the swap field.
               spec.approximate = true;
               spec.basis = "reopen mode modelled as points x point value";
              }
            break;

         case SYMBOL_SWAP_MODE_CURRENCY_SYMBOL:
            if(!MoneyMode(sym, SymbolInfoString(sym, SYMBOL_CURRENCY_BASE), spec))
               return false;
            break;

         case SYMBOL_SWAP_MODE_CURRENCY_MARGIN:
            if(!MoneyMode(sym, SymbolInfoString(sym, SYMBOL_CURRENCY_MARGIN), spec))
               return false;
            break;

         case SYMBOL_SWAP_MODE_CURRENCY_PROFIT:
            if(!MoneyMode(sym, SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT), spec))
               return false;
            break;

         case SYMBOL_SWAP_MODE_CURRENCY_DEPOSIT:
            spec.longPerLot = spec.swapLong;
            spec.shortPerLot = spec.swapShort;
            spec.basis = "money per lot in deposit currency";
            break;

         case SYMBOL_SWAP_MODE_INTEREST_CURRENT:
         case SYMBOL_SWAP_MODE_INTEREST_OPEN:
           {
            if(!haveTick || tickSize <= 0.0 || tickValue <= 0.0)
              {
               spec.error = "price or tick value unavailable for interest-mode swap";
               return false;
              }
            //--- notional of 1 lot in deposit ccy = price / tickSize * tickValue
            double price = (tick.bid + tick.ask) * 0.5;
            double notional = price / tickSize * tickValue;
            //--- MT5 interest modes use a 360-day bank year
            spec.longPerLot = notional * spec.swapLong / 100.0 / 360.0;
            spec.shortPerLot = notional * spec.swapShort / 100.0 / 360.0;
            spec.basis = "annual % of notional " + DoubleToString(notional, 0) + " / 360";
            if(spec.mode == SYMBOL_SWAP_MODE_INTEREST_OPEN)
               spec.basis += " (open price ~ current)";
            break;
           }

         default:
            spec.error = "unsupported swap mode " + SAEA_SwapModeName(spec.mode);
            return false;
        }
      spec.valid = true;
      return true;
     }

   //--- Projected swap for one direction over a given rollover multiplier (deposit ccy, 1.0 lot)
   double            HoldValue(const SAEASwapSpec &spec, const int dir, const double rollMult) const
     {
      if(dir > 0)
         return spec.longPerLot * rollMult;
      if(dir < 0)
         return spec.shortPerLot * rollMult;
      return 0.0;
     }

   string            DayRatioText(const SAEASwapSpec &spec) const
     {
      string s = "";
      for(int d = 0; d < 7; d++)
         s += StringSubstr(SAEA_DayName(d), 0, 2) + DoubleToString(spec.dayRatio[d], 0) + " ";
      s += spec.brokerDayRatios ? "(broker)" : "(derived)";
      return s;
     }
  };

#endif
//+------------------------------------------------------------------+
