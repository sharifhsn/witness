# Grant Witness PoC

**693 federal grants show active spending despite termination notices.**

This pipeline cross-references NIH and NSF grant termination data against official USAspending.gov records to find grants where government reporting contradicts observed termination activity. Built as a proof-of-concept extension of [Grant Witness](https://grant-witness.us/).

**[Live Dashboard](https://sharifhsn.github.io/witness/)**

## What This Discovers

| Discrepancy | What It Means | Count |
|---|---|---|
| **Active Despite Terminated** | USAspending shows live outlays on a grant that termination notices say is dead | 693 |
| **Possible Freeze** | Award period is open, confirmed low or zero disbursements (<10% outlay ratio). Note: uses current outlay ratio, not outlay state at time of targeting — see methodology notes below | 4,660 |
| **Possible Freeze (No Data)** | Award period is open but outlay data is missing — cannot confirm or rule out freeze | 280 |
| **Untracked** | Official awards from tracked agencies with no corresponding forensic notice | 11,310 |

The `possible_freeze` category is further triaged by **elapsed time** and **transaction-level data**. Transaction-level analysis assigns freeze confidence (high/medium/low) based on the actual last disbursement date. Awards >$1B (Medicaid entitlements, umbrella contracts) are flagged separately to avoid distorting aggregate statistics.

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

**File C temporal reconstruction** — Period-by-period outlay data from USAspending File C (`/api/v2/awards/funding/`) enables temporal freeze reconstruction: checking whether outlays were $0 during each month of an institutional freeze, not just the aggregate ratio. Combined with Grant Witness targeting dates, computes `outlays_before_targeting`, `outlays_during_targeting`, and `months_zero_during_freeze`. Produces a `freeze_evidence` classification: confirmed_freeze (3+ zero months + 180d gap), likely_freeze, possible_freeze, likely_not_frozen, or confirmed_not_frozen.

### Known Methodology Gaps vs. Grant Witness

Our `possible_freeze` flag uses a different (and less precise) methodology than Grant Witness's frozen grant detection:

1. **We use current outlay ratio; GW uses outlay state at time of targeting.** GW's Feb 2026 update ("Refining our criteria for 'frozen' NIH grants") showed that using current outlays produces false negatives: grants that were frozen then unfrozen may appear fully paid out now. The fix is to subtract post-freeze outlays from current totals to reconstruct the state at freeze onset. We don't do this yet.

2. **We flag any active award with low outlays; GW requires a known targeted institution.** GW only classifies grants as frozen at 8 specific universities (Harvard, Columbia, Brown, Cornell, Weill Cornell, Northwestern, Duke, UPenn). Our approach is broader but less precise — many grants legitimately have low outlays.

3. **We don't track reinstatements.** GW tracks "Possibly Reinstated" (date re-extension or court order) and "Reinstated" (confirmed by subsequent outlay). We have no reinstatement logic.

4. **File C integration (partially closed).** We now fetch USAspending File C data (`/api/v2/awards/funding/`) for freeze-relevant grants, enabling temporal reconstruction and `freeze_evidence` classification (confirmed/likely/possible). However, our File C fetch is per-award (not bulk), so we only cover grants already flagged — GW processes File C for their entire database.

## Key Results

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

## Novel Contributions

Verified against the [full Grant Witness website](https://grant-witness.us/) as of March 2026.

| Capability | Grant Witness | This PoC |
|---|---|---|
| Active-despite-terminated detection | Not available — no cross-reference of outlays vs. termination status | Flags 693 grants still receiving outlays despite termination notices |
| Institution-agnostic freeze detection | Requires knowing which institutions are targeted (8 named universities) | Flags any grant with low outlay ratio, potentially catching freezes before they're public |
| Automated data quality flags | Acknowledges data quality issues in prose; no systematic flagging | 10 automated flags quantifying source disagreement (24 exact matches with >25% amount discrepancy) |
| Cross-agency unified view | Separate pages and reports per agency | Single joined dataset across NIH + NSF + EPA |
| NIH institute-level breakdown | Blog post narrative (May 2025) with per-IC analysis | Automated per-IC counts on every pipeline run (programmatic, not one-off) |
| Obligation vs. outlay analysis | Uses File C period-by-period outlays at targeted institutions | Aggregate outlay ratio on any active award (broader but less precise) |
| Transaction-level timelines | File C monthly aggregates for freeze detection | Individual disbursement events from USAspending transactions endpoint |
| Treasury Fiscal Data integration | Not used | MTS Table 5 bureau-level outlays as macro early warning signal — detects spending drops 1-2 months before USAspending |

**What Grant Witness does that we don't (yet):** reinstatement tracking (Possibly Reinstated / Reinstated), crowdsourced PI self-reports, SAMHSA and CDC agency coverage, flagged-word analysis, RCDC spending category ML predictions, overdue funding detection, event history tracking (multiple rounds of termination/reinstatement). Note: File C integration and temporal freeze reconstruction are now partially implemented — see methodology section.

## Visualizations

| | |
|---|---|
| ![Institute Bar Chart](output/institute_bars.png) | ![Discrepancy Summary](output/discrepancy_summary.png) |
| ![Outlay Scatter](output/outlay_scatter.png) | ![Freeze Severity](output/freeze_severity.png) |

![State Map](output/state_map.png)

## Novel Data Signals (Not in Grant Witness)

### Subaward Flow Analysis
Tracks money flowing from prime recipients to sub-recipients via USAspending's subaward search. Detects:
- **Frozen grants with active subawards** — workaround patterns where institutional freezes don't block downstream money flow
- **Terminated grants still paying subawardees** — contradictions invisible to prime-award-level analysis
- **Downstream institution impact** — which smaller institutions are affected by freezes at major research universities

### Treasury Fiscal Data Early Warning
Queries Treasury's Monthly Treasury Statement (MTS Table 5) for bureau-level outlays with ~30 day lag — detecting agency spending drops 1-2 months before USAspending grant-level data reflects them. Detects:
- **Month-over-month anomalies** — >20% outlay drops at NIH, NSF, CDC, SAMHSA, EPA
- **Year-over-year anomalies** — >15% drops vs same month prior year
- **Z-score outliers** — outlays >2 standard deviations below trailing 12-month mean
- **Cross-reference corroboration** — do macro spending drops at an agency correlate with our grant-level freeze flags?

Grant Witness does not use Treasury Fiscal Data. The job posting explicitly lists Treasury Fiscal Data hub as a platform the data scientist should examine.

### De-obligation Spike Detection
Identifies fund clawbacks (negative obligations) in transaction data as an **early warning signal**. De-obligations precede outlay drops — money gets pulled back before disbursements stop. Detects:
- **Per-grant de-obligation events** — individual grants losing funding
- **Agency-month spikes** — coordinated rescission patterns across multiple awards (>2x median monthly rate)

Grant Witness monitors outlays dropping to $0 but does not surface de-obligation patterns as a distinct signal.

## Freeze Heuristic Calibration

We calibrate our freeze detection against Grant Witness's published labeled dataset
([analysis report](analysis/freeze_calibration.qmd)). The calibration pipeline:

1. Downloads GW's NIH CSV with labeled frozen/unfrozen/terminated grants
2. Joins to our USAspending data by award ID (exact match)
3. Measures precision/recall of our `outlay_ratio < 10%` heuristic
4. Sweeps thresholds to find the F1-optimal cutoff
5. Trains a logistic regression classifier using pipeline features
6. Analyzes the temporal reconstruction gap (current vs. at-targeting outlays)
7. Examines the Duke anomaly (Dec 2025 outlays during active freeze)

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
usaspending_awards ─ validated_awards ─┘                 ├─ discrepancies_enriched ─┐
                                                         ├─ discrepancy_summary    │
                                                         └─ file_c_probe           │
                                                              │                    │
                                                         file_c_data ──────────────┤
                                                              │                    │
gw_nih_data ─── targeting_lookup ─── file_c_features ──────────┤
                                                              │
                                                    discrepancies_file_c ──────────┐
                                                         ├─ plot_files             │
                                                         └─ export_parquet         │
                                                                                   │
subaward_data ─── subaward_analysis ◄──────────────────────────────────────────────┤
transaction_data ─┬─ deobligation_summary                                          │
                  └─ deobligation_spikes                                           │
                                                                                   │
treasury_mts_data ─┬─ treasury_anomalies ─┬─ treasury_anomalies_enriched ◄───────┤
                   │                      └─ treasury_file_c_corroboration ◄──────┤
                   └─ treasury_plots ◄──────────────────────────────────────────┤
                                                                                │
gw_nih_data ── calibration_data ◄──────────────────────────────────────────────┘
                   └─ calibration_features ─┬─ calibration_results
                                            ├─ temporal_analysis
                                            ├─ freeze_classifier
                                            └─ calibration_plots
```

### Data Sources

- [NIH Reporter API](https://api.reporter.nih.gov/) — terminated grant projects (offset cap: 14,999)
- [NSF Terminated Awards CSV](https://nsf-gov-resources.nsf.gov/files/NSF-Terminated-Awards.csv) — Latin-1 encoded
- [USAspending.gov API](https://api.usaspending.gov/) — award records (page cap: 100), transaction search, and File C funding data (period-by-period outlays)
- [Treasury Fiscal Data API](https://fiscaldata.treasury.gov/) — MTS Table 5 bureau-level outlays (~30 day lag)

### Tech Stack

- **R** with [{targets}](https://docs.ropensci.org/targets/) for reproducible pipeline orchestration
- **httr2** for polite API access (rate limiting, retries, exponential backoff)
- **fuzzyjoin** for Jaro-Winkler string-distance matching
- **assertr** for runtime data validation
- **ggplot2** with viridis palette matching Grant Witness visual style

### Project Structure

```
R/
  scrape_nih.R              # NIH Reporter API scraper
  scrape_nsf.R              # NSF Terminated Awards CSV parser
  fetch_usaspending.R       # USAspending.gov award + transaction fetcher
  fetch_file_c.R            # USAspending File C period-by-period outlay fetcher
  fetch_gw.R                # Grant Witness CSV downloader + File C parser
  fetch_treasury.R          # Treasury Fiscal Data MTS Table 5 fetcher
  validate.R                # assertr schema enforcement
  transform.R               # Fuzzy join, discrepancy detection, freeze enrichment
  detect_treasury_anomalies.R # Treasury spending anomaly detection + cross-referencing
  calibrate_freeze.R        # Calibration analysis against GW ground truth
  visualize.R               # ggplot2 charts (GW visual style)
  visualize_calibration.R   # Calibration-specific plots
  visualize_treasury.R      # Treasury timeline + anomaly corroboration plots
  utils.R                   # Shared HTTP, date parsing, logging
analysis/
  freeze_calibration.qmd    # Reproducible calibration report
tests/
  testthat/test-parsers.R   # Unit tests
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
| `flag_umbrella_award` | Joined | Award >$1B (Medicaid entitlements, umbrella contracts) |
| `flag_missing_outlay_data` | Joined | Freeze flag based on missing data, not confirmed low outlays |

</details>

## License

MIT
