# BreakoutStopBot

MT5 Expert Advisor implementing a 1-minute candle breakout system: on every new
M1 bar, it places a Buy Stop above and a Sell Stop below the just-closed
candle's high/low (OCO pair), manages take-profit/stop-loss, moves losing-risk
to breakeven once a position is far enough in profit, and closes any position
still in floating loss at the next candle close.

## Requirements

- **Hedging account.** Each filled stop order becomes its own position with
  its own SL/TP. This EA has not been validated on netting accounts (only one
  net position per symbol) and will log a warning on `OnInit` if the account
  isn't in `ACCOUNT_MARGIN_MODE_RETAIL_HEDGING`.
- Run on an **M1 chart**. The EA reads M1 candle data internally regardless of
  chart timeframe, but relies on `iTime(..., PERIOD_M1, 0)` changing to detect
  new bars — run it on M1 so tick delivery lines up as expected.

## Logic

Every tick:
1. **OCO enforcement** — if one pending stop order of the current pair filled
   or disappeared while the other is still pending, the sibling is cancelled.
2. **Breakeven check** — for each open position, if floating profit has
   reached `InpBreakevenTriggerPips`, the stop loss moves to
   `entry ± (current spread + InpBreakevenBufferPips)` pips, locking in a
   small guaranteed profit. This check recomputes from position state every
   time (no separate "already armed" flag), so it's safe across EA restarts.

On every new M1 bar (once, at the bar's first tick):
1. **Drawdown close** — any open position (from this EA) currently in
   floating loss is closed at market immediately, rather than waiting for the
   fixed stop loss.
2. **Stale order cleanup** — the previous bar's Buy Stop / Sell Stop are
   cancelled if they never filled.
3. **New OCO pair** — if spread and session filters pass and the EA is below
   `InpMaxConcurrentPositions`, a fresh Buy Stop is placed at
   `previous candle high + InpEntryBufferPips` and a fresh Sell Stop at
   `previous candle low − InpEntryBufferPips`, each with its own
   `InpTakeProfitPips` / `InpStopLossPips`.

## Inputs

| Input | Default | Description |
|---|---|---|
| `InpTakeProfitPips` | 100 | Take profit distance from entry, in pips |
| `InpStopLossPips` | 50 | Stop loss distance from entry, in pips |
| `InpBreakevenTriggerPips` | 20 | Floating profit needed before breakeven arms |
| `InpBreakevenBufferPips` | 0.25 | Extra pips locked in beyond spread at breakeven |
| `InpEntryBufferPips` | 0 | Offset added beyond the prior candle's high/low |
| `InpPendingExpiryMinutes` | 0 | Pending order expiry; 0 = GTC (orders are replaced every bar regardless) |
| `InpUseRiskPercent` | false | Use risk-percent position sizing instead of a fixed lot |
| `InpRiskPercent` | 1.0 | Risk per trade, % of account balance (if `InpUseRiskPercent`) |
| `InpLotSize` | 0.01 | Fixed lot size (if not using risk-percent sizing) |
| `InpMaxConcurrentPositions` | 3 | Cap on simultaneously open positions from this EA |
| `InpMaxSpreadPips` | 3.0 | Skip placing new stops this bar if spread exceeds this |
| `InpUseSessionFilter` | false | Restrict new stop placement to a server-time window |
| `InpTradingStartHour` / `InpTradingEndHour` | 0 / 24 | Session window (server time, hour granularity) |
| `InpSlippagePips` | 2 | Max slippage allowed for market operations (e.g. drawdown close) |
| `InpMagicNumber` | 20260904 | Identifies this EA's orders/positions |
| `InpCancelPendingOnRemove` | true | Cancel this EA's pending stop orders when it's removed from the chart |

## Install

1. Copy `MQL5/Experts/BreakoutStopBot.mq5` and the
   `MQL5/Include/BreakoutStopBot/` folder into your terminal's `MQL5/Experts`
   and `MQL5/Include` directories (Data Folder → `MQL5/`).
2. Compile `BreakoutStopBot.mq5` in MetaEditor.
3. Attach to an M1 chart, enable AutoTrading, set inputs.

## Known limitations / risks

- **Weekend / news gap risk**: resting stop orders through low-liquidity
  periods can fill with large slippage. Consider adding a news-avoidance or
  Friday-close-avoidance guard if you trade through those windows —
  not currently implemented.
- **Netting accounts**: not supported — multiple simultaneous positions with
  independent SL/TP require a hedging account.
- **Broker stop/freeze levels**: pending order and SL/TP prices are clamped to
  the symbol's minimum stop distance (`SYMBOL_TRADE_STOPS_LEVEL`), which can
  shift the actual entry away from the exact candle high/low on some
  brokers/symbols when the market is very close to those levels.
- **High-frequency stop placement**: a breakout system re-arming every minute
  is very sensitive to spread and slippage costs; backtest with realistic
  spread/commission modeling before running live.
