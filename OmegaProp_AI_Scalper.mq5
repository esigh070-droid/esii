#property copyright "2024"
#property link      "https://openai.com"
#property version   "1.00"
#property strict
/*
 OmegaProp_AI_Scalper.mq5
 -------------------------------------------------
 High-frequency intraday scalper tuned for prop-firm style constraints.
 Attach to an M1 chart of any supported symbol (default XAUUSD). The EA internally
 manages both XAUUSD and EURUSD provided that the broker supports simultaneous
 trading from a single chart instance.
 
 Setup Notes:
 - Configure risk parameters to respect prop limits (AccountRiskPerTradePercent,
   MaxDailyLossPercent, MaxTotalLossPercent, TargetProfitPercent).
 - Allow WebRequest access to the configured AI_Server_URL if AI MetaBrain is used.
 - Test extensively on demo / evaluation accounts. There is no performance guarantee.
*/

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>

CTrade        trade;
CPositionInfo pos;
CSymbolInfo   symbolInfo;

enum BiasDirection
  {
   BIAS_NEUTRAL = 0,
   BIAS_LONG,
   BIAS_SHORT
  };

struct RangeInfo
  {
   bool     valid;
   double   high;
   double   low;
   datetime timestamp;
  };

struct TickSpeedTracker
  {
   double   ticks[];
   double   avg;
   datetime lastCleanup;
   long     lastTickMsc;
  };

struct TradeState
  {
   bool     hasPosition;
   double   entryPrice;
   double   stopLoss;
   double   slDistance;
   double   oneR;
   bool     partialTaken;
   datetime openTime;
   double   atrAtEntry;
  };

struct NewsInterval
  {
   datetime start;
   datetime end;
  };

struct AIState
  {
   bool     pause;
   double   riskMultiplier;
   string   regime;
   datetime lastUpdate;
  };

//--- Input parameters -------------------------------------------------------
input bool   Trade_XAU                    = true;
input bool   Trade_EUR                    = true;
input string Symbol_XAU                   = "XAUUSD";
input string Symbol_EUR                   = "EURUSD";

input int    EMA_Fast_Period_M5           = 50;
input int    EMA_Slow_Period_M5           = 200;

input double VWAP_TolerancePips_XAU       = 30.0;
input double VWAP_TolerancePips_EUR       = 2.5;

input int    N_RangeBars                  = 6;
input double MaxRangePips_XAU             = 35.0;
input double MaxRangePips_EUR             = 4.0;

input double BreakoutBufferPips_XAU       = 4.0;
input double BreakoutBufferPips_EUR       = 0.5;
input double MaxBreakoutBodyATR_Multiple  = 1.8;

input int    ATR_Period_SL                = 14;
input double SL_ATR_MinFactor             = 0.8;
input double SL_ATR_MaxFactor             = 2.8;
input double SL_Struct_Buffer_Pips        = 2.0;
input double MinSL_Pips_XAU               = 15.0;
input double MaxSL_Pips_XAU               = 70.0;
input double MinSL_Pips_EUR               = 4.0;
input double MaxSL_Pips_EUR               = 25.0;

input double TP1_R_Multiple               = 2.0;
input double TP2_R_Multiple               = 3.0;
input double BE_Buffer_Pips               = 0.5;
input int    MaxHoldSeconds               = 900;

input double AccountRiskPerTradePercent   = 0.5;
input double MaxDailyLossPercent          = 4.0;
input double MaxTotalLossPercent          = 9.0;
input double EmergencySL_Percent          = 2.0;
input int    MaxConsecutiveLossesPerDay   = 4;
input int    MinMinutesBetweenTrades      = 2;
input double TargetProfitPercent          = 9.0;
input double MaxSpreadPips_XAU            = 35.0;
input double MaxSpreadPips_EUR            = 2.0;
input double MaxLotPerTrade               = 20.0;

input int    TickWindowSeconds            = 10;
input double TickSpeedMultiplier          = 1.5;

input bool   UseSessionFilter             = true;
input string LondonStart                  = "07:30";
input string LondonEnd                    = "16:00";
input string NewYorkStart                 = "13:00";
input string NewYorkEnd                   = "21:00";

input bool   UseNewsFilter                = false;
input string NewsBlackoutWindows          = ""; // Format: "2024.11.01 14:00-15:00;2024.11.02 12:00-12:30"

input bool   UseAI_MetaBrain              = false;
input string AI_Server_URL                = "https://example.com/ai";
input int    AI_UpdateIntervalMinutes     = 15;

input bool   EnableDashboard              = true;
input int    DashboardRefreshMillis       = 750;
input bool   EnableDebugLogs              = true;
input ulong  MagicNumber                  = 25011984;

//---------------------------------------------------------------------------
struct SymbolSettings
  {
   string symbol;
   bool   enabled;
   double vwapTolerance;
   double maxRangePips;
   double breakoutBuffer;
   double minSLPips;
   double maxSLPips;
   double maxSpreadPips;
  };

