# NFPM Raw Data Quality Check

Dataset inspected: `/home/gharbi/Defind/data/uniswap/nfpm`

Inspection date: 2026-04-06

Coverage currently indexed:

- contract: `0xc36442b4a4522e871399cd717abdd847ab11fe88` (Uniswap V3 NFPM)
- block range: `12,369,651` to `12,969,699`
- events:
  - `Approval`
  - `ApprovalForAll`
  - `Collect`
  - `DecreaseLiquidity`
  - `IncreaseLiquidity`
  - `Transfer`

## Summary

The raw event decoding looks healthy on this first indexed slice.

Main result:

- no malformed tx hashes
- no nulls on required event fields
- no duplicate `(tx_hash, log_index)` within any event table
- no out-of-range blocks relative to the requested coverage
- all numeric event payloads are decimal strings, not broken hex fragments
- all decoded numeric payloads fit their expected unsigned integer bounds
- address fields are well-formed

The only non-issue that surfaced is formatting:

- `contract` is stored in checksum-case form, not lower-case
- case-insensitive comparison confirms it always matches the expected NFPM contract

## Event Row Counts

| Event | Rows |
|---|---:|
| `Approval` | 5,389 |
| `ApprovalForAll` | 312 |
| `Collect` | 115,165 |
| `DecreaseLiquidity` | 84,618 |
| `IncreaseLiquidity` | 136,323 |
| `Transfer` | 110,050 |

## Common Checks

Applied to every event dataset:

- `tx_hash` format = valid `0x...` 32-byte hash
- `log_index` non-null
- `contract` constant and equal to NFPM address, case-insensitive
- `event` column matches the directory name
- `(tx_hash, log_index)` unique within each event
- `block_number` stays inside the requested coverage

Result:

- all passed

## Event-Specific Checks

### `Approval`

- `approved` and `owner` are valid addresses
- `tokenId` is always a decimal string
- `tokenId` range: `10` to `105371`
- `approved = zero address` appears often and looks like standard approval reset behavior

### `ApprovalForAll`

- `operator` and `owner` are valid addresses
- `approved` decodes as real boolean values
- observed values:
  - `True`: 311
  - `False`: 1

### `Collect`

- `recipient` is always a valid address
- `amount0`, `amount1`, `tokenId` are always decimal strings
- `amount0` and `amount1` always fit in `uint256`
- `tokenId` range: `3` to `105361`
- some rows have zero amounts:
  - both zero: 330
  - only `amount0 = 0`: 5,073
  - only `amount1 = 0`: 6,148

These do not look like decode failures by themselves. For NFPM, zero-fee collects and one-sided fee accrual are plausible.

### `DecreaseLiquidity`

- `amount0`, `amount1`, `liquidity`, `tokenId` are always decimal strings
- `liquidity` always fits in `uint128`
- `tokenId` range: `3` to `105361`
- zero-liquidity rows: 0
- one-sided decreases exist and look plausible:
  - both amounts zero: 8
  - only `amount0 = 0`: 19,502
  - only `amount1 = 0`: 23,392

### `IncreaseLiquidity`

- `amount0`, `amount1`, `liquidity`, `tokenId` are always decimal strings
- `liquidity` always fits in `uint128`
- `tokenId` range: `1` to `105390`
- zero-liquidity rows: 0
- one-sided increases exist and look plausible:
  - both amounts zero: 0
  - only `amount0 = 0`: 9,347
  - only `amount1 = 0`: 10,144

### `Transfer`

- `from` and `to` are always valid addresses
- `tokenId` is always a decimal string
- `tokenId` range: `1` to `105390`
- mint-like transfers (`from = zero address`): 105,390
- burn-like transfers (`to = zero address`): 2,860
- self-transfers (`from = to`): 11

The self-transfers are unusual but not automatically a decode issue. They should be reviewed later in business logic if needed.

## Conclusion

For this first NFPM indexed slice, the raw event decoding looks good enough to continue.

There is no immediate evidence of:

- broken topic decoding
- broken data-word decoding
- malformed addresses
- malformed uint fields
- duplicated events from chunk overlap
- coverage leakage outside the requested range

## Follow-Up Checks Worth Doing Later

- cross-check `Transfer` mint counts against distinct `tokenId` creation
- inspect the 11 self-transfers to confirm they are legitimate contract behavior
- cross-link `IncreaseLiquidity` / `DecreaseLiquidity` / `Collect` by `tokenId`
- add a reusable notebook or script for the same checks on future NFPM backfills
