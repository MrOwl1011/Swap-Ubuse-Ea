//+------------------------------------------------------------------+
//|                                                 TradeLogger.mqh  |
//|   Journal + CSV logging of decisions, entries and deals, and      |
//|   per-position statistics built from the account deal history.    |
//|   CSV files go to MQL5\Files (tester: the agent's Files folder).  |
//+------------------------------------------------------------------+
#ifndef SAEA_TRADE_LOGGER_MQH
#define SAEA_TRADE_LOGGER_MQH

#include "Defines.mqh"

struct SAEAStats
  {
   int               trades;
   int               wins;
   int               losses;
   int               maxConsecLosses;
   double            grossProfit;     // sum of winning positions (net of swap/commission/fee)
   double            grossLoss;       // sum of losing positions (positive number)
   double            netProfit;
   double            priceProfit;     // DEAL_PROFIT only
   double            swapTotal;
   double            swapIncome;
   double            swapPaid;
   double            commission;
   double            fees;
   double            estSpreadCost;   // estimates logged at entry during this run
   int               entriesThisRun;

   void              Reset()
     {
      trades = 0;
      wins = 0;
      losses = 0;
      maxConsecLosses = 0;
      grossProfit = 0.0;
      grossLoss = 0.0;
      netProfit = 0.0;
      priceProfit = 0.0;
      swapTotal = 0.0;
      swapIncome = 0.0;
      swapPaid = 0.0;
      commission = 0.0;
      fees = 0.0;
      estSpreadCost = 0.0;
      entriesThisRun = 0;
     }

   double            ProfitFactor() const
     {
      if(grossLoss <= 0.0)
         return (grossProfit > 0.0) ? 99.0 : 0.0;
      return grossProfit / grossLoss;
     }

   double            WinRate() const
     {
      return (trades > 0) ? 100.0 * wins / trades : 0.0;
     }
  };

