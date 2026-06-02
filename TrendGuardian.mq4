//+------------------------------------------------------------------+
//|                                                    TrendGuardian |
//|                                    AlgoEdge Trading - Trend Guardian EA |
//|                                   https://github.com/imnotsmoke/trading-bot |
//+------------------------------------------------------------------+
#property copyright "AlgoEdge Trading"
#property link      "https://github.com/imnotsmoke/trading-bot"
#property version   "1.00"
#property strict
#property description "Trend Guardian EA - Conservative Trend Following System"
#property description "EMA crossover + ADX filter + ATR-based risk management"

//+------------------------------------------------------------------+
//| EA Parameters (User Configurable)                                |
//+------------------------------------------------------------------+
// --- Risk Management ---
input double   RiskPercent         = 1.0;      // % of equity to risk per trade
input int      MagicNumber         = 880123;   // Unique ID for EA orders

// --- Strategy Parameters ---
input int      FastEMA             = 20;       // Fast EMA period
input int      SlowEMA             = 50;       // Slow EMA period
input int      ADXPeriod           = 14;       // ADX period
input double   ADXThreshold        = 25.0;     // Minimum ADX value to allow trades
input int      ATRPeriod           = 14;       // ATR period
input double   SLMultiplier        = 1.5;      // ATR multiplier for Stop Loss
input double   TP_ATRMultiplier    = 3.0;      // ATR multiplier for Take Profit

// --- Filters ---
input double   MaxSpread           = 3.0;      // Max spread in pips
input int      MaxPositionsPerSymbol = 1;      // Max positions per symbol
input int      MaxTotalPositions   = 3;        // Max total positions across all symbols
input double   MaxDailyLossPercent = 3.0;      // Max daily loss % before stopping

// --- Time Filter ---
input bool     EnableTimeFilter    = true;     // Enable/Disable trading hours restriction
input int      StartHour           = 8;        // Trading start hour (Broker time)
input int      EndHour             = 20;       // Trading end hour (Broker time)