struct SymbolRuntime
  {
   SymbolSettings settings;
   RangeInfo      range;
   TickSpeedTracker tickTracker;
   TradeState     tradeState;
   datetime       lastTradeTime;
   BiasDirection  bias;
   double         lastAtr;
   int            emaFastHandle;
   int            emaSlowHandle;
   int            atrHandle;
  };

SymbolRuntime runtimes[2];
NewsInterval  newsIntervals[];
AIState       aiState;

// Risk tracking ------------------------------------------------------------
double        StartEquityOverall = 0.0;
double        DailyStartEquity   = 0.0;
datetime      DailyStartDate     = 0;
int           ConsecutiveLossesToday = 0;
int           TradesToday = 0;
int           WinsToday = 0;
double        DailyPnL = 0.0;
double        DailyPnLPercent = 0.0;
double        DailyDrawdownPercent = 0.0;
double        TotalDrawdownPercent = 0.0;
string        TradingHaltReason = "";

datetime      lastDashboardUpdate = 0;
datetime      lastGlobalTradeTime = 0;

// Utility helpers ---------------------------------------------------------
string FormatDouble(double value,int digits=2)
  {
   return(DoubleToString(value,digits));
  }

string TrimString(string value)
  {
   StringTrimLeft(value);
   StringTrimRight(value);
   return(value);
  }

void Log(string text)
  {
   if(EnableDebugLogs)
      Print(text);
  }

string ExtractJsonToken(const string json,const string key)
  {
   string pattern = "\""+key+"\"";
   int idx = StringFind(json,pattern);
   if(idx<0)
      return("");
   int colon = StringFind(json,":",idx+StringLen(pattern));
   if(colon<0)
      return("");
   int start = colon+1;
   while(start<StringLen(json) && (StringGetCharacter(json,start)==' ')) start++;
   if(start<StringLen(json) && StringGetCharacter(json,start)=='\"')
      start++;
   int end = start;
   while(end<StringLen(json))
     {
      ushort ch = StringGetCharacter(json,end);
      if(ch==',' || ch=='}' || ch=='\"')
         break;
      end++;
     }
   return(StringSubstr(json,start,end-start));
  }

double ExtractJsonDouble(const string json,const string key,double def)
  {
   string token = ExtractJsonToken(json,key);
   if(StringLen(token)==0)
      return(def);
   return(StringToDouble(token));
  }

bool ExtractJsonBool(const string json,const string key,bool def)
  {
   string token = StringToLower(ExtractJsonToken(json,key));
   if(token=="true")
      return(true);
   if(token=="false")
      return(false);
   return(def);
  }

string ExtractJsonString(const string json,const string key)
  {
   string pattern = "\""+key+"\"";
   int idx = StringFind(json,pattern);
   if(idx<0)
      return("");
   int firstQuote = StringFind(json,"\"",idx+StringLen(pattern));
   if(firstQuote<0)
      return("");
   firstQuote++;
   int secondQuote = StringFind(json,"\"",firstQuote);
   if(secondQuote<0)
      return("");
   return(StringSubstr(json,firstQuote,secondQuote-firstQuote));
  }

//---------------------------------------------------------------------------
bool ParseTimeHM(string text,int &hours,int &minutes)
  {
   ushort chars[];
   StringToCharArray(text,chars);
   string parts[];
   int count = StringSplit(text,':',parts);
   if(count!=2) return(false);
   hours = (int)StringToInteger(parts[0]);
   minutes = (int)StringToInteger(parts[1]);
   return(true);
  }

datetime BuildSessionTime(int hours,int minutes)
  {
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(),tm);
   tm.hour = hours;
   tm.min = minutes;
   tm.sec = 0;
   return(StructToTime(tm));
  }

bool IsWithinSessions()
  {
   if(!UseSessionFilter)
      return(true);
   int h,m;
   int h2,m2;
   if(!ParseTimeHM(LondonStart,h,m)) return(true);
   if(!ParseTimeHM(LondonEnd,h2,m2)) return(true);
   datetime londonStart = BuildSessionTime(h,m);
   datetime londonEnd = BuildSessionTime(h2,m2);
   if(TimeCurrent()>=londonStart && TimeCurrent()<=londonEnd)
      return(true);
   if(!ParseTimeHM(NewYorkStart,h,m)) return(false);
   if(!ParseTimeHM(NewYorkEnd,h2,m2)) return(false);
   datetime nyStart = BuildSessionTime(h,m);
   datetime nyEnd   = BuildSessionTime(h2,m2);
   if(TimeCurrent()>=nyStart && TimeCurrent()<=nyEnd)
      return(true);
   return(false);
  }

