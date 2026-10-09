//+------------------------------------------------------------------+
//|                                               TradeExecutor.mqh  |
//|   Order placement with permission, volume, stop-level and result  |
//|   validation. Handles hedging and netting accounts.               |
//+------------------------------------------------------------------+
#ifndef SAEA_TRADE_EXECUTOR_MQH
#define SAEA_TRADE_EXECUTOR_MQH

#include <Trade\Trade.mqh>
#include "Defines.mqh"
#include "RiskManager.mqh"

class CTradeExecutor
  {
private:
   CTrade            m_trade;
   CRiskManager     *m_risk;

   bool              ResultOk()
     {
      uint rc = m_trade.ResultRetcode();
      return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED);
     }

   string            ResultText()
     {
      return "retcode " + IntegerToString(m_trade.ResultRetcode()) + " (" + m_trade.ResultRetcodeDescription() +
             "), deal " + IntegerToString((long)m_trade.ResultDeal()) +
             ", vol " + DoubleToString(m_trade.ResultVolume(), 2) +
             ", price " + DoubleToString(m_trade.ResultPrice(), 8);
     }

   //--- Stop distance in points respecting SYMBOL_TRADE_STOPS_LEVEL (+ current spread)
   int               StopDistance(const string sym, const int wanted) const
     {
      int stops = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
      int spread = (int)SymbolInfoInteger(sym, SYMBOL_SPREAD);
      int minDist = stops + spread + 1;
      return (wanted < minDist && stops > 0) ? minDist : wanted;
     }

   double            NormalizePrice(const string sym, const double price) const
     {
      double tick = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(tick > 0.0)
         return NormalizeDouble(MathRound(price / tick) * tick, digits);
      return NormalizeDouble(price, digits);
     }

public:
                     CTradeExecutor() : m_risk(NULL) {}

   void              Init(CRiskManager *risk)
     {
      m_risk = risk;
      m_trade.SetExpertMagicNumber((ulong)g_cfg.magic);
      m_trade.SetDeviationInPoints((ulong)g_cfg.slippage);
      m_trade.SetMarginMode();
      m_trade.SetAsyncMode(false);
      m_trade.LogLevel(LOG_LEVEL_ERRORS);
     }

   //--- Terminal, program and account permissions for automated trading
   bool              TradingPermitted(string &why) const
     {
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
        { why = "AutoTrading disabled in terminal"; return false; }
      if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
        { why = "Algo trading not allowed for this EA (Common tab)"; return false; }
      if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
        { why = "trading not allowed on this account (investor login?)"; return false; }
      if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
        { why = "broker disallows Expert Advisors on this account"; return false; }
      why = "";
      return true;
     }

   //--- Market entry in a.favDir with a.lots. Returns false and a description on any failure.
   bool              Open(const SAEAAnalysis &a, string &result)
     {
      string sym = a.symbol;
      double lots = m_risk.NormalizeVolume(sym, a.lots);
      if(lots <= 0.0)
        { result = "invalid volume " + DoubleToString(a.lots, 4); return false; }
      MqlTick tick;
      if(!SymbolInfoTick(sym, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
        { result = "no live quote"; return false; }
      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      double price = (a.favDir > 0) ? tick.ask : tick.bid;
      string err = "";
      if(!m_risk.MarginOk(sym, a.favDir, lots, price, err))
        { result = err; return false; }

      double sl = 0.0, tp = 0.0;
      if(g_cfg.useStopLoss && g_cfg.stopLossPoints > 0)
        {
         int d = StopDistance(sym, g_cfg.stopLossPoints);
         sl = NormalizePrice(sym, (a.favDir > 0) ? price - d * point : price + d * point);
        }
      if(g_cfg.useTakeProfit && g_cfg.takeProfitPoints > 0)
        {
         int d = StopDistance(sym, g_cfg.takeProfitPoints);
         tp = NormalizePrice(sym, (a.favDir > 0) ? price + d * point : price - d * point);
        }

      m_trade.SetTypeFillingBySymbol(sym);
      string comment = "SAEA " + SAEA_KindName(a.kind) + " x" + DoubleToString(a.rollMult, 0);
      bool sent = (a.favDir > 0) ? m_trade.Buy(lots, sym, price, sl, tp, comment)
                  : m_trade.Sell(lots, sym, price, sl, tp, comment);
      result = ResultText();
      if(!sent || !ResultOk())
        {
         result = "FAILED " + result;
         return false;
        }
      return true;
     }

   bool              Close(const SAEAPosition &p, string &result)
     {
      m_trade.SetTypeFillingBySymbol(p.symbol);
      bool sent = m_trade.PositionClose(p.ticket, (ulong)g_cfg.slippage);
      result = ResultText();
      if(!sent || !ResultOk())
        {
         result = "FAILED " + result;
         return false;
        }
      return true;
     }

   //--- Reduce a position by 'volume' lots (partial close on hedging, opposite deal on netting)
   bool              Reduce(const SAEAPosition &p, const double volume, string &result)
     {
      double v = m_risk.NormalizeVolume(p.symbol, volume);
      if(v <= 0.0)
        { result = "reduce volume below minimum"; return false; }
      if(v >= p.volume - 1e-9)
         return Close(p, result);
      m_trade.SetTypeFillingBySymbol(p.symbol);
      bool sent;
      if(SAEA_IsHedging())
         sent = m_trade.PositionClosePartial(p.ticket, v, (ulong)g_cfg.slippage);
      else
         sent = (p.dir > 0) ? m_trade.Sell(v, p.symbol, 0.0, 0.0, 0.0, "SAEA reduce")
                : m_trade.Buy(v, p.symbol, 0.0, 0.0, 0.0, "SAEA reduce");
      result = ResultText();
      if(!sent || !ResultOk())
        {
         result = "FAILED " + result;
         return false;
        }
      return true;
     }
  };

#endif
//+------------------------------------------------------------------+
