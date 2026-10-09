//+------------------------------------------------------------------+
//|                                                   Dashboard.mqh  |
//|   On-chart text panel (OBJ_LABEL lines on a rectangle label).     |
//+------------------------------------------------------------------+
#ifndef SAEA_DASHBOARD_MQH
#define SAEA_DASHBOARD_MQH

#include "Defines.mqh"

#define SAEA_DASH_MAX_LINES 48

class CDashboard
  {
private:
   string            m_lines[];
   color             m_colors[];
   int               m_drawn;

   string            LineName(const int i) const { return SAEA_OBJ_PREFIX + "L" + IntegerToString(i); }
   string            BgName() const { return SAEA_OBJ_PREFIX + "BG"; }

   void              EnsureLabel(const int i)
     {
      string name = LineName(i);
      if(ObjectFind(0, name) >= 0)
         return;
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, g_cfg.dashboardX + 8);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, g_cfg.dashboardY + 6 + i * (g_cfg.dashboardFontSize + 7));
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, g_cfg.dashboardFontSize);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
     }

public:
                     CDashboard() : m_drawn(0) {}

   static bool       Enabled()
     {
      if(!g_cfg.showDashboard)
         return false;
      //--- no chart objects in non-visual tester runs (speed)
      if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))
         return false;
      return true;
     }

   void              Begin()
     {
      ArrayResize(m_lines, 0);
      ArrayResize(m_colors, 0);
     }

   void              Add(const string text, const color clr = clrWhite)
     {
      int n = ArraySize(m_lines);
      if(n >= SAEA_DASH_MAX_LINES)
         return;
      ArrayResize(m_lines, n + 1);
      ArrayResize(m_colors, n + 1);
      m_lines[n] = text;
      m_colors[n] = clr;
     }

   void              Render()
     {
      if(!Enabled())
         return;
      int n = ArraySize(m_lines);
      int maxLen = 10;
      for(int i = 0; i < n; i++)
         maxLen = MathMax(maxLen, StringLen(m_lines[i]));
      string bg = BgName();
      if(ObjectFind(0, bg) < 0)
        {
         ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
         ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'16,20,28');
         ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
         ObjectSetInteger(0, bg, OBJPROP_COLOR, C'60,70,90');
         ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
         ObjectSetInteger(0, bg, OBJPROP_BACK, false);
        }
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, g_cfg.dashboardX);
      ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, g_cfg.dashboardY);
      //--- Consolas glyph width is roughly 0.75 x point size in pixels at 96 DPI
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, (int)(maxLen * g_cfg.dashboardFontSize * 0.78) + 20);
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, n * (g_cfg.dashboardFontSize + 7) + 12);
      for(int i = 0; i < n; i++)
        {
         EnsureLabel(i);
         ObjectSetString(0, LineName(i), OBJPROP_TEXT, m_lines[i] == "" ? " " : m_lines[i]);
         ObjectSetInteger(0, LineName(i), OBJPROP_COLOR, m_colors[i]);
        }
      for(int i = n; i < m_drawn; i++)
         ObjectDelete(0, LineName(i));
      m_drawn = n;
      ChartRedraw(0);
     }

   void              Remove()
     {
      ObjectsDeleteAll(0, SAEA_OBJ_PREFIX);
      m_drawn = 0;
      ChartRedraw(0);
     }
  };

#endif
//+------------------------------------------------------------------+
