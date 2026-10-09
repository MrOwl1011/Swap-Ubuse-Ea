# Known limitations and risks

## Strategy risk

- **Positive swap is not profit.** On gold, one weekend's credit on 1 lot is typically tens of dollars, while a 95th-percentile weekend gap is often thousands of points (on a 2-digit XAUUSD, 1,000 points is $10 a troy ounce, about $1,000 per lot). The dashboard's "edge covers N pts" next to the median gap shows how small the edge is relative to normal price movement. Expect the outcome of individual trades to be dominated by price.
- **Stops do not protect against gaps.** If Monday opens beyond your stop, the fill is at or past the opening price. The sizing never treats a stop as reducing gap risk.
- **Swap rates change.** Brokers update swaps, sometimes weekly and sometimes on Friday itself. The EA re-reads them on every scan and closes positions whose swap turns negative, but a change booked at the rollover itself cannot be anticipated.
- **Broker-specific rollover handling.** The EA uses the broker's per-day ratios when published and the classic MT5 model otherwise. Brokers that book swap at a time other than server midnight must be configured with `RolloverTimeOffsetMinutes`. Swap-free (Islamic) accounts replace swap with fees the EA cannot see.
- **Weekend margin.** Some brokers raise margin requirements over the weekend or close positions before it. The margin check uses current requirements.

## Data and API limitations

- **Commission is not readable from symbol properties.** The EA uses `CommissionPerLotRoundTrip` and, if enabled, commission observed in recent deals. With neither, costs are understated.
- **Holidays and special sessions** are not visible through `SymbolInfoSessionTrade()`, which only returns the regular weekly schedule. On a holiday-shortened Friday the EA's target time may be later than the real close and the window may be missed.
- **Reopen swap modes** (`REOPEN_CURRENT`, `REOPEN_BID`) are approximated as points; the P&L impact shows up in the position price, not in the swap field.
- **`INTEREST_OPEN`** is estimated at the current price.
- **Currency conversion** uses the mid price of a broker forex/CFD symbol at scan time. If no conversion symbol exists, the symbol is rejected.
- **Gap statistics** need about a year of H1 and D1 history for each scanned symbol. Until it loads the symbol is rejected ("gap history unavailable"). Historical gaps do not bound future gaps.
- **Liquidity** is approximated by quote freshness and an optional tick count; MT5 exposes no order-book depth for most CFD/forex symbols.

## Tester limitations

See [BACKTESTING.md](BACKTESTING.md#what-the-mt5-strategy-tester-can-and-cannot-tell-you): current swap rates are applied to all history, the rollover schedule is today's, and Friday/Monday spreads are realistic only with real ticks.

## Operational

- **Compilation was not run in the environment that produced this code** (no MetaEditor available). Compile it in MetaEditor and fix anything a newer or older build objects to before use.
- Positions are managed only while the EA runs in live mode on a connected terminal. If the terminal is off on Monday, the scheduled exit does not happen until it is back. Switching to analysis-only mode with open positions leaves them unmanaged.
- The duplicate-entry guard is stored in terminal global variables. Deleting them, or running a second copy with the same magic number, removes that protection.
- In netting accounts the EA skips symbols that already hold a position opened by something else, rather than netting into it.
