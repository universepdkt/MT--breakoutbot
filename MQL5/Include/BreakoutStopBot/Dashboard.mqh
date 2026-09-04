#ifndef __BREAKOUTSTOPBOT_DASHBOARD_MQH__
#define __BREAKOUTSTOPBOT_DASHBOARD_MQH__

#include "TradeUtils.mqh"

#define DASHBOARD_PREFIX "BOS_DASH_"
#define DASHBOARD_LINES  9

struct PeriodStats
  {
   double pnl;
   int    trades;
   int    wins;
  };

PeriodStats CalcPeriodStats(const string symbol,ulong magic,datetime from,datetime to)
  {
   PeriodStats s;
   s.pnl=0.0; s.trades=0; s.wins=0;

   if(!HistorySelect(from,to))
      return s;

   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket=HistoryDealGetTicket(i);
      if(ticket==0) continue;
      if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=symbol) continue;
      if((ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC)!=magic) continue;

      double profit=HistoryDealGetDouble(ticket,DEAL_PROFIT);
      double swap=HistoryDealGetDouble(ticket,DEAL_SWAP);
      double commission=HistoryDealGetDouble(ticket,DEAL_COMMISSION);
      s.pnl+=profit+swap+commission;

      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
        {
         s.trades++;
         if(profit>0.0) s.wins++;
        }
     }
   return s;
  }

double CalcOpenFloatingPnl(const string symbol,ulong magic)
  {
   double total=0.0;
   ulong tickets[];
   int n=GetPositionTickets(symbol,magic,tickets);
   for(int i=0;i<n;i++)
     {
      if(!PositionSelectByTicket(tickets[i])) continue;
      total+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
     }
   return total;
  }

color PnlColor(double value)
  {
   if(value>0.0) return clrLimeGreen;
   if(value<0.0) return clrTomato;
   return clrSilver;
  }

void CreateDashboardBackground()
  {
   string name=DASHBOARD_PREFIX+"BG";
   if(ObjectFind(0,name)<0)
     {
      ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,5);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,15);
      ObjectSetInteger(0,name,OBJPROP_XSIZE,250);
      ObjectSetInteger(0,name,OBJPROP_YSIZE,20+DASHBOARD_LINES*16+10);
      ObjectSetInteger(0,name,OBJPROP_BGCOLOR,C'20,20,20');
      ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clrSilver);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
     }
  }

void SetDashboardLine(int line,string text,color clr)
  {
   string name=DASHBOARD_PREFIX+IntegerToString(line);
   if(ObjectFind(0,name)<0)
     {
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,12);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,20+line*16);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
      ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
     }
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
  }

void UpdateDashboard(const string symbol,ulong magic,ENUM_TIMEFRAMES timeframe)
  {
   datetime now=TimeCurrent();

   PeriodStats dayStats  =CalcPeriodStats(symbol,magic,StartOfDay(now),  now);
   PeriodStats weekStats =CalcPeriodStats(symbol,magic,StartOfWeek(now), now);
   PeriodStats monthStats=CalcPeriodStats(symbol,magic,StartOfMonth(now),now);
   double floatingPnl=CalcOpenFloatingPnl(symbol,magic);
   int openPositions=CountPositionsByMagic(symbol,magic);

   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double equity =AccountInfoDouble(ACCOUNT_EQUITY);
   string currency=AccountInfoString(ACCOUNT_CURRENCY);
   double spreadPips=CurrentSpreadPips(symbol);

   double weekWinRate =weekStats.trades >0 ? (100.0*weekStats.wins /weekStats.trades) : 0.0;
   double monthWinRate=monthStats.trades>0 ? (100.0*monthStats.wins/monthStats.trades) : 0.0;

   CreateDashboardBackground();

   int line=0;
   SetDashboardLine(line++,StringFormat("BreakoutStopBot [%s]  %s",TimeframeLabel(timeframe),symbol),clrWhite);
   SetDashboardLine(line++,StringFormat("Balance %.2f  Equity %.2f %s",balance,equity,currency),clrSilver);
   SetDashboardLine(line++,StringFormat("Spread %.1f pips   Open Pos %d",spreadPips,openPositions),clrSilver);
   SetDashboardLine(line++,"------------------------------",clrGray);
   SetDashboardLine(line++,StringFormat("Today  P/L %+.2f  (%d trades)", dayStats.pnl,  dayStats.trades),  PnlColor(dayStats.pnl));
   SetDashboardLine(line++,StringFormat("Week   P/L %+.2f  (%d trades)", weekStats.pnl, weekStats.trades), PnlColor(weekStats.pnl));
   SetDashboardLine(line++,StringFormat("Month  P/L %+.2f  (%d trades)", monthStats.pnl,monthStats.trades),PnlColor(monthStats.pnl));
   SetDashboardLine(line++,StringFormat("Floating P/L %+.2f",floatingPnl),PnlColor(floatingPnl));
   SetDashboardLine(line++,StringFormat("Win rate  Week %.1f%%  Month %.1f%%",weekWinRate,monthWinRate),clrSilver);

   ChartRedraw(0);
  }

void RemoveDashboard()
  {
   ObjectsDeleteAll(0,DASHBOARD_PREFIX);
  }

#endif
