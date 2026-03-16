# Grant Witness PoC

**693 federal grants are receiving active outlays despite termination notices.**

This pipeline cross-references NIH and NSF termination data against official USAspending.gov records to surface discrepancies in federal grant execution. Built as a proof-of-concept extension of [Grant Witness](https://grant-witness.us/).

**[Live Dashboard](https://sharifhsn.github.io/witness/)**

## What This Finds

| Discrepancy Type | What It Means | Count |
|---|---|---|
| **Active Despite Terminated** | USAspending shows live outlays on a grant termination notices say is dead | 693 |
| **Possible Freeze (confirmed)** | Open award period + confirmed low/zero disbursements (<10% outlay ratio) | 4,660 |
| **Possible Freeze (no data)** | Open award period, outlay data missing — freeze cannot be confirmed or ruled out | 280 |
| **Untracked** | Official awards from tracked agencies with no corresponding forensic notice | 11,310 |

The pipeline goes three layers deep — individual grants, program-level patterns, and agency budget execution — each using independent data sources.

## Three Layers of Analysis

### Layer 1 — Grant-Level Cross-Reference

Cross-references termination notices against USAspending award records. The core technical challenge: NIH grant numbers don't match USAspending award IDs, requiring fuzzy matching on organization names. Two-pass approach:

1. **Exact match** on grant number (works for NSF, which uses the same 7-digit ID in both systems): 489 matches
2. **Fuzzy match** on organization name — Jaro-Winkler distance ≤ 0.08 plus a distinctive-token filter requiring shared non-stopword tokens. Initial threshold of 0.15 produced 71% false positives ("University of Chicago" → "University of Utah"); tightened to 2,498 high-precision matches.

**Transaction-level freeze confirmation** — For freeze-flagged grants, the pipeline fetches individual transaction records to determine when the last disbursement actually occurred. Grants with >180 days since last transaction are classified as high-confidence freezes.

**File C temporal reconstruction** — Period-by-period outlay data from USAspending File C (`/api/v2/awards/funding/`) enables reconstructing outlay state at the time of institutional targeting, not just the current aggregate ratio. Combined with Grant Witness targeting dates, computes `outlays_before_targeting`, `outlays_during_targeting`, and `months_zero_during_freeze`. Produces a five-tier `freeze_evidence` classification: confirmed_freeze / likely_freeze / possible_freeze / likely_not_frozen / confirmed_not_frozen.

### Layer 2 — Program-Level YoY Comparison

**CFDA program breakdown** (`fetch_cfda_breakdown`) queries USAspending's `spending_by_category/cfda/` endpoint to compare FY2026 award counts and obligations against FY2025 baselines by CFDA program code. This surfaces *which programs* are being frozen, not just which institutions.

Verified numbers from live API (FY2026 Oct–Mar vs FY2025 Oct–Mar):
- NSF total new grants: −65% (2,072 vs 5,929)
- NIH total new grants: −21% (24,054 vs 30,520)

**Award obligation flow** (`fetch_award_obligations_flow`) queries `spending_over_time` for month-by-month new obligation rates, providing a flow signal that complements the stock signal from GTAS.

### Layer 3 — Agency Budget Execution (GTAS)

**`fetch_agency_obligations`** queries the `budgetary_resources` endpoint (`/api/v2/agency/{toptier_code}/budgetary_resources/`), which is sourced directly from Treasury's GTAS system — independent of award-level USAspending data. Returns period-by-period cumulative obligations for each agency.

This is a different claim than Layer 1: not "these specific grants are frozen" but "the agency's entire new-obligation pipeline has collapsed":
- NSF FY2026 P4 (through January): $544M vs $1,051M in FY2025 — **−48% YoY**

Grant Witness does not use GTAS data. The job posting explicitly lists Treasury Fiscal Data hub as a platform the data scientist should examine.

> **`feature/macro-signals` branch** adds a fourth layer: Daily Treasury Statement (1-day lag real-time withdrawal signal) and obligation drought analysis framing the shortfall as an "iceberg" — GW's tracked terminations are the visible tip; the obligation drought is the submerged portion GW's methodology cannot see.

## Calibration Against Grant Witness Ground Truth

The pipeline downloads GW's published NIH labeled dataset and calibrates our freeze detection against it:

1. Joins GW's labeled grants to our USAspending data by award ID
2. Measures precision/recall of the `outlay_ratio < 10%` heuristic
3. Sweeps thresholds to find the F1-optimal cutoff
4. Trains a logistic regression classifier using pipeline features (outlay ratio, time since last transaction, File C monthly pattern, award amount)
5. Analyzes the temporal reconstruction gap (current vs. at-targeting outlays)
6. Examines the Duke anomaly (Dec 2025 outlays during an active freeze)

**Key methodology gap vs. GW:** GW's Feb 2026 "Refining our criteria" update reconstructs outlay state at the time of targeting by subtracting post-freeze transactions. Our `possible_freeze` uses the current ratio — producing false negatives for grants that were frozen and later unfrozen. The calibration pipeline quantifies this gap explicitly.

## Key Numbers

| Metric | Value |
|---|---|
| NIH terminated grants scraped | 9,063 (deduplicated) |
| NSF terminated awards parsed | 1,667 |
| USAspending awards fetched | 15,000 (HHS + NSF + EPA) |
| Exact matches (grant number) | 489 |
| Fuzzy matches (org name + date) | 2,498 |
| Active Despite Terminated | 693 |
| Possible Freeze (confirmed) | 4,660 |
| Possible Freeze (no data) | 280 |
| Untracked (no forensic notice) | 11,310 |
| NSF GTAS FY2026 P4 vs FY2025 | −48% ($544M vs $1,051M) |
| NSF CFDA award count YoY | −65% (FY2026 Oct–Mar) |
| NIH CFDA award count YoY | −21% (FY2026 Oct–Mar) |

## Novel Contributions vs. Grant Witness

Verified against the [full Grant Witness website](https://grant-witness.us/) as of March 2026.

| Capability | Grant Witness | This PoC |
|---|---|---|
| Active-despite-terminated detection | Not available | Flags 693 grants still receiving outlays after termination notices |
| Institution-agnostic freeze detection | Requires named targeted institution (8 universities) | Flags any grant with low outlay ratio — wider net, calibrated precision |
| File C temporal reconstruction | Core of freeze detection | Implemented for freeze-flagged grants; `freeze_evidence` 5-tier classification |
| CFDA program-level YoY breakdown | Not available | Which NSF/NIH programs are hardest hit, not just which institutions |
| GTAS agency budget execution | Not available | Independent Treasury-sourced obligation rate; NSF P4 −48% YoY |
| Data quality flags | Prose acknowledgements | 10 automated flags quantifying source disagreement |
| Cross-agency unified view | Separate reports per agency | Single joined dataset across NIH + NSF + EPA |
| Subaward flow analysis | Not available | Downstream sub-recipient exposure for terminated prime awards |
| De-obligation spike detection | Not available | Early clawback signal; de-obligations precede outlay drops |
| GW calibration | Produces ground truth | Evaluates our heuristics against their labeled dataset |

**What GW does that this PoC doesn't (yet):** reinstatement tracking, crowdsourced PI self-reports, SAMHSA and CDC coverage, TAGGS PDF integration, outlay-state-at-targeting reconstruction, overdue funding detection, RCDC spending category ML model.

## Visualizations

| | |
|---|---|
| ![Institute Bar Chart](output/institute_bars.png) | ![Discrepancy Summary](output/discrepancy_summary.png) |
| ![Outlay Scatter](output/outlay_scatter.png) | ![Freeze Severity](output/freeze_severity.png) |

![State Map](output/state_map.png)

## Running the Pipeline

```r
renv::restore()        # Install dependencies
targets::tar_make()    # Run the full pipeline
```

Data is cached in `data/raw/*.rds` — delete a file (or run `scripts/fetch_data.R --force <name>`) to re-fetch from the live API.

<details>
<summary>Technical Details</summary>

### Pipeline DAG

```
notices_nih ─────┐
                 ├─ validated_notices ─┐
notices_nsf ─────┘                     │
                                       ├─ discrepancies ─┬─ transaction_data ─┬─ termination_actions
usaspending_awards ─ validated_awards ─┘                 │                   ├─ reinstatement_patterns
                                                         │                   ├─ deobligation_summary
                                                         │                   └─ deobligation_spikes
                                                         ├─ discrepancy_summary
                                                         └─ file_c_probe
                                                              │
                                                         file_c_data ────────────────────────┐
                                                              │                             │
gw_nih_data ─┬─ targeting_lookup ─── file_c_features ────────┤                             │
             │                                               │                             │
             └─ calibration_data ─── calibration_features ─┬─ calibration_results         │
                                                           ├─ freeze_classifier            │
                                                           ├─ temporal_analysis            │
                                                           └─ calibration_plots            │
                                                                                           ▼
                                                         discrepancies_file_c ─┬─ discrepancies_emergency
                                                              │                ├─ subaward_analysis
                                                              ├─ plot_files    └─ subaward_impact
                                                              └─ export_parquet

cfda_breakdown          (CFDA program YoY — spending_by_category/cfda/)
agency_obligations      (GTAS period obligations — agency/{code}/budgetary_resources/)
award_obligations_flow  (transaction flow — spending_over_time/)
```

### Data Sources

| Source | Endpoint | Notes |
|---|---|---|
| NIH Reporter API | `api.reporter.nih.gov/v2/projects/search` | Offset cap: 14,999; paginated |
| NSF Terminated Awards CSV | `nsf-gov-resources.nsf.gov/files/NSF-Terminated-Awards.csv` | Latin-1 encoding |
| USAspending awards | `POST /api/v2/search/spending_by_award/` | Page cap: 100 |
| USAspending transactions | `POST /api/v2/search/spending_by_transaction/` | Filter by `award_ids` |
| USAspending File C | `POST /api/v2/awards/funding/` | Requires `generated_internal_id` |
| USAspending GTAS | `GET /api/v2/agency/{toptier_code}/budgetary_resources/` | All FY in one call |
| USAspending CFDA | `POST /api/v2/search/spending_by_category/cfda/` | Category in URL path |
| USAspending spending flow | `POST /api/v2/search/spending_over_time/` | `"group": "month"` |
| Grant Witness CSVs | `grant-witness.us/data/` | Ground truth for calibration |

### Tech Stack

- **R** with [{targets}](https://docs.ropensci.org/targets/) for reproducible pipeline orchestration
- **httr2** for polite API access (rate limiting, retries, exponential backoff)
- **fuzzyjoin** for Jaro-Winkler string-distance matching
- **assertr** for runtime data validation
- **ggplot2** matching Grant Witness visual style

### Project Structure

```
R/
  scrape_nih.R              # NIH Reporter API v2 paginated scraper
  scrape_nsf.R              # NSF Terminated Awards CSV parser
  fetch_usaspending.R       # USAspending awards, transactions, subawards
  fetch_file_c.R            # File C period-by-period outlay fetcher
  fetch_usaspending_budget.R # GTAS obligations, CFDA breakdown, award flow
  fetch_gw.R                # Grant Witness CSV downloader + parser
  transform.R               # Fuzzy join, discrepancy flags, freeze enrichment
  calibrate_freeze.R        # Calibration against GW ground truth
  validate.R                # assertr schema enforcement + data quality flags
  visualize.R               # ggplot2 charts (GW visual style)
  visualize_calibration.R   # Calibration-specific plots
  utils.R                   # Shared HTTP, date parsing, logging
tests/
  testthat/test-parsers.R   # 404 assertions across all modules
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
| `flag_cfda_mismatch` | Awards | CFDA prefix doesn't match awarding agency |
| `flag_international` | Notices | Canadian province code (cross-border NIH grant) |
| `flag_invalid_state` | Notices | Unrecognized state/territory code |
| `flag_bad_grant_number` | Notices | Malformed grant number format for agency |
| `flag_amount_mismatch` | Joined | >25% gap between sources (exact matches only) |
| `flag_umbrella_award` | Joined | Award >$1B (Medicaid entitlements, umbrella contracts) |
| `flag_missing_outlay_data` | Joined | Freeze inferred from missing data, not confirmed low outlays |

</details>

## License

MIT
