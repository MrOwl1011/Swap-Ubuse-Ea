# Backtesting plan

No backtest has been run for this repository. Nothing below is a result; it is the procedure for producing results you can trust.

## What the MT5 Strategy Tester can and cannot tell you

- **Historical swap rates are not available.** The tester applies the symbol's *current* swap settings (`SYMBOL_SWAP_LONG/SHORT`, mode, per-day ratios) to the whole test period. A 2-year test of a gold short with today's +28.488 assumes that rate held for two years. Interest-rate cycles mean it almost certainly did not. Treat swap income in any test as "what today's rates would have paid".
- **Rollover schedule** in the tester follows the current triple-swap day and per-day ratios, not the historical ones, and does not model broker holiday changes.
- **Weekend gaps are real** in the price history (Friday close to Monday open), so gap losses are represented, but only at the granularity of your tick data. Use "Every tick based on real ticks" where the broker provides them.
- **Spread at the Friday close and Monday open** is only realistic with real ticks. With generated ticks the tester uses a fixed or bar spread, which understates exactly the costs this strategy is most sensitive to.
- **Execution:** the tester fills at the requested price plus the configured delay; it does not reproduce requotes, Friday liquidity, broker-side stop handling during gaps, or margin increases some brokers apply over weekends.
- **Commission** is applied only if the tester's symbol/account settings include it; otherwise set `CommissionPerLotRoundTrip`, which is used for the decision but not charged by the tester.

## Setup

1. Strategy Tester (Ctrl+R) > Expert: `SwapAbuseEA\Swap_Abuse_EA`.
2. Symbol: the one under test (e.g. XAUUSD). Timeframe: M15 or M5 (the EA works on time, not bars).
3. Modelling: **Every tick based on real ticks**. Deposit and leverage: match the account you would trade.
4. Inputs: load `MQL5/Presets/SwapAbuseEA_Backtest_XAUUSD.set`, which sets `EnableTrading = true`, `AnalysisOnlyMode = false`, `SymbolsToScan = CURRENT` and `ShowDashboard = false`.
5. Period: at least 12 months (about 50 weekends), and preferably 24 to 36 months so that gap statistics include stressed weekends.
6. Run once in visual mode on a few weeks to confirm on the dashboard that the entry window, target time and exit time match your broker's Friday close and Monday open.

Test one symbol per run with `SymbolsToScan = CURRENT`. Multi-symbol tests work but slow down history loading and mix results.

## Reading the output

- The **Journal** has one `SUMMARY` line per run: trades, net profit, profit factor, win rate, maximum consecutive losses, drawdown, price P/L, swap net / income / paid, commission, fees, and estimated spread cost.
- `SwapAbuseEA_<magic>_summary.csv` holds the same row (per optimisation pass, in each agent's `Files` folder).
- `deals.csv` and `entries.csv` let you compare, per position, expected swap and cost with what was booked.
- The question to answer is: **is swap income larger than price P/L variance plus costs?** If net profit is driven by price P/L rather than swap, the result is directional luck, not the swap edge.

## Experiments

| # | Question | Vary | Keep |
|---|---|---|---|
| 1 | Does the weekend swap on gold cover its costs at all? | nothing (fixed 0.01 lot) | defaults |
| 2 | Entry time sensitivity | `FridayPreparationMinutes` 15 to 240 step 15, `FridayEntryCutoffMinutes` 2 to 30 step 2 | lot |
| 3 | Holding period | `HoldRollovers` 1 to 5; `ExitDelayMinutes` 0 to 240 step 15 | entry time |
| 4 | Does a trend filter reduce gap losses? | `UseTrendFilter` on/off, `TrendTimeframe` H1/H4/D1, fast 10 to 50, slow 50 to 200 | timing |
| 5 | Risk controls | `MaximumWeekendLoss`, `GapPercentile` 80 to 99, `GapRiskMultiplier` 1 to 2, `UseStopLoss` with 1000 to 5000 points | timing |
| 6 | Lot size / sizing mode | `FixedLotSize` 0.01 to 0.5, or `UseRiskBasedSizing` with `RiskPercent` 0.25 to 2 | best of 2 to 5 |
| 7 | Other symbols | repeat 1 to 3 for each forex pair and index whose swap is asymmetric on your broker | |
| 8 | Weekday triple-swap | `EnableFridayStrategy = false`, `EnableMidweekRollover = true`, `MidweekTripleSwapOnly = true` | |

For optimisation use `OptimizationCriterion = Net profit / max drawdown` (the default), then confirm the chosen settings with a forward period the optimiser did not see (Strategy Tester > Forward: 1/3). Discard settings that only work in-sample or that depend on a handful of trades: a weekend strategy produces at most ~50 trades a year per symbol, so small samples are the norm and over-fitting is easy.

## Recommended initial settings

These are starting points for a demo account, not optimised values:

| Input | Value | Why |
|---|---|---|
| `EnableTrading` / `AnalysisOnlyMode` | false / true until reconciled | observe several weekends first |
| `FixedLotSize` | 0.01 | smallest risk while validating |
| `MinimumNetSwapAdvantage` | 1.0 (or more) | ignore marginal edges |
| `FridayPreparationMinutes` / `FridayEntryCutoffMinutes` | 60 / 10 | avoid the last minutes when spreads blow out |
| `HoldRollovers` / `ExitDelayMinutes` | 1 / 15 | exit Monday once the reopen spread settles |
| `ExitSpreadMultiplier` | 2.0 | Monday spreads are wide |
| `MaximumWeekendLoss` | an amount you accept losing in one weekend | it caps size against the 95th-percentile gap |
| `MaximumTotalLots` / `MaximumOpenPositions` | 0.10 / 3 | |
| `GapPercentile` / `GapRiskMultiplier` | 95 / 1.0 | |
| `UseStopLoss` | false at first | stops do not protect gaps and add intra-Friday stop-outs; test it in experiment 5 |
| `CommissionPerLotRoundTrip` | your broker's value | required for honest net figures |