void ParseNewsIntervals()
  {
   ArrayResize(newsIntervals,0);
   if(!UseNewsFilter || StringLen(NewsBlackoutWindows)==0)
      return;
   string segments[];
   int count = StringSplit(NewsBlackoutWindows,';',segments);
   for(int i=0;i<count;i++)
     {
      string segment = TrimString(segments[i]);
      if(StringLen(segment)==0) continue;
      int delim = StringFind(segment," ");
      if(delim<0) continue;
      string date = StringSubstr(segment,0,delim);
      string range = StringSubstr(segment,delim+1);
      string times[];
      if(StringSplit(range,'-',times)!=2) continue;
      datetime start = StringToTime(date+" "+times[0]);
      datetime end   = StringToTime(date+" "+times[1]);
      if(end<=start) continue;
      NewsInterval ni;
      ni.start = start;
      ni.end = end;
      int newSize = ArraySize(newsIntervals)+1;
      ArrayResize(newsIntervals,newSize);
      newsIntervals[newSize-1] = ni;
     }
  }

bool IsNewsBlackout()
  {
   if(!UseNewsFilter) return(false);
   datetime now = TimeCurrent();
   for(int i=0;i<ArraySize(newsIntervals);i++)
     {
      if(now>=newsIntervals[i].start && now<=newsIntervals[i].end)
         return(true);
     }
   return(false);
  }

string GetNextNewsWindow()
  {
   if(!UseNewsFilter || ArraySize(newsIntervals)==0)
      return("-");
   datetime now = TimeCurrent();
   datetime best = 0;
   for(int i=0;i<ArraySize(newsIntervals);i++)
     {
      if(newsIntervals[i].start>now)
        {
         if(best==0 || newsIntervals[i].start<best)
            best = newsIntervals[i].start;
        }
     }
   if(best==0)
      return("-");
   return(TimeToString(best,TIME_MINUTES));
  }

//---------------------------------------------------------------------------
void InitSymbolRuntime(SymbolRuntime &rt,const SymbolSettings &settings)
  {
   rt.settings = settings;
   rt.range.valid = false;
   ArrayResize(rt.tickTracker.ticks,0);
   rt.tickTracker.avg = 0;
   rt.tickTracker.lastCleanup = TimeCurrent();
   rt.tickTracker.lastTickMsc = 0;
   rt.tradeState.hasPosition = false;
   rt.lastTradeTime = 0;
   rt.bias = BIAS_NEUTRAL;
   rt.emaFastHandle = iMA(rt.settings.symbol,PERIOD_M5,EMA_Fast_Period_M5,0,MODE_EMA,PRICE_CLOSE);
   rt.emaSlowHandle = iMA(rt.settings.symbol,PERIOD_M5,EMA_Slow_Period_M5,0,MODE_EMA,PRICE_CLOSE);
   rt.atrHandle = iATR(rt.settings.symbol,PERIOD_M1,ATR_Period_SL);
   if(rt.emaFastHandle==INVALID_HANDLE || rt.emaSlowHandle==INVALID_HANDLE || rt.atrHandle==INVALID_HANDLE)
      Log("Indicator handle creation failed for "+rt.settings.symbol);
  }

SymbolRuntime* GetRuntime(int index)
  {
   return(&runtimes[index]);
  }

int SymbolIndex(const string symbol)
  {
   for(int i=0;i<ArraySize(runtimes);i++)
     {
      if(runtimes[i].settings.symbol==symbol)
         return(i);
     }
   return(-1);
  }

//---------------------------------------------------------------------------
bool UpdateBias(SymbolRuntime &rt)
  {
   double fast[3];
   double slow[3];
   if(CopyBuffer(rt.emaFastHandle,0,1,2,fast)!=2)
      return(false);
   if(CopyBuffer(rt.emaSlowHandle,0,1,2,slow)!=2)
      return(false);
   double closePrice;
   double closeArray[];
   if(CopyClose(rt.settings.symbol,PERIOD_M5,1,1,closeArray)!=1)
      return(false);
   closePrice = closeArray[0];
   if(fast[1]>slow[1] && closePrice>fast[1] && closePrice>slow[1])
      rt.bias = BIAS_LONG;
   else if(fast[1]<slow[1] && closePrice<fast[1] && closePrice<slow[1])
      rt.bias = BIAS_SHORT;
   else
      rt.bias = BIAS_NEUTRAL;
   return(true);
  }

//---------------------------------------------------------------------------
bool CalcVWAPCondition(SymbolRuntime &rt,double &vwap,bool &priceOK)
  {
   datetime startOfDay = iTime(rt.settings.symbol,PERIOD_D1,0);
   MqlRates rates[];
   if(CopyRates(rt.settings.symbol,PERIOD_M1,startOfDay,TimeCurrent(),rates)<=0)
      return(false);
   double num=0,den=0;
   for(int i=0;i<ArraySize(rates);i++)
     {
      double typical = (rates[i].high+rates[i].low+rates[i].close)/3.0;
      num += typical * rates[i].tick_volume;
      den += rates[i].tick_volume;
     }
   if(den==0)
      return(false);
   vwap = num/den;
   double closeArr[];
   if(CopyClose(rt.settings.symbol,PERIOD_M1,1,1,closeArr)!=1)
      return(false);
   double close = closeArr[0];
   double tolerance = rt.settings.vwapTolerance * SymbolInfoDouble(rt.settings.symbol,SYMBOL_POINT);
   if(rt.bias==BIAS_LONG)
      priceOK = (close >= vwap - tolerance);
   else if(rt.bias==BIAS_SHORT)
      priceOK = (close <= vwap + tolerance);
   else
      priceOK = false;
   return(true);
  }

