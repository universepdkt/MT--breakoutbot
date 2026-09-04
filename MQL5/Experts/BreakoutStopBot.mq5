#property copyright "BreakoutStopBot"
#property version   "1.00"
#property strict
#property description "1-minute breakout bot: places Buy Stop / Sell Stop at the prior candle's "
#property description "high/low every bar (OCO pair), manages TP/SL, breakeven, early drawdown exit."

#include <Trade/Trade.mqh>
#include <BreakoutStopBot/TradeUtils.mqh>
#include <BreakoutStopBot/RiskManager.mqh>

input group "=== Take Profit / Stop Loss ==="
input double InpTakeProfitPips         = 100.0;  // Take profit distance (pips)
input double InpStopLossPips           = 50.0;   // Stop loss distance (pips)

input group "=== Breakeven ==="
input double InpBreakevenTriggerPips   = 20.0;   // Floating profit (pips) needed before breakeven arms
input double InpBreakevenBufferPips    = 0.25;   // Extra pips locked in beyond spread at breakeven

input group "=== Entry ==="
input double InpEntryBufferPips        = 0.0;    // Offset beyond prior candle's high/low
input int    InpPendingExpiryMinutes   = 0;       // 0 = GTC (orders are replaced every bar regardless)

input group "=== Position Sizing ==="
input bool   InpUseRiskPercent         = false;  // Use risk-percent sizing instead of fixed lot
input double InpRiskPercent            = 1.0;    // Risk per trade, % of balance (if InpUseRiskPercent)
input double InpLotSize                = 0.01;   // Fixed lot size (if !InpUseRiskPercent)

input group "=== Risk Controls ==="
input int    InpMaxConcurrentPositions = 3;      // Max simultaneously open positions from this EA
input double InpMaxSpreadPips          = 3.0;    // Skip placing new stops if spread exceeds this

input group "=== Session Filter ==="
input bool   InpUseSessionFilter       = false;  // Restrict new stop placement to a time window
input int    InpTradingStartHour       = 0;      // Server-time hour, inclusive
input int    InpTradingEndHour         = 24;     // Server-time hour, exclusive

input group "=== Execution ==="
input int    InpSlippagePips           = 2;      // Max slippage for market operations (pips)
input ulong  InpMagicNumber            = 20260904;
input bool   InpCancelPendingOnRemove  = true;   // Cancel our pending stops when the EA is removed

CTrade    trade;
datetime  g_lastBarTime          = 0;
ulong     g_pendingBuyStopTicket = 0;
ulong     g_pendingSellStopTicket= 0;

int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double pip=PipSize(_Symbol);
   int deviationPoints=(point>0.0)?(int)MathRound(InpSlippagePips*(pip/point)):(int)InpSlippagePips;
   trade.SetDeviationInPoints(deviationPoints);

   ENUM_ACCOUNT_MARGIN_MODE marginMode=(ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("WARNING: account is not a hedging account. This EA assumes independent per-order "
            "positions and has not been validated on netting accounts.");

   if(_Period!=PERIOD_M1)
      Print("WARNING: chart timeframe is not M1. This EA reads M1 candle data internally, but "
            "run it on an M1 chart for accurate new-bar timing.");

   g_lastBarTime=iTime(_Symbol,PERIOD_M1,0);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(InpCancelPendingOnRemove && reason==REASON_REMOVE)
     {
      if(g_pendingBuyStopTicket!=0 && OrderSelect(g_pendingBuyStopTicket))
         trade.OrderDelete(g_pendingBuyStopTicket);
      if(g_pendingSellStopTicket!=0 && OrderSelect(g_pendingSellStopTicket))
         trade.OrderDelete(g_pendingSellStopTicket);
     }
  }

void OnTick()
  {
   EnforceOco();
   ManageBreakeven();

   if(IsNewBar(_Symbol,PERIOD_M1,g_lastBarTime))
      OnNewBar();
  }