// --- Misc ---
input int      Slippage            = 3;        // Maximum slippage in pips

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
string   commentStr           = "TrendGuardian";
datetime lastBarTime          = 0;
double   dailyStartingEquity  = 0;
int      lastDayOfMonth       = -1;
bool     dailyLossStopReached = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
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

   // Initialize daily equity tracking
   dailyStartingEquity = AccountEquity();
   lastDayOfMonth = Day();
   dailyLossStopReached = false;

   Print("Trend Guardian EA v1.00 initialized successfully");
   Print("Magic Number: ", MagicNumber);
   Print("Risk: ", RiskPercent, "% per trade");
   Print("Time Filter: ", EnableTimeFilter ? "Enabled (" + IntegerToString(StartHour) + ":00-" + IntegerToString(EndHour) + ":00)" : "Disabled");
   Print("Max Spread: ", MaxSpread, " pips");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("Trend Guardian EA deinitialized (reason: ", reason, ")");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // --- Daily reset check ---
   CheckDailyReset();

   // --- Daily loss stop check ---
   if(dailyLossStopReached)
   {
      if(Day() != lastDayOfMonth)
      {
         dailyLossStopReached = false;
         dailyStartingEquity = AccountEquity();
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
   double fastEMA = GetFastEMA();
   double slowEMA = GetSlowEMA();
   double prevFastEMA = GetFastEMA(1);
   double prevSlowEMA = GetSlowEMA(1);
   double adxValue = GetADX();
   double atrValue = GetATR();

   // --- Validate indicator values ---
   if(fastEMA == 0 || slowEMA == 0 || adxValue == 0 || atrValue == 0)
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
   if(adxValue < ADXThreshold)
   {
      Print("ADX (", DoubleToString(adxValue, 1), ") below threshold (", ADXThreshold, "). No trade.");
      return;
   }

   // --- Entry signals ---
   double bid = Bid;
   double ask = Ask;
   double close = Close[0];

   // Long Entry: Fast EMA crosses above Slow EMA + ADX > 25 + Price above both EMAs
   if(prevFastEMA <= prevSlowEMA && fastEMA > slowEMA && close > fastEMA && close > slowEMA)
   {
      Print("LONG SIGNAL: FastEMA crossed above SlowEMA, ADX=", DoubleToString(adxValue, 1));
      OpenTrade(OP_BUY, bid, ask, atrValue);
   }
   // Short Entry: Fast EMA crosses below Slow EMA + ADX > 25 + Price below both EMAs
   else if(prevFastEMA >= prevSlowEMA && fastEMA < slowEMA && close < fastEMA && close < slowEMA)
   {
      Print("SHORT SIGNAL: FastEMA crossed below SlowEMA, ADX=", DoubleToString(adxValue, 1));
      OpenTrade(OP_SELL, bid, ask, atrValue);
   }
}

//+------------------------------------------------------------------+
//| Check if a new bar has formed                                    |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime curBarTime = Time[0];
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
   int currentHour = Hour();
   
   if(StartHour <= EndHour)
   {
      // Normal range (e.g., 08:00 - 20:00)
      if(currentHour >= StartHour && currentHour < EndHour)
         return true;
   }
   else
   {
      // Overnight range (e.g., 22:00 - 06:00)
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
   // If day changed, reset daily starting equity
   if(Day() != lastDayOfMonth)
   {
      lastDayOfMonth = Day();
      dailyStartingEquity = AccountEquity();
      dailyLossStopReached = false;
      Print("New trading day. Daily starting equity: ", DoubleToString(dailyStartingEquity, 2));
   }

   // Check if daily loss limit has been hit
   if(!dailyLossStopReached)
   {
      double currentEquity = AccountEquity();
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
   // Check total positions
   int totalPositions = CountPositions();
   if(totalPositions >= MaxTotalPositions)
   {
      Print("Maximum total positions (", MaxTotalPositions, ") reached.");
      return false;
   }

   // Check positions on this symbol
   int symbolPositions = CountPositionsBySymbol(Symbol());
   if(symbolPositions >= MaxPositionsPerSymbol)
   {
      Print("Maximum positions for ", Symbol(), " (", MaxPositionsPerSymbol, ") reached.");
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Get spread in pips                                               |
//+------------------------------------------------------------------+
double GetSpreadInPips()
{
   return (Ask - Bid) / Point;
}

//+------------------------------------------------------------------+
//| Get Fast EMA value                                               |
//+------------------------------------------------------------------+
double GetFastEMA(int shift = 0)
{
   return iMA(NULL, 0, FastEMA, 0, MODE_EMA, PRICE_CLOSE, shift);
}

//+------------------------------------------------------------------+
//| Get Slow EMA value                                               |
//+------------------------------------------------------------------+
double GetSlowEMA(int shift = 0)
{
   return iMA(NULL, 0, SlowEMA, 0, MODE_EMA, PRICE_CLOSE, shift);
}

//+------------------------------------------------------------------+
//| Get ADX value                                                    |
//+------------------------------------------------------------------+
double GetADX(int shift = 0)
{
   return iADX(NULL, 0, ADXPeriod, PRICE_CLOSE, MODE_MAIN, shift);
}

//+------------------------------------------------------------------+
//| Get ATR value                                                    |
//+------------------------------------------------------------------+
double GetATR(int shift = 0)
{
   return iATR(NULL, 0, ATRPeriod, shift);
}

//+------------------------------------------------------------------+
//| Open a trade                                                     |
//+------------------------------------------------------------------+
void OpenTrade(int orderType, double bid, double ask, double atrValue)
{
   // Calculate lot size based on risk
   double lotSize = CalculateLotSize(orderType, atrValue);
   if(lotSize <= 0)
   {
      Print("ERROR: Invalid lot size calculated (", lotSize, "). Cannot open trade.");
      return;
   }

   // Calculate SL and TP
   double slPrice = 0;
   double tpPrice = 0;

   if(orderType == OP_BUY)
   {
      slPrice = ask - (SLMultiplier * atrValue);
      tpPrice = ask + (TP_ATRMultiplier * atrValue);

      // Normalize prices
      slPrice = NormalizeDouble(slPrice, Digits);
      tpPrice = NormalizeDouble(tpPrice, Digits);

      // Verify SL is valid (must be below current price)
      if(slPrice >= bid)
      {
         Print("ERROR: Invalid SL for BUY (SL: ", slPrice, " >= Bid: ", bid, ")");
         return;
      }

      Print("BUY ORDER: Lots=", DoubleToString(lotSize, 2),
            ", SL=", DoubleToString(slPrice, Digits),
            ", TP=", DoubleToString(tpPrice, Digits),
            ", Ask=", DoubleToString(ask, Digits));

      int ticket = OrderSend(Symbol(), OP_BUY, lotSize, ask, Slippage, slPrice, tpPrice,
                             commentStr, MagicNumber, 0, Green);

      if(ticket > 0)
      {
         Print("BUY order placed successfully. Ticket: ", ticket);
      }
      else
      {
         Print("ERROR placing BUY order: ", GetLastError());
      }
   }
   else if(orderType == OP_SELL)
   {
      slPrice = bid + (SLMultiplier * atrValue);
      tpPrice = bid - (TP_ATRMultiplier * atrValue);

      // Normalize prices
      slPrice = NormalizeDouble(slPrice, Digits);
      tpPrice = NormalizeDouble(tpPrice, Digits);

      // Verify SL is valid (must be above current price)
      if(slPrice <= ask)
      {
         Print("ERROR: Invalid SL for SELL (SL: ", slPrice, " <= Ask: ", ask, ")");
         return;
      }

      Print("SELL ORDER: Lots=", DoubleToString(lotSize, 2),
            ", SL=", DoubleToString(slPrice, Digits),
            ", TP=", DoubleToString(tpPrice, Digits),
            ", Bid=", DoubleToString(bid, Digits));

      int ticket = OrderSend(Symbol(), OP_SELL, lotSize, bid, Slippage, slPrice, tpPrice,
                             commentStr, MagicNumber, 0, Red);

      if(ticket > 0)
      {
         Print("SELL order placed successfully. Ticket: ", ticket);
      }
      else
      {
         Print("ERROR placing SELL order: ", GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk % of equity                     |
//+------------------------------------------------------------------+
double CalculateLotSize(int orderType, double atrValue)
{
   double equity = AccountEquity();
   double riskAmount = equity * (RiskPercent / 100.0);

   // Calculate SL distance in price units (1.5 * ATR)
   double slDistance = SLMultiplier * atrValue;

   // Get market info
   double pipValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize = MarketInfo(Symbol(), MODE_TICKSIZE);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);

   if(pipValue <= 0 || tickSize <= 0 || lotStep <= 0)
   {
      Print("ERROR: Unable to calculate lot size. Check MarketInfo values.");
      return(0);
   }

   // Risk per standard lot = SL distance in pips * pip value
   double slInPips = slDistance / Point;
   double riskPerStandardLot = slInPips * pipValue;

   if(riskPerStandardLot <= 0)
   {
      Print("ERROR: Risk per standard lot is zero or negative.");
      return(0);
   }

   // Ideal lot size = riskAmount / riskPerStandardLot
   double idealLot = riskAmount / riskPerStandardLot;

   // Round down to nearest lot step
   double lots = MathFloor(idealLot / lotStep) * lotStep;

   // Clamp to min/max
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);

   // Normalize to lot step
   lots = NormalizeDouble(lots, 2);

   Print("Position Sizing: Equity=", DoubleToString(equity, 2),
         ", Risk=", DoubleToString(riskAmount, 2),
         ", SL pips=", DoubleToString(slInPips, 1),
         ", Lots=", DoubleToString(lots, 2));

   return(lots);
}

//+------------------------------------------------------------------+
//| Manage existing positions - trailing stop logic                  |
//| 1. Move SL to break-even when profit >= 1.0 * ATR               |
//| 2. After break-even, trail SL by 1.5 * ATR from current price   |
//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      // Only manage our own orders
      if(OrderMagicNumber() != MagicNumber)
         continue;

      // Only manage orders for this chart symbol
      if(OrderSymbol() != Symbol())
         continue;

      // Only manage open positions (not pending orders)
      if(OrderType() != OP_BUY && OrderType() != OP_SELL)
         continue;

      // Get current ATR value for trailing calculation
      double atrValue = GetATR();
      if(atrValue <= 0)
         continue;

      double currentSL = OrderStopLoss();
      double openPrice = OrderOpenPrice();
      double tpPrice = OrderTakeProfit();
      double atrDistance = SLMultiplier * atrValue; // 1.5 * ATR
      double beThreshold = atrValue;                // 1.0 * ATR for break-even trigger

      if(OrderType() == OP_BUY)
      {
         double profitPrice = Bid - openPrice;

         // Only proceed if profit >= 1.0 * ATR
         if(profitPrice < beThreshold)
            continue;

         // Step 1: Move SL to break-even if not already there
         if(currentSL < openPrice)
         {
            double beSL = NormalizeDouble(openPrice, Digits);
            if(OrderModify(OrderTicket(), openPrice, beSL, tpPrice, 0, clrNavy))
            {
               Print("BUY #", OrderTicket(), " moved to break-even at ", DoubleToString(beSL, Digits));
            }
            else
            {
               Print("ERROR: BUY #", OrderTicket(), " break-even modify failed: ", GetLastError());
            }
         }
         else
         {
            // Step 2: Trail by 1.5 * ATR from current price (only move forward)
            double trailSL = NormalizeDouble(Bid - atrDistance, Digits);

            if(trailSL > currentSL && trailSL > openPrice)
            {
               if(OrderModify(OrderTicket(), openPrice, trailSL, tpPrice, 0, clrNavy))
               {
                  Print("BUY #", OrderTicket(), " trailing SL updated to ", DoubleToString(trailSL, Digits));
               }
               else
               {
                  Print("ERROR: BUY #", OrderTicket(), " trailing SL modify failed: ", GetLastError());
               }
            }
         }
      }
      else if(OrderType() == OP_SELL)
      {
         double profitPrice = openPrice - Ask;

         // Only proceed if profit >= 1.0 * ATR
         if(profitPrice < beThreshold)
            continue;

         // Step 1: Move SL to break-even if not already there
         if(currentSL > openPrice)
         {
            double beSL = NormalizeDouble(openPrice, Digits);
            if(OrderModify(OrderTicket(), openPrice, beSL, tpPrice, 0, clrCrimson))
            {
               Print("SELL #", OrderTicket(), " moved to break-even at ", DoubleToString(beSL, Digits));
            }
            else
            {
               Print("ERROR: SELL #", OrderTicket(), " break-even modify failed: ", GetLastError());
            }
         }
         else
         {
            // Step 2: Trail by 1.5 * ATR from current price (only move forward)
            double trailSL = NormalizeDouble(Ask + atrDistance, Digits);

            if(trailSL < currentSL && trailSL < openPrice)
            {
               if(OrderModify(OrderTicket(), openPrice, trailSL, tpPrice, 0, clrCrimson))
               {
                  Print("SELL #", OrderTicket(), " trailing SL updated to ", DoubleToString(trailSL, Digits));
               }
               else
               {
                  Print("ERROR: SELL #", OrderTicket(), " trailing SL modify failed: ", GetLastError());
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
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() == MagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Count positions for a specific symbol owned by this EA           |
//+------------------------------------------------------------------+
int CountPositionsBySymbol(string symbol)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() == MagicNumber && OrderSymbol() == symbol)
         count++;
   }
   return count;
}
//+------------------------------------------------------------------+