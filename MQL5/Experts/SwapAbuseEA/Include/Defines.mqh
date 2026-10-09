//+------------------------------------------------------------------+
//|                                                     Defines.mqh  |
//|            Swap Abuse EA - shared types, configuration, helpers  |
//+------------------------------------------------------------------+
#ifndef SAEA_DEFINES_MQH
#define SAEA_DEFINES_MQH

#define SAEA_NAME            "Swap Abuse EA"
#define SAEA_VERSION         "1.00"
#define SAEA_OBJ_PREFIX      "SAEA_"
#define SAEA_SECONDS_PER_DAY 86400
#define SAEA_WEEKEND_MIN_GAP_HOURS 20   // closed period that counts as a "weekend"

//--- How a position opened by the EA is exited
enum ENUM_SAEA_EXIT_MODE
  {
   SAEA_EXIT_AFTER_ROLLOVERS = 0, // Close after the planned rollovers are booked
   SAEA_EXIT_MANUAL          = 1  // No scheduled exit (SL/TP and risk rules only)
  };

//--- Custom optimisation criterion returned by OnTester()
enum ENUM_SAEA_OPT_CRITERION
  {
   SAEA_OPT_NET_PROFIT    = 0, // Net profit (incl. swap and commission)
   SAEA_OPT_PROFIT_FACTOR = 1, // Profit factor
   SAEA_OPT_RECOVERY      = 2, // Net profit / max equity drawdown
   SAEA_OPT_NET_SWAP      = 3  // Net swap minus commission and fees
  };

//--- Which entry schedule produced the current window
enum ENUM_SAEA_WINDOW_KIND
  {
   SAEA_KIND_NONE    = 0, // Not an entry schedule the EA is configured for
   SAEA_KIND_FRIDAY  = 1, // Friday close, held over the weekend
   SAEA_KIND_MIDWEEK = 2  // Ordinary / triple-swap daily rollover
  };

//--- Where "now" sits relative to the entry window
enum ENUM_SAEA_WINDOW_STATE
  {
   SAEA_WIN_UNKNOWN = 0, // Schedule could not be verified
   SAEA_WIN_CLOSED  = 1, // Market closed now
   SAEA_WIN_IDLE    = 2, // Market open, window not started yet
   SAEA_WIN_ACTIVE  = 3, // Inside [target - preparation, target - cutoff]
   SAEA_WIN_CUTOFF  = 4  // Inside [target - cutoff, target]: no new entries
  };

//--- Runtime configuration (filled from the EA inputs in OnInit)
struct SAEAConfig
  {
   bool              enableTrading;
   bool              analysisOnly;
   bool              enableFriday;
   bool              enableScanner;
   bool              enableMidweek;
   bool              midweekTripleOnly;
   string            symbolsToScan;
   int               maxSymbols;
   double            fixedLot;
   bool              useRiskSizing;
   double            riskPercent;
   double            minNetAdvantage;
   bool              requireOppositeSigns;
   int               prepMinutes;
   int               cutoffMinutes;
   int               rolloverOffsetMinutes;
   int               holdRollovers;
   ENUM_SAEA_EXIT_MODE exitMode;
   int               exitDelayMinutes;
   int               exitMaxWaitMinutes;
   int               maxSpread;
   double            exitSpreadMultiplier;
   double            commissionPerLotRT;
   bool              autoDetectCommission;
   double            otherCostsPerLot;
   double            maxWeekendLoss;
   double            maxTotalLots;
   int               maxOpenPositions;
   double            maxMarginUsePercent;
   int               gapLookbackWeeks;
   double            gapPercentile;
   double            gapMultiplier;
   double            minStressPercent;
   int               maxQuoteAgeSeconds;
   int               minTicksLast5Min;
   bool              useTrendFilter;
   ENUM_TIMEFRAMES   trendTimeframe;
   int               trendFastPeriod;
   int               trendSlowPeriod;
   bool              useStopLoss;
   int               stopLossPoints;
   bool              useTakeProfit;
   int               takeProfitPoints;
   bool              closeOnSwapFlip;
   bool              reduceToLimits;
   long              magic;
   int               slippage;
   int               timerSeconds;
   int               scanIntervalSeconds;
   bool              showDashboard;
   int               dashboardRows;
   int               dashboardX;
   int               dashboardY;
   int               dashboardFontSize;
   bool              writeCsv;
   bool              verboseLog;
   ENUM_SAEA_OPT_CRITERION optCriterion;
  };

SAEAConfig g_cfg;