//---------------------------------------------------------------------------
bool DetectMicroRange(SymbolRuntime &rt)
  {
   MqlRates rates[];
   if(CopyRates(rt.settings.symbol,PERIOD_M1,1,N_RangeBars,rates)!=N_RangeBars)
     {
      rt.range.valid=false;
      return(false);
     }
   double maxHigh = rates[0].high;
   double minLow  = rates[0].low;
   for(int i=1;i<N_RangeBars;i++)
     {
      maxHigh = MathMax(maxHigh,rates[i].high);
      minLow  = MathMin(minLow,rates[i].low);
     }
   double rangePips = (maxHigh-minLow)/SymbolInfoDouble(rt.settings.symbol,SYMBOL_POINT);
   double limit = rt.settings.maxRangePips;
   if(rangePips<=limit)
     {
      rt.range.valid = true;
      rt.range.high = maxHigh;
      rt.range.low = minLow;
      rt.range.timestamp = rates[0].time;
      return(true);
     }
   rt.range.valid=false;
   return(false);
  }

//---------------------------------------------------------------------------
void UpdateTickSpeed(SymbolRuntime &rt)
  {
   MqlTick tick;
   if(!SymbolInfoTick(rt.settings.symbol,tick))
      return;
   if(rt.tickTracker.lastTickMsc!=0 && rt.tickTracker.lastTickMsc==tick.time_msc)
      return;
   rt.tickTracker.lastTickMsc = tick.time_msc;
   datetime now = (datetime)(tick.time_msc/1000);
   int size = ArraySize(rt.tickTracker.ticks);
   ArrayResize(rt.tickTracker.ticks,size+1);
   rt.tickTracker.ticks[size] = now;
   // cleanup
   double window = TickWindowSeconds;
   if(window<=0)
      window = 5;
   int newSize = 0;
   for(int i=0;i<ArraySize(rt.tickTracker.ticks);i++)
     {
      if(now-rt.tickTracker.ticks[i]<=window)
        {
         rt.tickTracker.ticks[newSize++] = rt.tickTracker.ticks[i];
        }
     }
   ArrayResize(rt.tickTracker.ticks,newSize);
   double currentCount = newSize;
   if(rt.tickTracker.avg==0)
      rt.tickTracker.avg = currentCount;
   else
      rt.tickTracker.avg = 0.8*rt.tickTracker.avg + 0.2*currentCount;
  }

bool TickSpeedOK(SymbolRuntime &rt)
  {
   double current = ArraySize(rt.tickTracker.ticks);
   if(rt.tickTracker.avg<1.0)
      return(false);
   return(current>TickSpeedMultiplier*rt.tickTracker.avg);
  }

//---------------------------------------------------------------------------
double GetATR(SymbolRuntime &rt)
  {
   double buffer[3];
   if(CopyBuffer(rt.atrHandle,0,1,1,buffer)!=1)
      return(0);
   rt.lastAtr = buffer[0];
   return(rt.lastAtr);
  }

//---------------------------------------------------------------------------
bool GetSwingLevels(string symbol,double &swingHigh,double &swingLow)
  {
   MqlRates rates[];
   if(CopyRates(symbol,PERIOD_M1,1,10,rates)<5)
      return(false);
   swingHigh = rates[0].high;
   swingLow  = rates[0].low;
   for(int i=1;i<10;i++)
     {
      swingHigh = MathMax(swingHigh,rates[i].high);
      swingLow  = MathMin(swingLow,rates[i].low);
     }
   return(true);
  }

//---------------------------------------------------------------------------
bool ComputeSmartSL(SymbolRuntime &rt,double entryPrice,bool isBuy,double &sl,double &slPips,double atr)
  {
   double swingHigh,swingLow;
   if(!GetSwingLevels(rt.settings.symbol,swingHigh,swingLow))
      return(false);
   double slBase;
   double point = SymbolInfoDouble(rt.settings.symbol,SYMBOL_POINT);
   if(isBuy)
     {
      slBase = MathMin(rt.range.low,MathMin(swingLow,entryPrice)) - SL_Struct_Buffer_Pips*point;
     }
   else
     {
      slBase = MathMax(rt.range.high,MathMax(swingHigh,entryPrice)) + SL_Struct_Buffer_Pips*point;
     }
   double slDist = MathAbs(entryPrice-slBase);
   double minDist = SL_ATR_MinFactor*atr;
   double maxDist = SL_ATR_MaxFactor*atr;
   if(slDist<minDist)
      slDist = minDist;
   if(slDist>maxDist)
      return(false);
   double slPipsRaw = slDist/point;
   double minSL = rt.settings.minSLPips;
   double maxSL = rt.settings.maxSLPips;
   if(slPipsRaw<minSL)
     {
      slDist = minSL*point;
      slPipsRaw = minSL;
     }
   if(slPipsRaw>maxSL)
      return(false);
   slPips = slPipsRaw;
   if(isBuy)
      sl = entryPrice - slDist;
   else
      sl = entryPrice + slDist;
   return(true);
  }