void OnNewBar()
  {
   CloseDrawdownPositions();
   CancelStalePendingOrders();

   if(!SpreadOk())
     {
      Print("Spread ",DoubleToString(CurrentSpreadPips(),1)," pips exceeds max ",
            DoubleToString(InpMaxSpreadPips,1),", skipping new stop orders this bar.");
      return;
     }

   if(InpUseSessionFilter && !WithinSession())
      return;

   int openCount=CountPositionsByMagic(_Symbol,InpMagicNumber);
   if(openCount>=InpMaxConcurrentPositions)
     {
      Print("Max concurrent positions reached (",openCount,"/",InpMaxConcurrentPositions,
            "), skipping new stop orders.");
      return;
     }

   PlaceBreakoutStops();
  }

// Cancels the previous bar's OCO pair if it never filled, so stale breakout levels
// don't accumulate. Positions already open are left untouched.
void CancelStalePendingOrders()
  {
   if(g_pendingBuyStopTicket!=0)
     {
      if(OrderSelect(g_pendingBuyStopTicket))
         trade.OrderDelete(g_pendingBuyStopTicket);
      g_pendingBuyStopTicket=0;
     }
   if(g_pendingSellStopTicket!=0)
     {
      if(OrderSelect(g_pendingSellStopTicket))
         trade.OrderDelete(g_pendingSellStopTicket);
      g_pendingSellStopTicket=0;
     }
  }

// If one side of the current OCO pair filled or vanished and the other is still
// pending, cancel the sibling so only one direction can be active at a time.
void EnforceOco()
  {
   if(g_pendingBuyStopTicket==0 && g_pendingSellStopTicket==0)
      return;

   bool buyExists =g_pendingBuyStopTicket!=0  && OrderSelect(g_pendingBuyStopTicket);
   bool sellExists=g_pendingSellStopTicket!=0 && OrderSelect(g_pendingSellStopTicket);

   if(g_pendingBuyStopTicket!=0 && !buyExists)
      g_pendingBuyStopTicket=0;
   if(g_pendingSellStopTicket!=0 && !sellExists)
      g_pendingSellStopTicket=0;

   if(g_pendingBuyStopTicket==0 && g_pendingSellStopTicket!=0 && sellExists)
     {
      trade.OrderDelete(g_pendingSellStopTicket);
      g_pendingSellStopTicket=0;
     }
   else if(g_pendingSellStopTicket==0 && g_pendingBuyStopTicket!=0 && buyExists)
     {
      trade.OrderDelete(g_pendingBuyStopTicket);
      g_pendingBuyStopTicket=0;
     }
  }

void PlaceBreakoutStops()
  {
   double prevHigh=iHigh(_Symbol,PERIOD_M1,1);
   double prevLow =iLow(_Symbol,PERIOD_M1,1);
   if(prevHigh<=0.0 || prevLow<=0.0)
     {
      Print("Invalid previous candle data, skipping stop placement.");
      return;
     }

   double buyStopPrice =AdjustStopPrice(_Symbol,ORDER_TYPE_BUY_STOP, prevHigh+PipsToPrice(_Symbol,InpEntryBufferPips));
   double sellStopPrice=AdjustStopPrice(_Symbol,ORDER_TYPE_SELL_STOP,prevLow -PipsToPrice(_Symbol,InpEntryBufferPips));

   double lot=InpUseRiskPercent
              ? CalcLotByRisk(_Symbol,InpRiskPercent,InpStopLossPips)
              : NormalizeVolume(_Symbol,InpLotSize);

   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double buySl =NormalizeDouble(buyStopPrice -PipsToPrice(_Symbol,InpStopLossPips),  digits);
   double buyTp =NormalizeDouble(buyStopPrice +PipsToPrice(_Symbol,InpTakeProfitPips),digits);
   double sellSl=NormalizeDouble(sellStopPrice+PipsToPrice(_Symbol,InpStopLossPips),  digits);
   double sellTp=NormalizeDouble(sellStopPrice-PipsToPrice(_Symbol,InpTakeProfitPips),digits);

   ENUM_ORDER_TYPE_TIME typeTime=ORDER_TIME_GTC;
   datetime expiration=0;
   if(InpPendingExpiryMinutes>0)
     {
      typeTime=ORDER_TIME_SPECIFIED;
      expiration=TimeCurrent()+InpPendingExpiryMinutes*60;
     }

   string comment=StringFormat("BOS_%d",(int)g_lastBarTime);

   if(trade.OrderOpen(_Symbol,ORDER_TYPE_BUY_STOP,lot,0.0,buyStopPrice,buySl,buyTp,typeTime,expiration,comment))
      g_pendingBuyStopTicket=trade.ResultOrder();
   else
      Print("Buy stop failed: ",trade.ResultRetcodeDescription()," price=",DoubleToString(buyStopPrice,digits));

   if(trade.OrderOpen(_Symbol,ORDER_TYPE_SELL_STOP,lot,0.0,sellStopPrice,sellSl,sellTp,typeTime,expiration,comment))
      g_pendingSellStopTicket=trade.ResultOrder();
   else
      Print("Sell stop failed: ",trade.ResultRetcodeDescription()," price=",DoubleToString(sellStopPrice,digits));
  }

