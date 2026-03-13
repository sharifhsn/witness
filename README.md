# Grant Witness PoC

**693 federal grants show active spending despite termination notices.**

This pipeline cross-references NIH and NSF grant termination data against official USAspending.gov records to find grants where government reporting contradicts observed termination activity. Built as a proof-of-concept extension of [Grant Witness](https://grant-witness.us/).

**[Live Dashboard](https://sharifhsn.github.io/witness/)**

## What This Discovers

| Discrepancy | What It Means | Count |
|---|---|---|
| **Active Despite Terminated** | USAspending shows live outlays on a grant that termination notices say is dead | 693 |
| **Possible Freeze** | Award period is open but disbursements are absent or near-zero (<10% outlay ratio) | 4,957 |
| **Untracked** | Official awards from tracked agencies with no corresponding forensic notice | 11,310 |

The `possible_freeze` category is further triaged by **elapsed time** and **transaction-level data**: 489 grants are >50% through their award period with <10% outlay, and 142 are >80% elapsed. Transaction-level analysis assigns freeze confidence (high/medium/low) based on the actual last disbursement date.

## Methodology

```
NIH Reporter API ──┐                                  ┌── Discrepancy Flags
                    ├── Validate ──┐                   ├── Transaction-Level Freeze Analysis
NSF Terminated CSV ─┘              ├── Join & Flag ────┤── Visualizations
                                   │                   └── Parquet + DB Export
USAspending.gov API ── Validate ───┘
```

**Fuzzy join precision tuning** — NIH grant numbers don't match USAspending Award IDs, so matching requires organization name similarity. Initial Jaro-Winkler matching at threshold 0.15 produced a 71% false positive rate ("University of Chicago" matched "University of Utah"). Tightened to 0.08 and added a distinctive-token filter requiring shared non-stopword tokens. Result: 2,498 fuzzy matches with high precision.

**10 automated quality flags** catch data anomalies across both datasets: negative outlays (accounting adjustments), over-disbursement (>150% of award), inverted dates, zero awards, future dates, CFDA mismatches, international grants, invalid states, malformed grant numbers, and amount discrepancies between sources.

**Transaction-level freeze confirmation** — For grants flagged as possible freezes, the pipeline fetches individual transaction records from USAspending to determine when the last actual disbursement occurred. Grants with >180 days since last transaction are classified as high-confidence freezes.

## Key Results

| Metric | Value |
|---|---|
| NIH terminated grants scraped | 9,063 (deduplicated) |
| NSF terminated awards parsed | 1,667 |
| USAspending awards fetched | 15,000 (HHS + NSF + EPA) |
| Exact matches (grant number) | 489 |
| Fuzzy matches (org name + date) | 2,498 |
| Active Despite Terminated | 693 |
| Possible Freeze (<10% outlay) | 4,957 |
| Untracked (no forensic notice) | 11,310 |

## Novel Contributions

| Capability | Grant Witness | This PoC |
|---|---|---|
| NIH institute-level breakdown | Agency-level only | Per-IC granularity (NIGMS, NIAID, etc.) |
| Obligation vs. outlay analysis | Not available | Detects "frozen in practice" silent stoppages |
| Transaction-level freeze detection | Not available | Confirms freeze with actual disbursement timeline |
| Active-despite-terminated | Not available | Direct contradiction detection |
| Cross-agency comparison | Separate pages | Unified join across NIH + NSF + EPA |
| Geographic distribution | State-level maps | State-level choropleth from NIH Reporter |

## Visualizations

| | |
|---|---|
| ![Institute Bar Chart](output/institute_bars.png) | ![Discrepancy Summary](output/discrepancy_summary.png) |
| ![Outlay Scatter](output/outlay_scatter.png) | ![Freeze Severity](output/freeze_severity.png) |

![State Map](output/state_map.png)

## Production Readiness

- **Weekly automated runs** via GitHub Actions (Monday 06:00 UTC)
- **PostgreSQL-ready** — set `DATABASE_URL` env var to enable export
- **Airtable-compatible schema** — designed for integration with existing Grant Witness Airtable bases
- **Reproducible** — `renv.lock` pins all R dependencies; `{targets}` caches intermediate results

## Running the Pipeline

```r
renv::restore()        # Install dependencies
targets::tar_make()    # Run the full pipeline
```

<details>
<summary>Technical Details</summary>

### Pipeline DAG

```
notices_nih ─────┐
                 ├─ validated_notices ─┐
notices_nsf ─────┘                     │
                                       ├─ discrepancies ─┬─ transaction_data
usaspending_awards ─ validated_awards ─┘                 ├─ discrepancies_enriched
                                                         ├─ discrepancy_summary
                                                         ├─ plot_files
                                                         └─ export_parquet
```

### Data Sources

- [NIH Reporter API](https://api.reporter.nih.gov/) — terminated grant projects (offset cap: 14,999)
- [NSF Terminated Awards CSV](https://nsf-gov-resources.nsf.gov/files/NSF-Terminated-Awards.csv) — Latin-1 encoded
- [USAspending.gov API](https://api.usaspending.gov/) — award records (page cap: 100) and transaction search

### Tech Stack

- **R** with [{targets}](https://docs.ropensci.org/targets/) for reproducible pipeline orchestration
- **httr2** for polite API access (rate limiting, retries, exponential backoff)
- **fuzzyjoin** for Jaro-Winkler string-distance matching
- **assertr** for runtime data validation
- **ggplot2** with viridis palette matching Grant Witness visual style

### Project Structure

```
R/
  scrape_nih.R          # NIH Reporter API scraper
  scrape_nsf.R          # NSF Terminated Awards CSV parser
  fetch_usaspending.R   # USAspending.gov award + transaction fetcher
  validate.R            # assertr schema enforcement
  transform.R           # Fuzzy join, discrepancy detection, freeze enrichment
  visualize.R           # ggplot2 charts (GW visual style)
  utils.R               # Shared HTTP, date parsing, logging
tests/
  testthat/test-parsers.R   # 230 tests covering all modules
_targets.R                  # Pipeline orchestration
```

### Data Quality Flags

| Flag | Dataset | Description |
|---|---|---|
| `flag_negative_outlay` | Awards | Negative outlays (accounting adjustments) |
| `flag_over_disbursed` | Awards | Outlays > 150% of award amount |
| `flag_date_inverted` | Awards | End date before start date |
| `flag_zero_award` | Awards | $0 award amount |
| `flag_future_date` | Awards | Action date in the future |
| `flag_cfda_mismatch` | Awards | CFDA prefix doesn't match agency |
| `flag_international` | Notices | Canadian province (cross-border grant) |
| `flag_invalid_state` | Notices | Unrecognized state/territory code |
| `flag_bad_grant_number` | Notices | Malformed grant number for agency |
| `flag_amount_mismatch` | Joined | >25% gap between sources (exact matches only) |

</details>

## License

MIT