//---------------------------------------------------------------------------
double CalculateLotSize(const string symbol,double slPips,double riskPercent)
  {
   if(slPips<=0) return(0.0);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * riskPercent/100.0;
   double tickValue = SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
   double point = SymbolInfoDouble(symbol,SYMBOL_POINT);
   double tickSize = SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickSize==0)
      tickSize = point;
   double pipValue = tickValue * point/tickSize;
   if(pipValue==0)
      pipValue = tickValue;
   double lot = riskAmount/(slPips*pipValue);
   double minLot = SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   double maxLot = MathMin(SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX),MaxLotPerTrade);
   double step = SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   lot = MathMax(minLot,MathMin(maxLot,lot));
   lot = MathFloor(lot/step)*step;
   return(NormalizeDouble(lot,(int)SymbolInfoInteger(symbol,SYMBOL_VOLUME_DIGITS)));
  }

//---------------------------------------------------------------------------
bool CheckRiskLimits()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyDD = (equity-DailyStartEquity)/DailyStartEquity*100.0;
   double totalDD = (equity-StartEquityOverall)/StartEquityOverall*100.0;
   DailyDrawdownPercent = MathMin(0.0,dailyDD);
   TotalDrawdownPercent = MathMin(0.0,totalDD);
   if(equity>=StartEquityOverall*(1.0+TargetProfitPercent/100.0))
     {
      TradingHaltReason = "TargetHit";
      return(false);
     }
   if(dailyDD<=-MaxDailyLossPercent)
     {
      TradingHaltReason = "DailyLoss";
      return(false);
     }
   if(totalDD<=-MaxTotalLossPercent)
     {
      TradingHaltReason = "TotalLoss";
      return(false);
     }
   if(ConsecutiveLossesToday>=MaxConsecutiveLossesPerDay)
     {
      TradingHaltReason = "ConsecutiveLosses";
      return(false);
     }
   if(IsNewsBlackout())
     {
      TradingHaltReason = "News";
      return(false);
     }
   if(!IsWithinSessions())
     {
      TradingHaltReason = "Session";
      return(false);
     }
   if(aiState.pause)
     {
      TradingHaltReason = "AI_Pause";
      return(false);
     }
   TradingHaltReason = "";
   return(true);
  }

//---------------------------------------------------------------------------
bool SpreadOK(SymbolRuntime &rt)
  {
   MqlTick tick;
   if(!SymbolInfoTick(rt.settings.symbol,tick))
      return(false);
   double spread = (tick.ask - tick.bid)/SymbolInfoDouble(rt.settings.symbol,SYMBOL_POINT);
   return(spread<=rt.settings.maxSpreadPips);
  }

//---------------------------------------------------------------------------
bool TimeSinceLastTradeOK(SymbolRuntime &rt)
  {
   if(rt.lastTradeTime==0) return(true);
   int diff = (int)(TimeCurrent()-rt.lastTradeTime);
   return(diff >= MinMinutesBetweenTrades*60);
  }

bool GlobalCooldownOK()
  {
   if(lastGlobalTradeTime==0)
      return(true);
   int diff = (int)(TimeCurrent()-lastGlobalTradeTime);
   return(diff >= MinMinutesBetweenTrades*60);
  }

//---------------------------------------------------------------------------
void UpdateTradeStats()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(DailyStartEquity<=0)
      DailyStartEquity = equity;
   DailyPnL = equity-DailyStartEquity;
   DailyPnLPercent = DailyPnL/DailyStartEquity*100.0;
  }

//---------------------------------------------------------------------------
void RefreshDailySession()
  {
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(),tm);
   MqlDateTime prev;
   if(DailyStartDate!=0)
      TimeToStruct(DailyStartDate,prev);
   if(DailyStartDate==0 || prev.day!=tm.day || prev.mon!=tm.mon || prev.year!=tm.year)
     {
      DailyStartDate = TimeCurrent();
      DailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      ConsecutiveLossesToday = 0;
      TradesToday = 0;
      WinsToday = 0;
     }
  }

//---------------------------------------------------------------------------
bool EmergencyStopCheck(SymbolRuntime &rt)
  {
   if(!PositionSelect(rt.settings.symbol))
      return(false);
   MqlTick tick;
   SymbolInfoTick(rt.settings.symbol,tick);
   long type = PositionGetInteger(POSITION_TYPE);
   double price = (type==POSITION_TYPE_BUY)?tick.bid:tick.ask;
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double point = SymbolInfoDouble(rt.settings.symbol,SYMBOL_POINT);
   double loss = (type==POSITION_TYPE_BUY)?(entry-price):(price-entry);
   double lossMoney = loss/point*SymbolInfoDouble(rt.settings.symbol,SYMBOL_TRADE_TICK_VALUE)*volume;
   double threshold = AccountInfoDouble(ACCOUNT_BALANCE)*EmergencySL_Percent/100.0;
   if(lossMoney>=threshold)
     {
      Log("Emergency SL triggered for "+rt.settings.symbol);
      trade.PositionClose(rt.settings.symbol);
      return(true);
     }
   return(false);
  }

