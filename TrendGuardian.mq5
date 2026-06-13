//+------------------------------------------------------------------+
//|                                                    TrendGuardian |
//|                                    AlgoEdge Trading - Trend Guardian EA |
//|                                   https://github.com/imnotsmoke/trading-bot |
//+------------------------------------------------------------------+
#property copyright "AlgoEdge Trading"
#property link      "https://github.com/imnotsmoke/trading-bot"
#property version   "1.02"
#property description "Trend Guardian EA - Aggressive Daily Trading System"
#property description "EMA crossover + ADX filter + Metal-compatible spread handling"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| EA Parameters (User Configurable)                                |
//+------------------------------------------------------------------+
// --- Risk Management ---
input double   RiskPercent         = 1.0;       // % of equity to risk per trade
input double   FixedLotSize        = 0.0;       // Fixed lot size (0.0 = use risk-based calculation)
input int      MagicNumber         = 880123;    // Unique ID for EA orders

// --- Strategy Parameters ---
input int      FastEMA             = 10;        // Fast EMA period
input int      SlowEMA             = 30;        // Slow EMA period
input int      ADXPeriod           = 14;        // ADX period
input double   ADXThreshold        = 20.0;      // Minimum ADX value to allow trades
input int      ATRPeriod           = 14;        // ATR period
input double   SLMultiplier        = 2.0;       // ATR multiplier for Stop Loss
input double   TP_ATRMultiplier    = 4.0;       // ATR multiplier for Take Profit

// --- Filters ---
input double   MaxSpread           = 5.0;       // Max spread in pips (wider for XAU/XAG)
input int      MaxPositionsPerSymbol = 1;       // Max positions per symbol
input int      MaxTotalPositions   = 5;         // Max total positions across all symbols
input double   MaxDailyLossPercent = 10.0;      // Max daily loss % before stopping

// --- Time Filter ---
input bool     EnableTimeFilter    = false;     // Enable/Disable trading hours restriction
input int      StartHour           = 0;         // Trading start hour (Broker time)
input int      EndHour             = 23;        // Trading end hour (Broker time)

// --- Misc ---
input int      Slippage            = 10;        // Maximum slippage in points

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade         m_trade;
CPositionInfo  m_position;
CSymbolInfo    m_symbol;

// Indicator handles
int            handleFastEMA;
int            handleSlowEMA;
int            handleADX;
int            handleATR;

