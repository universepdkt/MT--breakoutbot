#ifndef __BREAKOUTSTOPBOT_RISKMANAGER_MQH__
#define __BREAKOUTSTOPBOT_RISKMANAGER_MQH__

#include "TradeUtils.mqh"

double CalcLotByRisk(const string symbol,double riskPercent,double slPips)
  {
   double minVol=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   if(slPips<=0.0) return minVol;

   double tickValue=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0.0) return minVol;

   double pipValuePerLot=tickValue*(PipSize(symbol)/tickSize);
   if(pipValuePerLot<=0.0) return minVol;

   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount=balance*(riskPercent/100.0);
   double lots=riskAmount/(slPips*pipValuePerLot);

   return NormalizeVolume(symbol,lots);
  }

#endif