//---------------------------------------------------------------------------
void ManageOpenTrade(SymbolRuntime &rt)
  {
   if(!PositionSelect(rt.settings.symbol))
     {
      rt.tradeState.hasPosition=false;
      return;
     }
   rt.tradeState.hasPosition=true;
   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   MqlTick tick;
   SymbolInfoTick(rt.settings.symbol,tick);
   long positionType = PositionGetInteger(POSITION_TYPE);
   double currentPrice = (positionType==POSITION_TYPE_BUY)?tick.bid:tick.ask;
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double slDistance = MathAbs(entryPrice-sl);
   double oneR = slDistance;
   double volume = PositionGetDouble(POSITION_VOLUME);
   bool isBuy = positionType==POSITION_TYPE_BUY;
   // partial close at +1R
   double target = isBuy?(entryPrice+oneR):(entryPrice-oneR);
   if(!rt.tradeState.partialTaken)
     {
      if( (isBuy && currentPrice>=target) || (!isBuy && currentPrice<=target) )
        {
         double closeVolume = volume*0.5;
         double minVol = SymbolInfoDouble(rt.settings.symbol,SYMBOL_VOLUME_MIN);
         double step = SymbolInfoDouble(rt.settings.symbol,SYMBOL_VOLUME_STEP);
         closeVolume = MathMax(minVol,MathFloor(closeVolume/step)*step);
         closeVolume = MathMin(volume-minVol,closeVolume);
         if(closeVolume>0 && closeVolume>=minVol)
            trade.PositionClosePartial(rt.settings.symbol,closeVolume);
         double newSL = isBuy ? entryPrice + BE_Buffer_Pips*SymbolInfoDouble(rt.settings.symbol,SYMBOL_POINT) : entryPrice - BE_Buffer_Pips*SymbolInfoDouble(rt.settings.symbol,SYMBOL_POINT);
         trade.PositionModify(rt.settings.symbol,newSL,tp);
         rt.tradeState.partialTaken = true;
        }
     }
   // time-based management
   if(MaxHoldSeconds>0 && TimeCurrent()-PositionGetInteger(POSITION_TIME) > MaxHoldSeconds)
     {
      double lockPrice = isBuy ? entryPrice + 0.3*oneR : entryPrice - 0.3*oneR;
      trade.PositionModify(rt.settings.symbol,lockPrice,tp);
     }
   // trailing logic using fractals approximated by ATR
   double atr = GetATR(rt);
   double trailBuffer = 0.5*atr;
   if(isBuy)
     {
      double newSL = currentPrice - trailBuffer;
      if(newSL>sl)
         trade.PositionModify(rt.settings.symbol,newSL,tp);
     }
   else
     {
      double newSL = currentPrice + trailBuffer;
      if(newSL<sl)
         trade.PositionModify(rt.settings.symbol,newSL,tp);
     }
   EmergencyStopCheck(rt);
  }

//---------------------------------------------------------------------------
bool EvaluateBreakout(SymbolRuntime &rt,bool isBuy,double atr,double &entryPrice)
  {
   if(!rt.range.valid) return(false);
   MqlRates lastBar[];
   if(CopyRates(rt.settings.symbol,PERIOD_M1,1,1,lastBar)!=1)
      return(false);
   double breakoutBuffer = rt.settings.breakoutBuffer * SymbolInfoDouble(rt.settings.symbol,SYMBOL_POINT);
   double body = MathAbs(lastBar[0].close - lastBar[0].open);
   if(body>MaxBreakoutBodyATR_Multiple*atr)
      return(false);
   if(isBuy)
     {
      if(lastBar[0].close>rt.range.high+breakoutBuffer)
        {
         entryPrice = SymbolInfoDouble(rt.settings.symbol,SYMBOL_ASK);
         return(true);
        }
     }
   else
     {
      if(lastBar[0].close<rt.range.low-breakoutBuffer)
        {
         entryPrice = SymbolInfoDouble(rt.settings.symbol,SYMBOL_BID);
         return(true);
        }
     }
   return(false);
  }

