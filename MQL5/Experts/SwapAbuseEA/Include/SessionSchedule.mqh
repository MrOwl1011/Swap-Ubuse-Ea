//+------------------------------------------------------------------+
//|                                             SessionSchedule.mqh  |
//|   Trading-session and rollover arithmetic in broker server time.  |
//|   Uses SymbolInfoSessionTrade(); holidays that are not part of    |
//|   the weekly schedule are NOT visible through this API.           |
//+------------------------------------------------------------------+
#ifndef SAEA_SESSION_SCHEDULE_MQH
#define SAEA_SESSION_SCHEDULE_MQH

#include "Defines.mqh"

#define SAEA_SESSION_JOIN_SECONDS 60   // sessions closer than this are treated as continuous

class CSessionSchedule
  {
public:
   //--- Trade sessions of one weekday as seconds since 00:00 (to <= 86400)
   static bool       DaySessions(const string sym, const int dow, long &from[], long &to[])
     {
      ArrayResize(from, 0);
      ArrayResize(to, 0);
      for(uint i = 0; i < 16; i++)
        {
         datetime f = 0, t = 0;
         if(!SymbolInfoSessionTrade(sym, (ENUM_DAY_OF_WEEK)dow, i, f, t))
            break;
         long lf = (long)f;
         long lt = (long)t;
         if(lf < 0)
            lf = 0;
         if(lt <= lf || lt > SAEA_SECONDS_PER_DAY)
            lt = SAEA_SECONDS_PER_DAY;   // "00:00" end means 24:00
         if(lf >= SAEA_SECONDS_PER_DAY)
            continue;
         int n = ArraySize(from);
         ArrayResize(from, n + 1);
         ArrayResize(to, n + 1);
         from[n] = lf;
         to[n] = lt;
        }
      return (ArraySize(from) > 0);
     }

   static bool       HasSchedule(const string sym)
     {
      long f[], t[];
      for(int d = 0; d < 7; d++)
         if(DaySessions(sym, d, f, t))
            return true;
      return false;
     }

   static bool       IsOpen(const string sym, const datetime when)
     {
      datetime ds = SAEA_DayStart(when);
      long sec = (long)(when - ds);
      long f[], t[];
      if(!DaySessions(sym, SAEA_DayOfWeek(when), f, t))
         return false;
      for(int k = 0; k < ArraySize(f); k++)
         if(sec >= f[k] && sec < t[k])
            return true;
      return false;
     }

   //--- End of the contiguous trading period that contains 'when' (0 if closed).
   //--- Sessions that touch across midnight (24:00 -> 00:00) are chained.
   static datetime   SessionEnd(const string sym, const datetime when)
     {
      if(!IsOpen(sym, when))
         return 0;
      datetime cur = when;
      for(int guard = 0; guard < 32; guard++)
        {
         datetime ds = SAEA_DayStart(cur);
         long sec = (long)(cur - ds);
         long f[], t[];
         bool extended = false;
         if(DaySessions(sym, SAEA_DayOfWeek(cur), f, t))
           {
            for(int k = 0; k < ArraySize(f); k++)
              {
               if(f[k] <= sec + SAEA_SESSION_JOIN_SECONDS && t[k] > sec)
                 {
                  cur = ds + (datetime)t[k];
                  extended = true;
                  break;
                 }
              }
           }
         if(!extended)
            break;
        }
      return cur;
     }

   //--- First moment >= 'when' at which the symbol trades (0 if none within 8 days)
   static datetime   NextOpen(const string sym, const datetime when)
     {
      if(IsOpen(sym, when))
         return when;
      datetime day0 = SAEA_DayStart(when);
      for(int d = 0; d <= 8; d++)
        {
         datetime ds = day0 + (datetime)(d * SAEA_SECONDS_PER_DAY);
         long f[], t[];
         if(!DaySessions(sym, SAEA_DayOfWeek(ds), f, t))
            continue;
         datetime best = 0;
         for(int k = 0; k < ArraySize(f); k++)
           {
            datetime start = ds + (datetime)f[k];
            datetime end = ds + (datetime)t[k];
            if(end <= when)
               continue;
            datetime c = (start > when) ? start : when;
            if(best == 0 || c < best)
               best = c;
           }
         if(best > 0)
            return best;
        }
      return 0;
     }

   //--- Rollover instant that books the swap for calendar day 'dayStart'
   static datetime   RolloverOf(const datetime dayStart, const int offsetMinutes)
     {
      return dayStart + (datetime)(SAEA_SECONDS_PER_DAY + offsetMinutes * 60);
     }

   //--- First rollover instant strictly after 'when'
   static datetime   NextRollover(const datetime when, const int offsetMinutes)
     {
      datetime d = SAEA_DayStart(when) - (datetime)SAEA_SECONDS_PER_DAY;
      for(int i = 0; i < 4; i++)
        {
         datetime r = RolloverOf(d + (datetime)(i * SAEA_SECONDS_PER_DAY), offsetMinutes);
         if(r > when)
            return r;
        }
      return RolloverOf(SAEA_DayStart(when), offsetMinutes);
     }

   //--- The n-th (1-based) rollover instant after 'when'
   static datetime   NthRolloverAfter(const datetime when, const int n, const int offsetMinutes)
     {
      datetime first = NextRollover(when, offsetMinutes);
      int k = (n < 1) ? 1 : n;
      return first + (datetime)((k - 1) * SAEA_SECONDS_PER_DAY);
     }

   //--- Number of rollover instants in (from, to]
   static int        CountRollovers(const datetime from, const datetime to, const int offsetMinutes)
     {
      if(to <= from)
         return 0;
      int count = 0;
      datetime d = SAEA_DayStart(from) - (datetime)SAEA_SECONDS_PER_DAY;
      datetime last = SAEA_DayStart(to) + (datetime)SAEA_SECONDS_PER_DAY;
      for(; d <= last; d += (datetime)SAEA_SECONDS_PER_DAY)
        {
         datetime r = RolloverOf(d, offsetMinutes);
         if(r > from && r <= to)
            count++;
        }
      return count;
     }

   //--- Sum of day ratios for every rollover in (from, to]; the ratio used is the one of
   //--- the calendar day being rolled FROM (SYMBOL_SWAP_FRIDAY = rollover Friday -> Saturday).
   static double     RolloverMultiplier(const SAEASwapSpec &spec, const datetime from, const datetime to,
                                        const int offsetMinutes, int &count)
     {
      count = 0;
      if(to <= from)
         return 0.0;
      double sum = 0.0;
      datetime d = SAEA_DayStart(from) - (datetime)SAEA_SECONDS_PER_DAY;
      datetime last = SAEA_DayStart(to) + (datetime)SAEA_SECONDS_PER_DAY;
      for(; d <= last; d += (datetime)SAEA_SECONDS_PER_DAY)
        {
         datetime r = RolloverOf(d, offsetMinutes);
         if(r > from && r <= to)
           {
            sum += spec.dayRatio[SAEA_DayOfWeek(d)];
            count++;
           }
        }
      return sum;
     }

   //--- Scheduled exit: first tradable moment after the n-th rollover, plus a delay
   static datetime   EstimateExit(const string sym, const datetime openTime, const int holdRollovers,
                                  const int offsetMinutes, const int delayMinutes)
     {
      datetime lastRoll = NthRolloverAfter(openTime, holdRollovers, offsetMinutes);
      datetime open = NextOpen(sym, lastRoll + 1);
      if(open <= 0)
         return 0;
      return open + (datetime)(delayMinutes * 60);
     }
  };

#endif
//+------------------------------------------------------------------+