class CTradeLogger
  {
private:
   string            m_decFile;
   string            m_entryFile;
   string            m_dealFile;
   string            m_keySym[];
   string            m_keyVal[];
   double            m_estSpread;
   int               m_entries;

   void              Append(const string file, const string header, const string line)
     {
      if(!g_cfg.writeCsv)
         return;
      int h = FileOpen(file, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
      if(h == INVALID_HANDLE)
        {
         SAEA_Debug("cannot open " + file + " (" + IntegerToString(GetLastError()) + ")");
         return;
        }
      FileSeek(h, 0, SEEK_END);
      if(FileTell(h) == 0)
         FileWriteString(h, header + "\r\n");
      FileWriteString(h, line + "\r\n");
      FileClose(h);
     }

   static string     Csv(const string s)
     {
      string r = s;
      StringReplace(r, ",", ";");
      return r;
     }

   static string     StripDigits(const string s)
     {
      string r = "";
      int n = StringLen(s);
      for(int i = 0; i < n; i++)
        {
         ushort c = StringGetCharacter(s, i);
         if((c >= '0' && c <= '9') || c == '.' || c == '-')
            continue;
         r += ShortToString(c);
        }
      return r;
     }

   static string     T(const datetime t)
     {
      return TimeToString(t, TIME_DATE | TIME_SECONDS);
     }

public:
                     CTradeLogger() : m_estSpread(0.0), m_entries(0) {}

   void              Init()
     {
      string base = "SwapAbuseEA_" + IntegerToString(g_cfg.magic);
      m_decFile = base + "_decisions.csv";
      m_entryFile = base + "_entries.csv";
      m_dealFile = base + "_deals.csv";
     }

   //--- Logs an evaluation only when its outcome changes (avoids one line per scan)
   void              Decision(const SAEAAnalysis &a, const datetime now)
     {
      string key = SAEA_KindName(a.kind) + "|" + SAEA_WindowName(a.window) + "|" + (a.qualifies ? "Q" : "-") +
                   (a.entryReady ? "E" : "-") + "|" + StripDigits(a.reason);
      int idx = -1;
      for(int i = 0; i < ArraySize(m_keySym); i++)
         if(m_keySym[i] == a.symbol)
           {
            idx = i;
            break;
           }
      if(idx < 0)
        {
         idx = ArraySize(m_keySym);
         ArrayResize(m_keySym, idx + 1);
         ArrayResize(m_keyVal, idx + 1);
         m_keySym[idx] = a.symbol;
         m_keyVal[idx] = "";
        }
      if(m_keyVal[idx] == key)
         return;
      m_keyVal[idx] = key;
      SAEA_Debug(a.symbol + " " + SAEA_KindName(a.kind) + "/" + SAEA_WindowName(a.window) + ": " + a.reason);
      string line = T(now) + "," + a.symbol + "," + SAEA_KindName(a.kind) + "," + SAEA_WindowName(a.window) + "," +
                    IntegerToString(a.minutesToTarget) + "," + SAEA_SwapModeName(a.swap.mode) + "," +
                    DoubleToString(a.swap.swapLong, 4) + "," + DoubleToString(a.swap.swapShort, 4) + "," +
                    DoubleToString(a.swap.longPerLot, 4) + "," + DoubleToString(a.swap.shortPerLot, 4) + "," +
                    DoubleToString(a.rollMult, 1) + "," + SAEA_DirName(a.favDir) + "," +
                    DoubleToString(a.favPerLot, 2) + "," + DoubleToString(a.costPerLot, 2) + "," +
                    DoubleToString(a.netPerLot, 2) + "," + DoubleToString(a.lots, 2) + "," +
                    DoubleToString(a.netAdvantage, 2) + "," + DoubleToString(a.stressPts, 0) + "," +
                    DoubleToString(a.stressLoss, 2) + "," + IntegerToString(a.spreadPts) + "," +
                    (a.qualifies ? "1" : "0") + "," + (a.entryReady ? "1" : "0") + "," + Csv(a.reason);
      Append(m_decFile,
             "time,symbol,kind,window,min_to_target,swap_mode,swap_long_raw,swap_short_raw,long_per_lot_roll,short_per_lot_roll," +
             "roll_mult,dir,swap_per_lot_hold,cost_per_lot,net_per_lot,lots,net_advantage,stress_pts,stress_loss,spread_pts," +
             "qualifies,entry_ready,reason",
             line);
     }

   void              Entry(const SAEAAnalysis &a, const datetime now, const bool ok, const string result)
     {
      SAEA_Log((ok ? "OPENED " : "ENTRY FAILED ") + a.symbol + " " + SAEA_DirName(a.favDir) + " " +
               DoubleToString(a.lots, 2) + " lots | hold x" + DoubleToString(a.rollMult, 1) +
               " | exp swap " + SAEA_Money(a.expectedSwap) + " cost " + SAEA_Money(a.expectedCost) +
               " net " + SAEA_Money(a.netAdvantage) + " | stress loss " + SAEA_Money(a.stressLoss) +
               " | " + result);
      if(ok)
        {
         m_entries++;
         m_estSpread += a.spreadCostPerLot * a.lots;
        }
      string line = T(now) + "," + a.symbol + "," + SAEA_KindName(a.kind) + "," + SAEA_DirName(a.favDir) + "," +
                    DoubleToString(a.lots, 2) + "," + DoubleToString(a.rollMult, 1) + "," + T(a.exitTime) + "," +
                    DoubleToString(a.expectedSwap, 2) + "," + DoubleToString(a.spreadCostPerLot * a.lots, 2) + "," +
                    DoubleToString(a.commissionPerLot * a.lots, 2) + "," + DoubleToString(a.expectedCost, 2) + "," +
                    DoubleToString(a.netAdvantage, 2) + "," + DoubleToString(a.stressLoss, 2) + "," +
                    IntegerToString(a.spreadPts) + "," + (ok ? "OK" : "FAIL") + "," + Csv(result);
      Append(m_entryFile,
             "time,symbol,kind,dir,lots,roll_mult,planned_exit,exp_swap,est_spread_cost,est_commission,est_total_cost," +
             "exp_net,stress_loss,spread_pts,status,result",
             line);
     }

   void              Action(const string sym, const string action, const string detail)
     {
      SAEA_Log(action + " " + sym + " | " + detail);
      Append(m_entryFile,
             "time,symbol,kind,dir,lots,roll_mult,planned_exit,exp_swap,est_spread_cost,est_commission,est_total_cost," +
             "exp_net,stress_loss,spread_pts,status,result",
             T(SAEA_ServerNow()) + "," + sym + ",MANAGE," + action + ",,,,,,,,,,," + action + "," + Csv(detail));
     }

   //--- Called from OnTradeTransaction: records every deal of this EA
   void              OnTransaction(const MqlTradeTransaction &trans)
     {
      if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
         return;
      if(!HistoryDealSelect(trans.deal))
         return;
      if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != g_cfg.magic)
         return;
      long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
      long type = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
      string sym = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
      double vol = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
      double price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
      double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
      double swap = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
      double com = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      double fee = HistoryDealGetDouble(trans.deal, DEAL_FEE);
      long pos = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
      datetime t = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
      string entryName = (entry == DEAL_ENTRY_IN) ? "IN" : (entry == DEAL_ENTRY_OUT) ? "OUT" :
                         (entry == DEAL_ENTRY_INOUT) ? "INOUT" : (entry == DEAL_ENTRY_OUT_BY) ? "OUT_BY" : "OTHER";
      string typeName = (type == DEAL_TYPE_BUY) ? "BUY" : (type == DEAL_TYPE_SELL) ? "SELL" : IntegerToString(type);
      SAEA_Log("DEAL " + entryName + " " + sym + " " + typeName + " " + DoubleToString(vol, 2) + " @ " +
               DoubleToString(price, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)) + " | profit " + SAEA_Money(profit) +
               " swap " + SAEA_Money(swap) + " commission " + SAEA_Money(com) + " fee " + SAEA_Money(fee) +
               " | position " + IntegerToString(pos));
      Append(m_dealFile, "time,symbol,position_id,deal,entry,type,volume,price,profit,swap,commission,fee,net",
             T(t) + "," + sym + "," + IntegerToString(pos) + "," + IntegerToString((long)trans.deal) + "," + entryName +
             "," + typeName + "," + DoubleToString(vol, 2) + "," + DoubleToString(price, 8) + "," +
             DoubleToString(profit, 2) + "," + DoubleToString(swap, 2) + "," + DoubleToString(com, 2) + "," +
             DoubleToString(fee, 2) + "," + DoubleToString(profit + swap + com + fee, 2));
     }

   //--- Closed-position statistics for this magic from the full deal history
   void              ComputeStats(SAEAStats &s) const
     {
      s.Reset();
      s.estSpreadCost = m_estSpread;
      s.entriesThisRun = m_entries;
      if(!HistorySelect(0, TimeCurrent() + SAEA_SECONDS_PER_DAY))
         return;
      long ids[];
      double net[];
      bool closed[];
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0 || HistoryDealGetInteger(deal, DEAL_MAGIC) != g_cfg.magic)
            continue;
         long type = HistoryDealGetInteger(deal, DEAL_TYPE);
         if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
            continue;
         long pos = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
         double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
         double swap = HistoryDealGetDouble(deal, DEAL_SWAP);
         double com = HistoryDealGetDouble(deal, DEAL_COMMISSION);
         double fee = HistoryDealGetDouble(deal, DEAL_FEE);
         s.priceProfit += profit;
         s.swapTotal += swap;
         if(swap > 0.0)
            s.swapIncome += swap;
         else
            s.swapPaid += -swap;
         s.commission += com;
         s.fees += fee;
         int k = -1;
         for(int j = ArraySize(ids) - 1; j >= 0; j--)
            if(ids[j] == pos)
              {
               k = j;
               break;
              }
         if(k < 0)
           {
            k = ArraySize(ids);
            ArrayResize(ids, k + 1);
            ArrayResize(net, k + 1);
            ArrayResize(closed, k + 1);
            ids[k] = pos;
            net[k] = 0.0;
            closed[k] = false;
           }
         net[k] += profit + swap + com + fee;
         long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
            closed[k] = true;
        }
      int consec = 0;
      for(int k = 0; k < ArraySize(ids); k++)
        {
         if(!closed[k] || PositionSelectByTicket((ulong)ids[k]))
            continue; // still (partly) open
         s.trades++;
         s.netProfit += net[k];
         if(net[k] >= 0.0)
           {
            s.wins++;
            s.grossProfit += net[k];
            consec = 0;
           }
         else
           {
            s.losses++;
            s.grossLoss += -net[k];
            consec++;
            if(consec > s.maxConsecLosses)
               s.maxConsecLosses = consec;
           }
        }
     }

   void              WriteSummary(const SAEAStats &s, const double ddMoney, const double ddPercent)
     {
      string line = T(TimeCurrent()) + "," + IntegerToString(s.trades) + "," + DoubleToString(s.netProfit, 2) + "," +
                    DoubleToString(s.ProfitFactor(), 2) + "," + DoubleToString(s.WinRate(), 1) + "," +
                    IntegerToString(s.maxConsecLosses) + "," + DoubleToString(ddMoney, 2) + "," +
                    DoubleToString(ddPercent, 2) + "," + DoubleToString(s.priceProfit, 2) + "," +
                    DoubleToString(s.swapTotal, 2) + "," + DoubleToString(s.swapIncome, 2) + "," +
                    DoubleToString(s.swapPaid, 2) + "," + DoubleToString(s.commission, 2) + "," +
                    DoubleToString(s.fees, 2) + "," + DoubleToString(s.estSpreadCost, 2);
      Append("SwapAbuseEA_" + IntegerToString(g_cfg.magic) + "_summary.csv",
             "time,trades,net_profit,profit_factor,win_rate_pct,max_consec_losses,max_dd_money,max_dd_pct," +
             "price_pnl,swap_net,swap_income,swap_paid,commission,fees,est_spread_cost",
             line);
      SAEA_Log("SUMMARY trades " + IntegerToString(s.trades) + " | net " + SAEA_Money(s.netProfit) +
               " | PF " + DoubleToString(s.ProfitFactor(), 2) + " | win " + DoubleToString(s.WinRate(), 1) +
               "% | max consec losses " + IntegerToString(s.maxConsecLosses) + " | DD " + SAEA_Money(ddMoney) +
               " (" + DoubleToString(ddPercent, 2) + "%) | price P/L " + SAEA_Money(s.priceProfit) +
               " | swap net " + SAEA_Money(s.swapTotal) + " (in " + SAEA_Money(s.swapIncome) + ", out " +
               SAEA_Money(s.swapPaid) + ") | commission " + SAEA_Money(s.commission) + " | fees " +
               SAEA_Money(s.fees) + " | est. spread cost " + SAEA_Money(s.estSpreadCost));
     }
  };

#endif
//+------------------------------------------------------------------+
