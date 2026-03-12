# Grant Witness PoC — Claude Context

## Project Purpose

R data pipeline that cross-references federal grant termination data with USAspending.gov to surface discrepancies. Built as a job-application PoC targeting a Data Scientist role at [Grant Witness](https://grant-witness.us/).

## Pipeline

```
notices_nih ──┐
               ├─ validated_notices ─┐
notices_nsf ──┘                      │
                                     ├─ discrepancies ─┬─ discrepancy_summary
usaspending_awards ─ validated_awards ┘                 ├─ plot_files
                                                        └─ export_parquet
```

Run with: `targets::tar_make()`

## Key Numbers (latest run)

| Metric | Value |
|---|---|
| NIH terminated grants | 9,063 (deduplicated) |
| NSF terminated awards | 1,667 |
| USAspending awards | 15,000 (HHS + NSF + EPA) |
| Exact matches | 489 |
| Fuzzy matches | 2,498 |
| Active Despite Terminated | 693 |
| Possible Freeze (<10% outlay) | 4,957 |
| Untracked | 11,310 |

## R Modules (R/ directory, ~1,619 lines total)

| File | Lines | Purpose |
|---|---|---|
| utils.R | 89 | `build_request()`, `parse_date_flexible()`, `log_event()` |
| validate.R | 163 | `validate_notices()`, `validate_awards()` — assertr schemas |
| scrape_nih.R | 199 | NIH Reporter API v2 paginated scraper |
| scrape_nsf.R | 205 | NSF Terminated Awards CSV parser |
| fetch_usaspending.R | 242 | USAspending.gov award fetcher |
| transform.R | 418 | Exact/fuzzy join, discrepancy flags, `elapsed_ratio` |
| visualize.R | 303 | 5 ggplot2 charts (GW visual style) |

## Critical API Constraints

- **NIH Reporter**: Hard offset cap at 14,999. Use `req_body_json()` not `req_body_raw(toJSON(...))` (fails in callr).
- **USAspending**: Hard page cap at 100. Date fields are `"Start Date"` / `"End Date"` (NOT "Period of Performance...").
- **NSF CSV**: Latin-1 encoding — must `iconv()` before parsing.

## Known Bug Classes (all have regression tests)

1. NIH offset > 14,999 → 400 error
2. USAspending limit > 100 → 422 error
3. `req_body_raw(toJSON(...))` fails in targets callr subprocess
4. NSF Latin-1 encoding crash
5. `NA_Date_` doesn't exist in R — use `as.Date(NA)`
6. Undeclared `mapproj` dependency for `coord_map()`
7. Column collision in joins — `.rename_shared_cols()` pre-renames with `_notice` suffix
8. NIH pagination boundary duplicates (13.6%) — `distinct(grant_number)`
9. USAspending wrong date field names (100% null)
10. Fuzzy join false positives — JW threshold 0.08 + distinctive-token filter

## Fuzzy Join Design

Two-layer approach (handles NIH→USAspending, no shared key exists):
1. Jaro-Winkler distance threshold ≤ 0.08 (tightened from 0.15 which had 71% FP rate)
2. `share_distinctive_token()` filter — requires shared non-stopword tokens

NSF exact matching works because NSF uses same 7-digit award ID in both systems.

## Tests

`tests/testthat/test-parsers.R` — 1,376 lines covering all 7 modules + regression guards for the 10 bug classes above.

## Next Priorities (from TRACKER.md)

**HIGH**
- Cross-agency institution analysis (`group_by(org_name)` across NIH + NSF)
- Add DOE/USDA/ED to `fetch_usaspending.R` (trivial parameter change)
- Transaction-level scraper (`/api/v2/transactions/`) — needed for Plan A freeze heuristic

**MEDIUM**
- PostgreSQL export (DBI + RPostgres already scoped)
- Discrepancy UI (Shiny/Quarto surfacing `flag_amount_mismatch`)

## Output

- `output/discrepancies.parquet` — full joined dataset
- `output/*.png` — 5 plots (institute bars, discrepancy summary, outlay scatter, freeze severity, state map)