//---------------------------------------------------------------------------
bool OpenTrade(SymbolRuntime &rt,bool isBuy)
  {
   double atr = GetATR(rt);
   if(atr<=0)
      return(false);
   double entryPrice;
   if(!EvaluateBreakout(rt,isBuy,atr,entryPrice))
      return(false);
   double slPrice,slPips;
   if(!ComputeSmartSL(rt,entryPrice,isBuy,slPrice,slPips,atr))
      return(false);
   double riskPercent = AccountRiskPerTradePercent;
   if(aiState.riskMultiplier>0)
      riskPercent *= aiState.riskMultiplier;
   riskPercent = MathMax(0.25,riskPercent);
   riskPercent = MathMin(0.75,riskPercent);
   double lot = CalculateLotSize(rt.settings.symbol,slPips,riskPercent);
   if(lot<=0)
      return(false);
   double tp1 = isBuy ? entryPrice + slPips*SymbolInfoDouble(rt.settings.symbol,SYMBOL_POINT)*TP1_R_Multiple : entryPrice - slPips*SymbolInfoDouble(rt.settings.symbol,SYMBOL_POINT)*TP1_R_Multiple;
   double tp2 = isBuy ? entryPrice + slPips*SymbolInfoDouble(rt.settings.symbol,SYMBOL_POINT)*TP2_R_Multiple : entryPrice - slPips*SymbolInfoDouble(rt.settings.symbol,SYMBOL_POINT)*TP2_R_Multiple;
   double tp = tp2;
   trade.SetExpertMagicNumber(MagicNumber);
   bool result = isBuy ? trade.Buy(lot,rt.settings.symbol,0.0,slPrice,tp,"OmegaBuy") : trade.Sell(lot,rt.settings.symbol,0.0,slPrice,tp,"OmegaSell");
   if(result)
     {
      if(PositionSelect(rt.settings.symbol))
         entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      rt.tradeState.hasPosition=true;
      rt.tradeState.entryPrice=entryPrice;
      rt.tradeState.stopLoss=slPrice;
      rt.tradeState.slDistance=MathAbs(entryPrice-slPrice);
      rt.tradeState.oneR=MathAbs(entryPrice-slPrice);
      rt.tradeState.partialTaken=false;
      rt.tradeState.openTime=TimeCurrent();
      rt.tradeState.atrAtEntry=atr;
      rt.lastTradeTime = TimeCurrent();
      lastGlobalTradeTime = TimeCurrent();
      TradesToday++;
     }
   else
     {
      Log("Trade failed: "+rt.settings.symbol+" error: "+IntegerToString(trade.ResultRetcode()));
     }
   return(result);
  }

//---------------------------------------------------------------------------
void CheckEntries(SymbolRuntime &rt)
  {
   if(!rt.settings.enabled)
      return;
   if(!CheckRiskLimits())
      return;
   if(!TimeSinceLastTradeOK(rt))
      return;
   if(!GlobalCooldownOK())
      return;
   if(PositionSelect(rt.settings.symbol))
      return;
   if(!SpreadOK(rt))
      return;
   if(!DetectMicroRange(rt))
      return;
   if(!UpdateBias(rt))
      return;
   if(rt.bias==BIAS_NEUTRAL)
      return;
   double vwap;
   bool priceOK;
   if(!CalcVWAPCondition(rt,vwap,priceOK))
      return;
   if(!priceOK)
      return;
   if(!TickSpeedOK(rt))
      return;
   bool isBuy = (rt.bias==BIAS_LONG);
   OpenTrade(rt,isBuy);
  }

//---------------------------------------------------------------------------
void UpdateDashboard()
  {
   if(!EnableDashboard)
      return;
   datetime now = TimeCurrent();
   if((now-lastDashboardUpdate)*1000<DashboardRefreshMillis)
      return;
   lastDashboardUpdate = now;
   string base = "OmegaDash";
   color panelColor = clrDimGray;
   string labels[] = {"Symbol","Spread","Bias","Tick","Trades","PnL","DD","Status"};
   if(ObjectFind(0,base+"BG")<0)
     {
      ObjectCreate(0,base+"BG",OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,base+"BG",OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,base+"BG",OBJPROP_XDISTANCE,5);
      ObjectSetInteger(0,base+"BG",OBJPROP_YDISTANCE,20);
      ObjectSetInteger(0,base+"BG",OBJPROP_XSIZE,250);
      ObjectSetInteger(0,base+"BG",OBJPROP_YSIZE,160);
      ObjectSetInteger(0,base+"BG",OBJPROP_COLOR,panelColor);
      ObjectSetInteger(0,base+"BG",OBJPROP_BACK,true);
     }
   string text;
   string symbolActive = Symbol();
   MqlTick dashTick;
   if(!SymbolInfoTick(symbolActive,dashTick))
     {
      dashTick.ask = SymbolInfoDouble(symbolActive,SYMBOL_ASK);
      dashTick.bid = SymbolInfoDouble(symbolActive,SYMBOL_BID);
     }
   double spread = (dashTick.ask-dashTick.bid)/SymbolInfoDouble(symbolActive,SYMBOL_POINT);
   string biasText = "-";
   double tickAvg = 0.0;
   int idx = SymbolIndex(symbolActive);
   if(idx>=0)
     {
      if(runtimes[idx].bias==BIAS_LONG) biasText="LONG";
      else if(runtimes[idx].bias==BIAS_SHORT) biasText="SHORT";
      else biasText="NEUTRAL";
      tickAvg = runtimes[idx].tickTracker.avg;
     }
   string status = (TradingHaltReason=="")?"Trading ON":"OFF:"+TradingHaltReason;
   text = "OmegaProp AI Scalper\n";
   text += "Symbol: "+symbolActive+" Spread:"+FormatDouble(spread,1)+"\n";
   text += "Bias: "+biasText+" TickAvg:"+FormatDouble(tickAvg,1)+"\n";
   text += "TradesToday: "+IntegerToString(TradesToday)+" Win%:"+FormatDouble(TradesToday>0?(double)WinsToday/TradesToday*100.0:0.0,1)+"\n";
   text += "DailyPnL: "+FormatDouble(DailyPnL,2)+" ("+FormatDouble(DailyPnLPercent,2)+"%)\n";
   text += "DailyDD: "+FormatDouble(DailyDrawdownPercent,2)+"% /"+FormatDouble(MaxDailyLossPercent,1)+"%\n";
   text += "TotalDD: "+FormatDouble(TotalDrawdownPercent,2)+"% /"+FormatDouble(MaxTotalLossPercent,1)+"%\n";
   text += "AI: "+(UseAI_MetaBrain?"ON":"OFF")+" Regime:"+aiState.regime+"\n";
   text += "NextNews: "+GetNextNewsWindow()+"\n";
   text += "Status: "+status+"\n";
   ObjectSetString(0,base+"BG",OBJPROP_TEXT,text);
  }

