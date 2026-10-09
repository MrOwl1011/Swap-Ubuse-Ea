# Swap Abuse EA

A standalone MetaTrader 5 Expert Advisor that reads the connected broker's swap specifications, projects what a BUY or SELL position would earn or pay over a planned hold (by default the Friday-to-Monday weekend), subtracts spread, commission and other costs, sizes the trade against a historical weekend-gap stress loss, and, only if you enable it, trades the favourable direction.

It does not exploit a broker loophole and it does not guarantee profit. A positive swap is a small, known credit; the price move over the hold, and especially the weekend gap, is a much larger unknown. The EA is built to measure that trade-off honestly and to stay in analysis mode until you decide otherwise.

**Live trading is off by default** (`EnableTrading = false`, `AnalysisOnlyMode = true`).

## Repository layout

```
MQL5/
  Experts/SwapAbuseEA/
    Swap_Abuse_EA.mq5          EA entry point: inputs, event handlers, entry engine, dashboard text
    Include/
      Defines.mqh              enums, config struct, analysis structs, helpers
      SymbolUniverse.mqh       resolves SymbolsToScan (CURRENT, MARKETWATCH, ALL, names, suffixes)
      SwapCalculator.mqh       swap mode interpretation, per-day ratios, currency conversion
      SessionSchedule.mqh      trading sessions, Friday close, rollover instants, hold projection
      CostModel.mqh            spread / commission costs, weekend-gap and daily-range statistics
      RiskManager.mqh          sizing, exposure limits, volume normalisation, margin check
      TrendFilter.mqh          optional EMA trend confirmation
      OpportunityScanner.mqh   per-symbol evaluation, accept/reject reason, ranking
      TradeExecutor.mqh        permissions, order send, result validation, hedging/netting close/reduce
      PositionManager.mqh      HOLD / REDUCE / CLOSE decisions for open positions
      TradeLogger.mqh          journal + CSV logs, per-position statistics for the tester
      Dashboard.mqh            on-chart panel
  Presets/
    SwapAbuseEA_Analysis.set   safe default: scanner and dashboard only
    SwapAbuseEA_Backtest_XAUUSD.set  Friday weekend test on gold with trading enabled
docs/
  ARCHITECTURE.md              how it works and the swap maths
  BACKTESTING.md               test plan, optimisation ranges, recommended initial settings
  LIMITATIONS.md               known limitations and risks
```

## Install

1. In MT5 open **File > Open Data Folder**.
2. Copy the `MQL5/Experts/SwapAbuseEA` folder into `<Data Folder>/MQL5/Experts/` (keep the `Include` sub-folder next to the `.mq5`).
3. Optionally copy `MQL5/Presets/*.set` into `<Data Folder>/MQL5/Presets/`.
4. Open `Swap_Abuse_EA.mq5` in MetaEditor and press **Compile** (F7). It uses only the MQL5 standard library (`Trade\Trade.mqh`).
5. Restart the Navigator (or right-click > Refresh). The EA appears under **Expert Advisors > SwapAbuseEA**.

Compile requirement: a recent MT5 build (2023 or later). The code reads `SYMBOL_SWAP_SUNDAY` ... `SYMBOL_SWAP_SATURDAY` and `SYMBOL_SWAP_MODE_CURRENCY_PROFIT`, which older builds do not have.

## Run (analysis only)

1. Drag the EA onto any chart, for example XAUUSD M15.
2. Leave the defaults. The dashboard shows, for the chart symbol: raw long/short swap, the swap mode and how it was converted, the per-day rollover ratios, the weekend and planned-hold swap per lot, costs per lot, net per lot, the gap stress loss, the schedule (session end, entry window, reopen), and the decision with its reason. Below that is the ranked list of scanned symbols.
3. The Experts journal lists every symbol's verified swap basis at start-up. Compare it with **Market Watch > right-click symbol > Specification** before trusting any number.
4. CSV logs are written to `<Data Folder>/MQL5/Files/SwapAbuseEA_<magic>_*.csv` (decisions, entries/management, deals, summary).

## Enable trading (demo first)

Set `EnableTrading = true` **and** `AnalysisOnlyMode = false`, allow Algo Trading in the terminal and on the EA's Common tab. Before that, set at least:

- `CommissionPerLotRoundTrip` to your broker's real commission (MQL5 cannot read it from the symbol).
- `RolloverTimeOffsetMinutes` if your broker books swap at a time other than server midnight.
- `MaximumWeekendLoss`, `MaximumTotalLots`, `MaximumOpenPositions` to amounts you can lose.

Run it on a demo account for several weekends and reconcile the `deals.csv` swap column against the `entries.csv` expected swap before going near a live account.

## Further reading

- [Architecture and strategy](docs/ARCHITECTURE.md)
- [Backtesting plan and recommended settings](docs/BACKTESTING.md)
- [Known limitations and risks](docs/LIMITATIONS.md)