//--- Swap specification of one symbol, normalised to deposit currency
struct SAEASwapSpec
  {
   bool              valid;
   string            error;
   ENUM_SYMBOL_SWAP_MODE mode;
   double            swapLong;          // raw broker value
   double            swapShort;         // raw broker value
   int               tripleDay;         // SYMBOL_SWAP_ROLLOVER3DAYS
   double            dayRatio[7];       // multiplier for the rollover FROM that weekday
   bool              brokerDayRatios;   // true = SYMBOL_SWAP_<DAY> from broker, false = derived
   bool              approximate;       // true for REOPEN modes (modelled as points)
   double            longPerLot;        // deposit ccy, one ordinary rollover, 1.0 lot
   double            shortPerLot;       // deposit ccy, one ordinary rollover, 1.0 lot
   string            basis;             // human readable explanation of the conversion

   void              Reset()
     {
      valid = false;
      error = "";
      mode = SYMBOL_SWAP_MODE_DISABLED;
      swapLong = 0.0;
      swapShort = 0.0;
      tripleDay = WEDNESDAY;
      for(int i = 0; i < 7; i++)
         dayRatio[i] = 0.0;
      brokerDayRatios = false;
      approximate = false;
      longPerLot = 0.0;
      shortPerLot = 0.0;
      basis = "";
     }
  };

//--- Historical adverse-move statistics used for gap / stress estimates
struct SAEAGapStats
  {
   bool              valid;
   datetime          computedAt;
   int               samples;
   double            weekendMedianPts;
   double            weekendStressPts;  // chosen percentile of weekend gaps
   double            dailyMedianPts;
   double            dailyStressPts;    // chosen percentile of daily ranges
   string            note;

   void              Reset()
     {
      valid = false;
      computedAt = 0;
      samples = 0;
      weekendMedianPts = 0.0;
      weekendStressPts = 0.0;
      dailyMedianPts = 0.0;
      dailyStressPts = 0.0;
      note = "";
     }
  };

//--- Full evaluation of one symbol at one scan
struct SAEAAnalysis
  {
   string            symbol;
   bool              verified;          // broker data fully verified
   bool              qualifies;         // economics pass all filters
   bool              entryReady;        // qualifies AND inside an entry window AND live filters pass
   string            reason;            // why accepted / rejected
   SAEASwapSpec      swap;
   double            bid;
   double            ask;
   double            point;
   double            pointValue;        // deposit ccy per point per 1.0 lot
   int               digits;
   int               spreadPts;
   int               maxSpreadPts;
   datetime          quoteTime;
   long              tradeMode;         // SYMBOL_TRADE_MODE
   //--- schedule
   ENUM_SAEA_WINDOW_KIND  kind;
   ENUM_SAEA_WINDOW_STATE window;
   datetime          sessionEnd;
   datetime          targetTime;        // last moment the position must be open (close or rollover)
   datetime          reopenTime;
   datetime          exitTime;          // estimated scheduled exit
   int               minutesToTarget;
   double            rollMult;          // sum of day ratios inside the projected hold
   int               rollCount;         // calendar rollovers inside the projected hold
   double            weekendMult;       // Fri+Sat+Sun ratios (dashboard reference)
   //--- economics, deposit currency
   double            holdLongPerLot;
   double            holdShortPerLot;
   int               favDir;            // +1 buy, -1 sell, 0 none
   double            favPerLot;
   double            oppPerLot;
   double            spreadCostPerLot;
   double            commissionPerLot;
   double            costPerLot;
   double            netPerLot;
   double            lots;
   double            expectedSwap;
   double            expectedCost;
   double            netAdvantage;
   //--- risk
   SAEAGapStats      gap;
   double            stressPts;
   double            stressLoss;
   double            breakevenPts;
   int               trendDir;
   string            sizingNote;

   void              Reset()
     {
      symbol = "";
      verified = false;
      qualifies = false;
      entryReady = false;
      reason = "";
      swap.Reset();
      bid = 0.0;
      ask = 0.0;
      point = 0.0;
      pointValue = 0.0;
      digits = 0;
      spreadPts = 0;
      maxSpreadPts = 0;
      quoteTime = 0;
      tradeMode = SYMBOL_TRADE_MODE_DISABLED;
      kind = SAEA_KIND_NONE;
      window = SAEA_WIN_UNKNOWN;
      sessionEnd = 0;
      targetTime = 0;
      reopenTime = 0;
      exitTime = 0;
      minutesToTarget = 0;
      rollMult = 0.0;
      rollCount = 0;
      weekendMult = 0.0;
      holdLongPerLot = 0.0;
      holdShortPerLot = 0.0;
      favDir = 0;
      favPerLot = 0.0;
      oppPerLot = 0.0;
      spreadCostPerLot = 0.0;
      commissionPerLot = 0.0;
      costPerLot = 0.0;
      netPerLot = 0.0;
      lots = 0.0;
      expectedSwap = 0.0;
      expectedCost = 0.0;
      netAdvantage = 0.0;
      gap.Reset();
      stressPts = 0.0;
      stressLoss = 0.0;
      breakevenPts = 0.0;
      trendDir = 0;
      sizingNote = "";
     }
  };