void CloseDrawdownPositions()
  {
   ulong tickets[];
   int n=GetPositionTickets(_Symbol,InpMagicNumber,tickets);
   for(int i=0;i<n;i++)
     {
      if(!PositionSelectByTicket(tickets[i]))
         continue;
      double profit=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(profit<0.0)
        {
         if(trade.PositionClose(tickets[i]))
            Print("Closed drawdown position #",tickets[i]," profit=",DoubleToString(profit,2));
         else
            Print("Failed to close drawdown position #",tickets[i]," error=",GetLastError());
        }
     }
  }

// Idempotent breakeven check: recomputes the target SL from position state every call,
// so it self-heals across EA restarts without needing separate "already armed" tracking.
void ManageBreakeven()
  {
   ulong tickets[];
   int n=GetPositionTickets(_Symbol,InpMagicNumber,tickets);
   if(n==0) return;

   double spreadPips=CurrentSpreadPips();
   double bePips=spreadPips+InpBreakevenBufferPips;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   for(int i=0;i<n;i++)
     {
      if(!PositionSelectByTicket(tickets[i]))
         continue;

      long type=PositionGetInteger(POSITION_TYPE);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);

      if(type==POSITION_TYPE_BUY)
        {
         double profitPips=PriceToPips(_Symbol,bid-entry);
         double beSl=NormalizeDouble(entry+PipsToPrice(_Symbol,bePips),digits);
         if(profitPips>=InpBreakevenTriggerPips && currentSl<beSl)
           {
            if(trade.PositionModify(tickets[i],beSl,tp))
               Print("Breakeven applied to #",tickets[i]," new SL=",DoubleToString(beSl,digits));
           }
        }
      else if(type==POSITION_TYPE_SELL)
        {
         double profitPips=PriceToPips(_Symbol,entry-ask);
         double beSl=NormalizeDouble(entry-PipsToPrice(_Symbol,bePips),digits);
         if(profitPips>=InpBreakevenTriggerPips && (currentSl>beSl || currentSl==0.0))
           {
            if(trade.PositionModify(tickets[i],beSl,tp))
               Print("Breakeven applied to #",tickets[i]," new SL=",DoubleToString(beSl,digits));
           }
        }
     }
  }

double CurrentSpreadPips()
  {
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   return PriceToPips(_Symbol,ask-bid);
  }

bool SpreadOk()
  {
   return CurrentSpreadPips()<=InpMaxSpreadPips;
  }

bool WithinSession()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   int hour=dt.hour;
   if(InpTradingStartHour<=InpTradingEndHour)
      return hour>=InpTradingStartHour && hour<InpTradingEndHour;
   return hour>=InpTradingStartHour || hour<InpTradingEndHour;
  }