datetime       lastBarTime          = 0;
double         dailyStartingEquity  = 0;
int            lastDayOfMonth       = -1;
bool           dailyLossStopReached = false;
string         commentStr           = "TrendGuardian";

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Set magic number for trade object
   m_trade.SetExpertMagicNumber(MagicNumber);

   // Validate inputs
   if(FastEMA >= SlowEMA)
   {
      Print("ERROR: FastEMA (", FastEMA, ") must be less than SlowEMA (", SlowEMA, ")");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(RiskPercent <= 0 || RiskPercent > 100)
   {
      Print("ERROR: RiskPercent must be between 0 and 100");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(ADXThreshold <= 0)
   {
      Print("ERROR: ADXThreshold must be positive");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(SLMultiplier <= 0 || TP_ATRMultiplier <= 0)
   {
      Print("ERROR: SL/TP multipliers must be positive");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(MaxSpread <= 0)
   {
      Print("ERROR: MaxSpread must be positive");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(StartHour < 0 || StartHour > 23 || EndHour < 0 || EndHour > 23)
   {
      Print("ERROR: StartHour and EndHour must be between 0 and 23");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(FixedLotSize < 0.0)
   {
      Print("ERROR: FixedLotSize cannot be negative");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Initialize symbol info
   m_symbol.Name(Symbol());
   m_symbol.Refresh();

   // Create indicator handles
   handleFastEMA = iMA(_Symbol, _Period, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA = iMA(_Symbol, _Period, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleADX     = iADX(_Symbol, _Period, ADXPeriod, PRICE_CLOSE);
   handleATR     = iATR(_Symbol, _Period, ATRPeriod);

   if(handleFastEMA == INVALID_HANDLE || handleSlowEMA == INVALID_HANDLE ||
      handleADX == INVALID_HANDLE || handleATR == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles");
      return INIT_FAILED;
   }

   // Initialize daily equity tracking
   dailyStartingEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   lastDayOfMonth = TimeDay(TimeCurrent());
   dailyLossStopReached = false;

   Print("Trend Guardian EA v1.02 (MQL5) initialized successfully - Aggressive Daily Trading mode");
   Print("Magic Number: ", MagicNumber);
   Print("Risk: ", RiskPercent, "% per trade");
   Print("Fixed Lot Size: ", (FixedLotSize > 0.0) ? DoubleToString(FixedLotSize, 2) + " (fixed mode)" : "0.0 (risk-based mode)");
   Print("Time Filter: ", EnableTimeFilter ? "Enabled (" + IntegerToString(StartHour) + ":00-" + IntegerToString(EndHour) + ":00)" : "Disabled");
   Print("Max Spread: ", MaxSpread, " pips");

   // Warn if fixed lot size is below broker minimum
   if(FixedLotSize > 0.0)
   {
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(FixedLotSize < minLot)
      {
         Print("WARNING: FixedLotSize (", DoubleToString(FixedLotSize, 2), ") is below broker minimum (", minLot, "). Lot will be rounded up to minimum.");
      }
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release indicator handles
   if(handleFastEMA != INVALID_HANDLE) IndicatorRelease(handleFastEMA);
   if(handleSlowEMA != INVALID_HANDLE) IndicatorRelease(handleSlowEMA);
   if(handleADX != INVALID_HANDLE)     IndicatorRelease(handleADX);
   if(handleATR != INVALID_HANDLE)     IndicatorRelease(handleATR);

   Print("Trend Guardian EA deinitialized (reason: ", reason, ")");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // --- Check if symbol info is current ---
   m_symbol.Refresh();

   // --- Daily reset check ---
   CheckDailyReset();

   // --- Daily loss stop check ---
   if(dailyLossStopReached)
   {
      if(TimeDay(TimeCurrent()) != lastDayOfMonth)
      {
         dailyLossStopReached = false;
         dailyStartingEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         Print("New trading day. Daily loss limit reset.");
      }
      else
      {
         return; // Stop trading for the day
      }
   }

   // --- Check for new bar ---
   if(!IsNewBar())
      return;

   // --- Check time filter ---
   if(EnableTimeFilter && !IsTradingHours())
   {
      Print("Outside trading hours. Skipping...");
      return;
   }

   // --- Manage existing positions (trailing stop) ---
   ManagePositions();

   // --- Check if we can open new positions ---
   if(!CanOpenTrade())
      return;

   // --- Get indicator values ---
   double fastEMA[1], slowEMA[1];
   double prevFastEMA[1], prevSlowEMA[1];
   double adxValue[1];
   double atrValue[1];

   if(CopyBuffer(handleFastEMA, 0, 1, 1, prevFastEMA) <= 0 ||
      CopyBuffer(handleFastEMA, 0, 0, 1, fastEMA) <= 0 ||
      CopyBuffer(handleSlowEMA, 0, 1, 1, prevSlowEMA) <= 0 ||
      CopyBuffer(handleSlowEMA, 0, 0, 1, slowEMA) <= 0 ||
      CopyBuffer(handleADX, 0, 0, 1, adxValue) <= 0 ||
      CopyBuffer(handleATR, 0, 0, 1, atrValue) <= 0)
   {
      Print("ERROR: Failed to copy indicator buffers");
      return;
   }

   // Check for invalid/zero values
   if(fastEMA[0] == 0 || slowEMA[0] == 0 || adxValue[0] == 0 || atrValue[0] == 0)
   {
      Print("ERROR: Indicator values unavailable, skipping tick");
      return;
   }

   // --- Get spread in pips ---
   double spread = GetSpreadInPips();
   if(spread > MaxSpread)
   {
      Print("Spread (", DoubleToString(spread, 1), " pips) exceeds maximum (", MaxSpread, " pips). No trade.");
      return;
   }

   // --- Check ADX filter ---
   if(adxValue[0] < ADXThreshold)
   {
      Print("ADX (", DoubleToString(adxValue[0], 1), ") below threshold (", ADXThreshold, "). No trade.");
      return;
   }

   // --- Entry signals ---
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double close = GetClose(0);

   // Long Entry: Fast EMA crosses above Slow EMA + ADX > threshold + Price above both EMAs
   if(prevFastEMA[0] <= prevSlowEMA[0] && fastEMA[0] > slowEMA[0] &&
      close > fastEMA[0] && close > slowEMA[0])
   {
      Print("LONG SIGNAL: FastEMA crossed above SlowEMA, ADX=", DoubleToString(adxValue[0], 1));
      OpenTrade(ORDER_TYPE_BUY, bid, ask, atrValue[0]);
   }
   // Short Entry: Fast EMA crosses below Slow EMA + ADX > threshold + Price below both EMAs
   else if(prevFastEMA[0] >= prevSlowEMA[0] && fastEMA[0] < slowEMA[0] &&
           close < fastEMA[0] && close < slowEMA[0])
   {
      Print("SHORT SIGNAL: FastEMA crossed below SlowEMA, ADX=", DoubleToString(adxValue[0], 1));
      OpenTrade(ORDER_TYPE_SELL, bid, ask, atrValue[0]);
   }
}

//+------------------------------------------------------------------+
//| Check if a new bar has formed                                    |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime curBarTime = iTime(_Symbol, _Period, 0);
   if(curBarTime == lastBarTime)
      return false;

   lastBarTime = curBarTime;
   return true;
}

//+------------------------------------------------------------------+
//| Check if current time is within trading hours                    |
//+------------------------------------------------------------------+
bool IsTradingHours()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int currentHour = dt.hour;

   if(StartHour <= EndHour)
   {
      if(currentHour >= StartHour && currentHour < EndHour)
         return true;
   }
   else
   {
      if(currentHour >= StartHour || currentHour < EndHour)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Check and reset daily equity tracking                            |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int currentDay = dt.day;

   if(currentDay != lastDayOfMonth)
   {
      lastDayOfMonth = currentDay;
      dailyStartingEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      dailyLossStopReached = false;
      Print("New trading day. Daily starting equity: ", DoubleToString(dailyStartingEquity, 2));
   }

   if(!dailyLossStopReached)
   {
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      double drawdown = 0;

      if(dailyStartingEquity > 0)
         drawdown = ((dailyStartingEquity - currentEquity) / dailyStartingEquity) * 100.0;

      if(drawdown >= MaxDailyLossPercent)
      {
         dailyLossStopReached = true;
         Print("DAILY LOSS LIMIT REACHED: Equity dropped ", DoubleToString(drawdown, 2),
               "% (limit: ", MaxDailyLossPercent, "%). Stopping trading for the day.");
      }
   }
}

//+------------------------------------------------------------------+
//| Check if we can open a new trade                                 |
//+------------------------------------------------------------------+
bool CanOpenTrade()
{
   int totalPositions = CountPositions();
   if(totalPositions >= MaxTotalPositions)
   {
      Print("Maximum total positions (", MaxTotalPositions, ") reached.");
      return false;
   }

   int symbolPositions = CountPositionsBySymbol(_Symbol);
   if(symbolPositions >= MaxPositionsPerSymbol)
   {
      Print("Maximum positions for ", _Symbol, " (", MaxPositionsPerSymbol, ") reached.");
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Get spread in pips                                               |
//+------------------------------------------------------------------+
double GetSpreadInPips()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double spreadPoints = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / point;

   // Handle fractional pip brokers (Digits=3/5) and metals (Digits=2 for XAUUSD)
   // Standard: 4-digit forex (Digits=4) -> pip = Point
   // 5-digit forex (Digits=5), JPY (Digits=3), Gold (Digits=2) -> pip = 10 * Point
   if(digits == 2 || digits == 3 || digits == 5)
      return spreadPoints / 10.0;
   else
      return spreadPoints;
}

//+------------------------------------------------------------------+
//| Get close price                                                  |
//+------------------------------------------------------------------+
double GetClose(int shift = 0)
{
   double closeArray[1];
   if(CopyClose(_Symbol, _Period, shift, 1, closeArray) > 0)
      return closeArray[0];
   return 0;
}

//+------------------------------------------------------------------+
//| Open a trade                                                     |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE orderType, double bid, double ask, double atrValue)
{
   // Calculate lot size based on risk
   double lotSize = CalculateLotSize(atrValue);
   if(lotSize <= 0)
   {
      Print("ERROR: Invalid lot size calculated (", lotSize, "). Cannot open trade.");
      return;
   }

   // Calculate SL and TP
   double slPrice = 0;
   double tpPrice = 0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(orderType == ORDER_TYPE_BUY)
   {
      slPrice = ask - (SLMultiplier * atrValue);
      tpPrice = ask + (TP_ATRMultiplier * atrValue);

      slPrice = NormalizeDouble(slPrice, digits);
      tpPrice = NormalizeDouble(tpPrice, digits);

      if(slPrice >= bid)
      {
         Print("ERROR: Invalid SL for BUY (SL: ", slPrice, " >= Bid: ", bid, ")");
         return;
      }

      Print("BUY ORDER: Lots=", DoubleToString(lotSize, 2),
            ", SL=", DoubleToString(slPrice, digits),
            ", TP=", DoubleToString(tpPrice, digits),
            ", Ask=", DoubleToString(ask, digits));

      if(m_trade.Buy(lotSize, _Symbol, ask, slPrice, tpPrice, commentStr))
      {
         Print("BUY order placed successfully. Ticket: ", m_trade.ResultOrder());
      }
      else
      {
         Print("ERROR placing BUY order: ", GetLastError());
      }
   }
   else if(orderType == ORDER_TYPE_SELL)
   {
      slPrice = bid + (SLMultiplier * atrValue);
      tpPrice = bid - (TP_ATRMultiplier * atrValue);

      slPrice = NormalizeDouble(slPrice, digits);
      tpPrice = NormalizeDouble(tpPrice, digits);

      if(slPrice <= ask)
      {
         Print("ERROR: Invalid SL for SELL (SL: ", slPrice, " <= Ask: ", ask, ")");
         return;
      }

      Print("SELL ORDER: Lots=", DoubleToString(lotSize, 2),
            ", SL=", DoubleToString(slPrice, digits),
            ", TP=", DoubleToString(tpPrice, digits),
            ", Bid=", DoubleToString(bid, digits));

      if(m_trade.Sell(lotSize, _Symbol, bid, slPrice, tpPrice, commentStr))
      {
         Print("SELL order placed successfully. Ticket: ", m_trade.ResultOrder());
      }
      else
      {
         Print("ERROR placing SELL order: ", GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk % of equity or fixed lot        |
//+------------------------------------------------------------------+
double CalculateLotSize(double atrValue)
{
   // --- Fixed lot size mode ---
   if(FixedLotSize > 0.0)
   {
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

      double lots = fmax(FixedLotSize, minLot);
      lots = fmin(lots, maxLot);
      lots = MathFloor(lots / lotStep) * lotStep;
      lots = NormalizeDouble(lots, 2);

      Print("Position Sizing (FIXED): FixedLotSize=", DoubleToString(FixedLotSize, 2),
            ", Adjusted lots=", DoubleToString(lots, 2));
      return lots;
   }

   // --- Risk-based calculation (default) ---
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (RiskPercent / 100.0);

   // Calculate SL distance in price units
   double slDistance = SLMultiplier * atrValue;

   // Get market info
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tickValue <= 0 || tickSize <= 0 || lotStep <= 0)
   {
      Print("ERROR: Unable to calculate lot size. Check MarketInfo values.");
      return 0;
   }

   // Risk per standard lot = SL distance in points * tick value
   double slInPoints = slDistance / point;
   double riskPerStandardLot = slInPoints * tickValue;

   if(riskPerStandardLot <= 0)
   {
      Print("ERROR: Risk per standard lot is zero or negative.");
      return 0;
   }

   // Ideal lot size = riskAmount / riskPerStandardLot
   double idealLot = riskAmount / riskPerStandardLot;

   // Round down to nearest lot step
   double lots = MathFloor(idealLot / lotStep) * lotStep;

   // Clamp to min/max
   lots = fmax(lots, minLot);
   lots = fmin(lots, maxLot);

   // Normalize to 2 decimal places
   lots = NormalizeDouble(lots, 2);

   Print("Position Sizing: Equity=", DoubleToString(equity, 2),
         ", Risk=", DoubleToString(riskAmount, 2),
         ", SL pts=", DoubleToString(slInPoints, 1),
         ", TickVal=", DoubleToString(tickValue, 6),
         ", Lots=", DoubleToString(lots, 2));

   return lots;
}

//+------------------------------------------------------------------+
//| Manage existing positions - trailing stop logic                  |
//| 1. Move SL to break-even when profit >= 1.0 * ATR               |
//| 2. After break-even, trail SL by SLMultiplier * ATR from price  |
//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i))
         continue;

      // Only manage our own positions
      if(m_position.Magic() != MagicNumber)
         continue;

      // Only manage positions for this chart symbol
      if(m_position.Symbol() != _Symbol)
         continue;

      // Only manage buy/sell positions
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)m_position.PositionType();
      if(posType != POSITION_TYPE_BUY && posType != POSITION_TYPE_SELL)
         continue;

      // Get current ATR value for trailing calculation
      double atrBuffer[1];
      if(CopyBuffer(handleATR, 0, 0, 1, atrBuffer) <= 0 || atrBuffer[0] <= 0)
         continue;

      double atrValue = atrBuffer[0];
      double currentSL = m_position.StopLoss();
      double openPrice = m_position.PriceOpen();
      double tpPrice = m_position.TakeProfit();
      double atrDistance = SLMultiplier * atrValue;
      double beThreshold = atrValue; // 1.0 * ATR for break-even trigger

      if(posType == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profitPrice = bid - openPrice;

         if(profitPrice < beThreshold)
            continue;

         // Step 1: Move SL to break-even if not already there
         if(currentSL < openPrice)
         {
            double beSL = NormalizeDouble(openPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
            if(m_trade.PositionModify(m_position.Ticket(), beSL, tpPrice))
            {
               Print("BUY #", m_position.Ticket(), " moved to break-even at ", DoubleToString(beSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
            }
            else
            {
               Print("ERROR: BUY #", m_position.Ticket(), " break-even modify failed: ", GetLastError());
            }
         }
         else
         {
            // Step 2: Trail by SLMultiplier * ATR from current price
            double trailSL = NormalizeDouble(bid - atrDistance, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

            if(trailSL > currentSL && trailSL > openPrice)
            {
               if(m_trade.PositionModify(m_position.Ticket(), trailSL, tpPrice))
               {
                  Print("BUY #", m_position.Ticket(), " trailing SL updated to ", DoubleToString(trailSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
               }
               else
               {
                  Print("ERROR: BUY #", m_position.Ticket(), " trailing SL modify failed: ", GetLastError());
               }
            }
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitPrice = openPrice - ask;

         if(profitPrice < beThreshold)
            continue;

         // Step 1: Move SL to break-even if not already there
         if(currentSL > openPrice)
         {
            double beSL = NormalizeDouble(openPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
            if(m_trade.PositionModify(m_position.Ticket(), beSL, tpPrice))
            {
               Print("SELL #", m_position.Ticket(), " moved to break-even at ", DoubleToString(beSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
            }
            else
            {
               Print("ERROR: SELL #", m_position.Ticket(), " break-even modify failed: ", GetLastError());
            }
         }
         else
         {
            // Step 2: Trail by SLMultiplier * ATR from current price
            double trailSL = NormalizeDouble(ask + atrDistance, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

            if(trailSL < currentSL && trailSL < openPrice)
            {
               if(m_trade.PositionModify(m_position.Ticket(), trailSL, tpPrice))
               {
                  Print("SELL #", m_position.Ticket(), " trailing SL updated to ", DoubleToString(trailSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
               }
               else
               {
                  Print("ERROR: SELL #", m_position.Ticket(), " trailing SL modify failed: ", GetLastError());
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Count total positions (all symbols) owned by this EA             |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Magic() == MagicNumber)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Count positions for a specific symbol owned by this EA           |
//+------------------------------------------------------------------+
int CountPositionsBySymbol(string symbol)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Magic() == MagicNumber && m_position.Symbol() == symbol)
            count++;
      }
   }
   return count;
}
//+------------------------------------------------------------------+