//--- One EA position
struct SAEAPosition
  {
   ulong             ticket;
   string            symbol;
   int               dir;
   double            volume;
   double            openPrice;
   datetime          openTime;
   double            swap;
   double            profit;
  };

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
void SAEA_Log(const string msg)
  {
   Print("[SAEA] ", msg);
  }

void SAEA_Debug(const string msg)
  {
   if(g_cfg.verboseLog)
      Print("[SAEA][dbg] ", msg);
  }

datetime SAEA_ServerNow()
  {
   datetime t = TimeTradeServer();
   if(t <= 0)
      t = TimeCurrent();
   return t;
  }

datetime SAEA_DayStart(const datetime t)
  {
   long s = (long)t;
   return (datetime)((s / SAEA_SECONDS_PER_DAY) * SAEA_SECONDS_PER_DAY);
  }

int SAEA_DayOfWeek(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.day_of_week;
  }

string SAEA_DayName(const int dow)
  {
   switch(dow)
     {
      case SUNDAY:
         return "SUN";
      case MONDAY:
         return "MON";
      case TUESDAY:
         return "TUE";
      case WEDNESDAY:
         return "WED";
      case THURSDAY:
         return "THU";
      case FRIDAY:
         return "FRI";
      case SATURDAY:
         return "SAT";
     }
   return "?";
  }

string SAEA_DirName(const int dir)
  {
   if(dir > 0)
      return "BUY";
   if(dir < 0)
      return "SELL";
   return "-";
  }

string SAEA_SwapModeName(const ENUM_SYMBOL_SWAP_MODE mode)
  {
   switch(mode)
     {
      case SYMBOL_SWAP_MODE_DISABLED:
         return "DISABLED";
      case SYMBOL_SWAP_MODE_POINTS:
         return "POINTS";
      case SYMBOL_SWAP_MODE_CURRENCY_SYMBOL:
         return "CCY_BASE";
      case SYMBOL_SWAP_MODE_CURRENCY_MARGIN:
         return "CCY_MARGIN";
      case SYMBOL_SWAP_MODE_CURRENCY_DEPOSIT:
         return "CCY_DEPOSIT";
      case SYMBOL_SWAP_MODE_CURRENCY_PROFIT:
         return "CCY_PROFIT";
      case SYMBOL_SWAP_MODE_INTEREST_CURRENT:
         return "INTEREST_CURRENT";
      case SYMBOL_SWAP_MODE_INTEREST_OPEN:
         return "INTEREST_OPEN";
      case SYMBOL_SWAP_MODE_REOPEN_CURRENT:
         return "REOPEN_CURRENT";
      case SYMBOL_SWAP_MODE_REOPEN_BID:
         return "REOPEN_BID";
     }
   return "UNKNOWN(" + IntegerToString((int)mode) + ")";
  }

string SAEA_WindowName(const ENUM_SAEA_WINDOW_STATE w)
  {
   switch(w)
     {
      case SAEA_WIN_UNKNOWN:
         return "UNVERIFIED";
      case SAEA_WIN_CLOSED:
         return "MARKET CLOSED";
      case SAEA_WIN_IDLE:
         return "WAITING";
      case SAEA_WIN_ACTIVE:
         return "ENTRY WINDOW";
      case SAEA_WIN_CUTOFF:
         return "CUTOFF";
     }
   return "?";
  }

string SAEA_KindName(const ENUM_SAEA_WINDOW_KIND k)
  {
   switch(k)
     {
      case SAEA_KIND_FRIDAY:
         return "FRIDAY";
      case SAEA_KIND_MIDWEEK:
         return "MIDWEEK";
      default:
         break;
     }
   return "NONE";
  }

string SAEA_Trim(string s)
  {
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
  }

string SAEA_TimeHM(const datetime t)
  {
   if(t <= 0)
      return "--:--";
   return TimeToString(t, TIME_MINUTES);
  }

string SAEA_Money(const double v)
  {
   return DoubleToString(v, 2);
  }

bool SAEA_IsHedging()
  {
   return ((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
  }

bool SAEA_IsTester()
  {
   return (MQLInfoInteger(MQL_TESTER) != 0);
  }

#endif
//+------------------------------------------------------------------+
