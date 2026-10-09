# Architecture and strategy

## Strategy in one paragraph

Brokers often charge one side of an instrument a large swap and credit the other side a smaller one (the example XAUUSD figures: BUY -76.008, SELL +28.488). If you hold the credited side through a rollover you receive the credit, and if the broker books a triple swap on the day you hold through (often Friday for metals and CFDs, often Wednesday for forex), you receive three times the credit for one night. The EA estimates that credit precisely from broker data, subtracts what it costs to get in and out, and compares the remainder with what the market can take from you while you hold, which for a weekend hold is mostly the Monday gap. It only trades when the net credit clears your minimum and the stress loss stays inside your limit.

## Data flow per scan

```
SymbolUniverse ──> for each symbol ──> OpportunityScanner.Analyze()
                                         ├─ SwapCalculator.Read()        broker swap spec -> deposit ccy per lot per rollover
                                         ├─ SessionSchedule              session end, reopen, entry window, rollovers in hold
                                         ├─ CostModel                    spread + commission, gap/range stress move
                                         ├─ RiskManager.PlannedLots()    fixed or % risk, capped by limits
                                         └─ filters -> qualifies / entryReady + reason
                                       ranked list
Entry engine (main EA) ─> TradeExecutor.Open()  (live mode only, ready symbols in rank order)
PositionManager.Manage() ─> HOLD / REDUCE / CLOSE (live mode only)
TradeLogger  ─> journal, CSV, OnTester statistics
Dashboard    ─> on-chart panel
```

The EA runs on a timer (`TimerSeconds`, default 5 s) and on ticks. A full scan runs every `ScanIntervalSeconds` (default 60 s), and every timer cycle while any symbol is within its preparation window.

## Swap maths (SwapCalculator.mqh)

All MQL5 properties used here were checked against the official MQL5 reference (Market Info constants):

| Property | Use |
|---|---|
| `SYMBOL_SWAP_LONG`, `SYMBOL_SWAP_SHORT` | raw broker values |
| `SYMBOL_SWAP_MODE` | how the raw value is denominated |
| `SYMBOL_SWAP_ROLLOVER3DAYS` | day of the triple swap |
| `SYMBOL_SWAP_SUNDAY` ... `SYMBOL_SWAP_SATURDAY` | per-day multiplier (0, 1 or 3) for the rollover from that day to the next |
| `SYMBOL_TRADE_TICK_VALUE`, `SYMBOL_TRADE_TICK_SIZE`, `SYMBOL_POINT` | value of one point for 1 lot in deposit currency |

Every mode is turned into **deposit currency per 1.0 lot per single rollover**:

| `SYMBOL_SWAP_MODE` | Conversion |
|---|---|
| `DISABLED` | 0 |
| `POINTS` | swap x point value (tick value x point / tick size) |
| `CURRENCY_SYMBOL` | swap in base currency, converted to deposit currency |
| `CURRENCY_MARGIN` | swap in margin currency, converted |
| `CURRENCY_PROFIT` | swap in profit currency, converted |
| `CURRENCY_DEPOSIT` | swap as is |
| `INTEREST_CURRENT`, `INTEREST_OPEN` | notional x rate / 100 / 360 (MT5 uses a 360-day bank year); notional = price / tick size x tick value; `OPEN` is estimated at the current price |
| `REOPEN_CURRENT`, `REOPEN_BID` | modelled as points x point value and flagged as an approximation, because the broker books it in the reopen price rather than the swap field |

Currency conversion uses a forex or CFD symbol the broker offers (`CCY/DEP` or `DEP/CCY`, or one hop through USD). If no path exists the symbol is marked **UNVERIFIED** and never traded.

**Rollover multiplier.** The EA never assumes that a displayed swap figure is per lot per weekend. It counts the rollover instants (server midnight + `RolloverTimeOffsetMinutes`) that fall inside the projected hold and adds the broker's per-day ratio for each, where the ratio used is the one for the day being rolled *from* (`SYMBOL_SWAP_FRIDAY` = the Friday-to-Saturday rollover). If the broker publishes no per-day ratios, the classic MT5 model is used (1 per weekday, 3 on `SYMBOL_SWAP_ROLLOVER3DAYS`, 0 for Saturday and Sunday) and the dashboard marks it "derived".

Consequence worth knowing: on a broker that books the triple swap on Wednesday, a Friday-to-Monday hold earns **one** swap, not three. The EA shows this rather than assuming the weekend is special.

## Schedule (SessionSchedule.mqh)

