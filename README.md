# Grant Witness PoC

A reproducible R data pipeline that cross-references federal grant termination data with official USAspending.gov records to surface discrepancies in government reporting.

Built as a proof-of-concept extension of [Grant Witness](https://grant-witness.us/), demonstrating novel data analysis capabilities beyond the existing platform.

## What This Does

```
NIH Reporter API ──┐                                  ┌── Discrepancy Flags
                    ├── Validate ──┐                   │   - active_despite_terminated
NSF Terminated CSV ─┘              ├── Join & Flag ────┤   - possible_freeze
                                   │                   │   - untracked
USAspending.gov API ── Validate ───┘                   └── Visualizations + Parquet
```

The pipeline discovers grants where **government reporting contradicts observed termination activity**:

- **Active Despite Terminated** — USAspending shows live outlays on a grant that termination notices say is dead
- **Possible Freeze** — Award period is open but disbursements are absent or near-zero (< 10% outlay ratio)
- **Untracked** — Official awards from tracked agencies with no corresponding forensic notice (coverage gaps)

## Novel Contributions

| Capability | Grant Witness | This PoC |
|---|---|---|
| NIH institute-level breakdown | Agency-level only | Per-IC granularity (NIGMS, NIAID, etc.) |
| Obligation vs. outlay analysis | Not available | Detects "frozen in practice" silent stoppages |
| Active-despite-terminated | Not available | Direct contradiction detection |
| Cross-agency comparison | Separate pages | Unified join across NIH + NSF + EPA |
| Geographic distribution | State-level maps | State-level choropleth from NIH Reporter |

## Visualizations

### NIH Institutes by Terminated Grant Count
![Institute Bar Chart](output/institute_bars.png)

### Federal Grant Discrepancies by Agency
![Discrepancy Summary](output/discrepancy_summary.png)

### Award Amount vs. Outlay Ratio
![Outlay Scatter](output/outlay_scatter.png)

### Geographic Distribution
![State Map](output/state_map.png)

## Latest Results

| Metric | Value |
|---|---|
| NIH terminated grants scraped | 9,063 (deduplicated, active-filtered) |
| NSF terminated awards parsed | 1,667 |
| USAspending awards fetched | 15,000 (HHS + NSF + EPA) |
| Exact matches (grant number) | 489 |
| Fuzzy matches (org name + date) | 17,204 |
| Active Despite Terminated | 2,395 grants |
| Possible Freeze (< 10% outlay) | 17,937 grants |
| Untracked (no forensic notice) | 11,310 grants |

## Running the Pipeline

```r
# Install dependencies
renv::restore()

# Run the full pipeline
targets::tar_make()
```

The pipeline scrapes live data from:
- [NIH Reporter API](https://api.reporter.nih.gov/) — terminated grant projects
- [NSF Terminated Awards CSV](https://nsf-gov-resources.nsf.gov/files/NSF-Terminated-Awards.csv)
- [USAspending.gov API](https://api.usaspending.gov/) — official award records for HHS, NSF, EPA

Output lands in `output/`:
- `discrepancies.parquet` — full joined dataset with discrepancy flags
- `*.png` — visualization plots

## Pipeline DAG

```
notices_nih ─────┐
                 ├─ validated_notices ─┐
notices_nsf ─────┘                     │
                                       ├─ discrepancies ─┬─ discrepancy_summary
usaspending_awards ─ validated_awards ─┘                 ├─ plot_files
                                                         └─ export_parquet
```

## Tech Stack

- **R** with [{targets}](https://docs.ropensci.org/targets/) for reproducible pipeline orchestration
- **httr2** for polite API access (rate limiting, retries, exponential backoff)
- **fuzzyjoin** for Jaro-Winkler string-distance matching across datasets
- **assertr** for runtime data validation
- **ggplot2** with viridis palette matching Grant Witness visual style
- **GitHub Actions** for weekly automated runs

## Project Structure

```
R/
  scrape_nih.R          # NIH Reporter API scraper
  scrape_nsf.R          # NSF Terminated Awards CSV parser
  fetch_usaspending.R   # USAspending.gov award fetcher
  validate.R            # assertr schema enforcement
  transform.R           # Fuzzy join + discrepancy detection
  visualize.R           # ggplot2 charts (GW visual style)
  utils.R               # Shared HTTP, date parsing, logging
tests/
  testthat/test-parsers.R   # 170 tests covering all modules
_targets.R                  # Pipeline orchestration
```

## License

MIT