//---------------------------------------------------------------------------
void UpdateAI()
  {
   if(!UseAI_MetaBrain)
      return;
   if(AI_UpdateIntervalMinutes<=0)
      return;
   if(TimeCurrent()-aiState.lastUpdate < AI_UpdateIntervalMinutes*60)
      return;
   string payload;
   payload = "{\"equity\":"+FormatDouble(AccountInfoDouble(ACCOUNT_EQUITY),2)+",";
   payload += "\"daily_pnl\":"+FormatDouble(DailyPnL,2)+",";
   payload += "\"dd\":"+FormatDouble(DailyDrawdownPercent,2)+"}";
   string headers = "Content-Type: application/json\r\n";
   uchar post[];
   StringToCharArray(payload,post);
   uchar result[];
   string responseHeaders;
   int status = WebRequest("POST",AI_Server_URL,headers,5000,post,result,responseHeaders);
   if(status==200)
     {
      string response = CharArrayToString(result);
      aiState.regime = ExtractJsonString(response,"regime");
      aiState.pause = ExtractJsonBool(response,"pause_trading",false);
      double mult = ExtractJsonDouble(response,"risk_multiplier",1.0);
      aiState.riskMultiplier = mult;
     }
   aiState.lastUpdate = TimeCurrent();
  }

//---------------------------------------------------------------------------
void OnTick()
  {
   RefreshDailySession();
   UpdateTradeStats();
   UpdateAI();
  for(int i=0;i<ArraySize(runtimes);i++)
    {
     if(!runtimes[i].settings.enabled)
        continue;
     UpdateTickSpeed(runtimes[i]);
     ManageOpenTrade(runtimes[i]);
     CheckEntries(runtimes[i]);
    }
   UpdateDashboard();
  }

//---------------------------------------------------------------------------
int OnInit()
  {
   StartEquityOverall = AccountInfoDouble(ACCOUNT_EQUITY);
   DailyStartEquity = StartEquityOverall;
   DailyStartDate = TimeCurrent();
  SymbolSettings xau = {Symbol_XAU,Trade_XAU,VWAP_TolerancePips_XAU,MaxRangePips_XAU,BreakoutBufferPips_XAU,MinSL_Pips_XAU,MaxSL_Pips_XAU,MaxSpreadPips_XAU};
  SymbolSettings eur = {Symbol_EUR,Trade_EUR,VWAP_TolerancePips_EUR,MaxRangePips_EUR,BreakoutBufferPips_EUR,MinSL_Pips_EUR,MaxSL_Pips_EUR,MaxSpreadPips_EUR};
  SymbolSelect(Symbol_XAU,true);
  SymbolSelect(Symbol_EUR,true);
  InitSymbolRuntime(runtimes[0],xau);
  InitSymbolRuntime(runtimes[1],eur);
   ParseNewsIntervals();
   aiState.pause=false;
   aiState.riskMultiplier=1.0;
   aiState.regime="";
   aiState.lastUpdate=0;
   return(INIT_SUCCEEDED);
  }

//---------------------------------------------------------------------------
void OnDeinit(const int reason)
  {
   if(EnableDashboard)
     {
      string base = "OmegaDash";
      ObjectDelete(0,base+"BG");
     }
  }

//---------------------------------------------------------------------------
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(trans.entry!=DEAL_ENTRY_OUT)
      return;
   if(PositionSelect(trans.symbol))
      return; // partial exit still running
   double dealProfit = trans.profit;
   if(dealProfit>0)
     {
      WinsToday++;
      ConsecutiveLossesToday = 0;
     }
   else if(dealProfit<0)
     {
      ConsecutiveLossesToday++;
     }
   UpdateTradeStats();
  }