- Sessions come from `SymbolInfoSessionTrade()` in broker server time. Back-to-back sessions (24:00 to 00:00, or gaps under 60 s) are chained, so "session end" is the real close of the contiguous trading period.
- **Target time** is the earlier of the session end and the next rollover instant: the moment the position must already be open.
- **Friday mode** applies when server time is Friday and the period after the session end is closed for at least 20 hours (a weekend).
- **Weekday mode** (`EnableMidweekRollover`, optionally only before triple-swap days) applies to ordinary nights.
- Window states: `WAITING` (more than `FridayPreparationMinutes` to target), `ENTRY WINDOW` (between preparation and cutoff), `CUTOFF` (less than `FridayEntryCutoffMinutes` left: no new entries), `MARKET CLOSED`, `UNVERIFIED` (no schedule).
- **Hold projection.** Scheduled exit = first tradable moment after the `HoldRollovers`-th rollover, plus `ExitDelayMinutes`. For a Friday entry, `HoldRollovers` of 1, 2 or 3 all exit Monday after the reopen and include the Fri, Sat and Sun ratios.

## Costs and stress (CostModel.mqh)

- **Spread cost per lot** = (entry spread + entry spread x `ExitSpreadMultiplier`) / 2 x point value: half the spread on each side, with a wider assumed exit spread because Monday reopen spreads are usually wide.
- **Commission** = max(`CommissionPerLotRoundTrip`, commission observed on this symbol in the last 90 days of account deals x 2). MQL5 has no symbol property for commission, so the input matters.
- **Stress move**: from H1 history, every bar-to-bar jump of 36 hours or more is a weekend/holiday gap; the `GapPercentile` (default 95th) of |Monday open - Friday close| over `GapLookbackWeeks`, times `GapRiskMultiplier`. Weekday mode uses the same percentile of D1 high-low ranges. A floor of `MinStressPercentOfPrice` applies. If history is insufficient, the symbol is rejected rather than guessed.
- **Stress loss** = (stress move x point value + costs per lot) x lots. Swap is excluded on purpose (conservative).
- **Break-even move** = net swap per lot / point value: how many points against you wipe out the edge. The dashboard shows it next to the median weekend gap.

## Decision rules (OpportunityScanner.mqh)

A symbol **qualifies** when, in order: swap data verified, swaps enabled, at least one rollover in the hold, the favoured direction earns positive swap, (optionally) the opposite direction is charged, the symbol's trade mode allows that direction, net swap per lot is positive after costs, gap history is available, a lot size survives all caps, net advantage at that size is at least `MinimumNetSwapAdvantage`, and stress loss is within `MaximumWeekendLoss`.

It becomes **entry-ready** when additionally: it is a configured entry day, the window is open, spread is within `MaximumSpread` (or the per-symbol override), the quote is fresh, the liquidity proxy passes, the trend filter (if on) agrees, and margin fits `MaxMarginUsePercent` of free margin.

The first failing rule is the reason shown on the dashboard and logged.

## Sizing and limits (RiskManager.mqh)

- Fixed lots, or `RiskPercent` of equity divided by risk per lot, where risk per lot = max(stress move, stop distance) x point value + costs. A stop does not cap a gap, so it never makes the risk smaller than the stress move.
- Caps, applied in order: `MaximumWeekendLoss`, remaining room under `MaximumTotalLots`, `SYMBOL_VOLUME_LIMIT`. Volume is floored to `SYMBOL_VOLUME_STEP` and rejected below `SYMBOL_VOLUME_MIN`.
- `MaximumOpenPositions` counts all EA positions.

## Execution (TradeExecutor.mqh, main EA)

- Checks terminal AutoTrading, the EA's algo-trading permission, `ACCOUNT_TRADE_ALLOWED` and `ACCOUNT_TRADE_EXPERT` before any order.
- Filling mode from the symbol, deviation = `MaximumSlippage`, stops adjusted to `SYMBOL_TRADE_STOPS_LEVEL`.
- Success only on `TRADE_RETCODE_DONE`, `DONE_PARTIAL` or `PLACED`; anything else is logged as a failure with the retcode.
- **Duplicates:** one EA position per symbol, never added to; a terminal global variable records the target time of the last entry per symbol so a restart cannot re-enter the same window; at most 3 attempts, 60 s apart, per window.
- **Netting accounts:** the EA will not trade a symbol that already has a position from another source, reduces with an opposite deal, and closes by ticket. **Hedging accounts:** reduces with a partial close.

## Position management (PositionManager.mqh)

For each EA position, in order:

1. Market closed: hold.
2. Held direction now pays swap and `CloseIfSwapTurnsNegative`: close.
3. Exit due (`ExitMode = after rollovers`): close when spread is back within limit, or anyway after `ExitMaxWaitMinutes`.
4. `ReduceToLimits`: reduce if total EA lots exceed `MaximumTotalLots`, or if before the weekend the position's stress loss exceeds `MaximumWeekendLoss`.
5. Otherwise hold, with the swap being collected and rollovers passed logged.

Position management runs only in live mode; in analysis mode the EA sends no orders at all.
