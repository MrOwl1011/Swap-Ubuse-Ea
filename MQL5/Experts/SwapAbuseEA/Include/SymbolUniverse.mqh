//+------------------------------------------------------------------+
//|                                              SymbolUniverse.mqh  |
//|   Resolves the SymbolsToScan input into broker symbol names       |
//+------------------------------------------------------------------+
#ifndef SAEA_SYMBOL_UNIVERSE_MQH
#define SAEA_SYMBOL_UNIVERSE_MQH

#include "Defines.mqh"

//--- Spec syntax (comma or semicolon separated):
//---   CURRENT          the chart symbol
//---   MARKETWATCH      every symbol currently in Market Watch
//---   ALL              every symbol the broker offers (capped by MaxSymbolsToScan)
//---   XAUUSD           exact name, or the first broker symbol that starts with it (XAUUSD.r, XAUUSDm)
//---   XAUUSD:60        same, with a per-symbol maximum spread in points
class CSymbolUniverse
  {
private:
   string            m_names[];
   int               m_maxSpread[];   // -1 = use the global MaximumSpread

   int               Find(const string name) const
     {
      for(int i = 0; i < ArraySize(m_names); i++)
         if(m_names[i] == name)
            return i;
      return -1;
     }

   string            Resolve(const string requested) const
     {
      bool custom = false;
      if(SymbolExist(requested, custom))
         return requested;
      //--- broker suffix / prefix variants: prefer Market Watch, then the full list
      for(int pass = 0; pass < 2; pass++)
        {
         bool selectedOnly = (pass == 0);
         int total = SymbolsTotal(selectedOnly);
         for(int i = 0; i < total; i++)
           {
            string s = SymbolName(i, selectedOnly);
            if(StringFind(s, requested) == 0)
               return s;
           }
        }
      return "";
     }

   void              Add(const string name, const int maxSpread, const int cap)
     {
      if(name == "" || Find(name) >= 0)
         return;
      if(cap > 0 && ArraySize(m_names) >= cap)
         return;
      if(!SymbolSelect(name, true))
        {
         SAEA_Log("Cannot select symbol " + name + " in Market Watch, skipped");
         return;
        }
      int n = ArraySize(m_names);
      ArrayResize(m_names, n + 1);
      ArrayResize(m_maxSpread, n + 1);
      m_names[n] = name;
      m_maxSpread[n] = maxSpread;
     }

public:
   int               Build(const string spec, const int cap)
     {
      ArrayResize(m_names, 0);
      ArrayResize(m_maxSpread, 0);
      string s = spec;
      StringReplace(s, ";", ",");
      string parts[];
      int count = StringSplit(s, ',', parts);
      if(count <= 0)
        {
         ArrayResize(parts, 1);
         parts[0] = "CURRENT";
         count = 1;
        }
      for(int p = 0; p < count; p++)
        {
         string token = SAEA_Trim(parts[p]);
         if(token == "")
            continue;
         int maxSpread = -1;
         int colon = StringFind(token, ":");
         if(colon > 0)
           {
            maxSpread = (int)StringToInteger(StringSubstr(token, colon + 1));
            token = SAEA_Trim(StringSubstr(token, 0, colon));
           }
         string upper = token;
         StringToUpper(upper);
         if(upper == "CURRENT")
           {
            Add(_Symbol, maxSpread, cap);
           }
         else
            if(upper == "MARKETWATCH")
              {
               int total = SymbolsTotal(true);
               for(int i = 0; i < total; i++)
                  Add(SymbolName(i, true), maxSpread, cap);
              }
            else
               if(upper == "ALL")
                 {
                  int total = SymbolsTotal(false);
                  for(int i = 0; i < total; i++)
                     Add(SymbolName(i, false), maxSpread, cap);
                 }
               else
                 {
                  string resolved = Resolve(token);
                  if(resolved == "")
                     SAEA_Log("Symbol '" + token + "' not offered by this broker, skipped");
                  else
                    {
                     if(resolved != token)
                        SAEA_Log("Symbol '" + token + "' resolved to broker symbol '" + resolved + "'");
                     Add(resolved, maxSpread, cap);
                    }
                 }
        }
      return ArraySize(m_names);
     }

   int               Total() const { return ArraySize(m_names); }
   string            Name(const int i) const { return m_names[i]; }
   int               MaxSpreadOverride(const int i) const { return m_maxSpread[i]; }
   int               IndexOf(const string name) const { return Find(name); }
  };

#endif
//+------------------------------------------------------------------+
