# Grant Witness PoC — Data Quality Notes

Ongoing record of data quality findings for `output/discrepancies.parquet` and upstream
pipeline outputs. Updated as new pipeline runs complete. Severity levels: **error** (blocks
use), **warning** (distorts aggregates; filter before reporting), **info** (expected behaviour
worth documenting).

---

## Dataset Snapshot

| Run | Rows | Columns | Last updated |
|---|---|---|---|
| 2026-03-14 | 17,446 | 40 | Pre-emergency-flags (session 2) |
| 2026-03-15 | 17,429 | 61 | Full rebuild — new columns + emergency flags |
| 2026-03-15 | 17,429 | 61 | QA pass 3 — freeze evidence + calibration gap documented |

---

## Finding Index

| ID | Severity | Category | Short description |
|---|---|---|---|
| DQ-01 | warning | distribution | Umbrella/entitlement grants inflate award_amount aggregates |
| DQ-02 | warning | fuzzy-join | High fan-out fuzzy matches inflate row count for large universities |
| DQ-03 | warning | fuzzy-join | 25% of fuzzy matches have >10× award amount discrepancy |
| DQ-04 | warning | financial | 59 over-disbursed grants (outlay_ratio > 1.0) |
| DQ-05 | warning | financial | 16 grants with negative outlay_ratio (clawbacks) |
| DQ-06 | warning | temporal | 134 awards with future action_date |
| DQ-07 | warning | temporal | 233 awards with action_date before 2000-01-01 |
| DQ-08 | warning | sentinel | 412 grants with exactly $1,000,000 award_amount (possible batch default) |
| DQ-09 | warning | description | 11 boilerplate descriptions account for 2,447 rows (14%) |
| DQ-10 | info | coverage | NSF notice coverage 29% — 1,178 NSF awards outside USAspending time window |
| DQ-11 | info | description | 2,235 fuzzy matches have identical org_name — could have exact-matched on org |
| DQ-12 | info | description | Long-duration awards: 1,088 with >15-year stated duration |
| DQ-13 | warning | def_codes | IIJA code Q present on 82% of awards — too ubiquitous for political targeting signal |
| DQ-14 | info | completeness | recipient_uei: 0% NA, all valid post-2022 format |
| DQ-15 | info | completeness | generated_internal_id: 0% NA, 100% ASST_NON_ format — File C lookups safe |
| DQ-16 | info | completeness | last_modified_date: 0% NA, 2,030 awards modified in last 30 days |
| DQ-17 | info | flag | flag_emergency_exempt: 607 grants (3.5%) — COVID/ARP code on freeze-type grant |
| DQ-18 | fixed | enrichment | active_despite_terminated: all 693 rows have null transaction data — root cause: hardcoded filter in `transaction_data` target excluded ADT grants |
| DQ-19 | info | expected-NA | Targeting columns 99.2% NA — only 13 grants have confirmed freeze evidence |
| DQ-20 | fixed | calibration | Current heuristic catches 0 of 34 GW-confirmed frozen grants — root cause: `our_freeze_flag` tested `discrepancy_type` (always `untracked` for calibration grants) instead of financial signal |
| DQ-21 | info | signal | 4,151 expired grants (end_date past) excluded from freeze pool — good filter |
| DQ-22 | info | coverage | possible_freeze_no_data: 280 rows, 73% NSF — no File C data available |
| DQ-23 | fixed | classification | 198/201 HHS possible_freeze grants were Medicaid/TANF entitlements — excluded via NON_RESEARCH_HHS_SUBAGENCIES filter |

---

## Detailed Findings

### DQ-01 — Umbrella/entitlement grants inflate award_amount aggregates

**Severity:** warning
**Category:** distribution
**n_affected:** 211 (awards >$1B)

USAspending includes MEDICAID ENTITLEMENT umbrella vehicles (e.g., `MEDICAID ENTITLEMENT
FOR 7 - FY 2026 - T19`, max = $101.3B) in the HHS award pull. These are not individual
research grants. Their presence makes mean `award_amount` ($134M) meaningless; median is
$2.5M. Awards >$1B account for **76.7% of total dollar volume** in the dataset.

**Impact:** Any aggregate dollar total, average, or "top institutions by funding" analysis
is severely distorted without filtering.

**Recommended filter:** `award_amount < 1e9` before any aggregate reporting. For freeze
analysis specifically, these umbrella awards never appear as terminated grants, so they
don't affect freeze counts — only dollar figures.

**Status:** Known; no code change required. Document in any public-facing output.

---

### DQ-02 — High fan-out fuzzy matches inflate row count for large universities

**Severity:** warning
**Category:** fuzzy-join
**n_affected:** 2,413 rows from 57 notice groups matched to >3 awards each

10 large universities (UCLA, UCSD, UF, JHU, U Illinois, etc.) generate >50 fuzzy matches
each (max fan-out: 400 — "Arizona State University" matching every ASU award). Total
inflated rows: ~2,189.

Row count in fuzzy stratum (2,498) therefore represents ~37 effective unique notice-award
pairs, not 2,498. The fuzzy stratum should not be used for counting unique affected grants.

**Root cause:** Fuzzy matching on org name without a shared key (NIH Reporter uses
institution names; USAspending uses recipient names — no common ID). NSF exact-match
(489 rows) is not affected.

**Recommended filter:** Use `match_method == "exact"` for per-grant financial claims. Use
aggregate fuzzy counts with explicit "may include duplicates" caveat.

**Status:** Structural limitation. JW ≤ 0.08 + `share_distinctive_token()` filter already
applied. Further tightening would increase false negatives.

---

### DQ-03 — Fuzzy matches with >10× award amount discrepancy

**Severity:** warning
**Category:** fuzzy-join
**n_affected:** 622 (25.1% of fuzzy stratum)

When the notice `award_amount` and the USAspending `award_amount` differ by more than 10×,
the match is likely a false positive — the same institution name matching a different award.

**Recommended filter:** For any per-grant financial analysis using fuzzy matches, add
`award_amount_ratio < 10` (or equivalent) to exclude these rows.

**Status:** Known; regression test exists. No code change required.

---

### DQ-04 — Over-disbursed grants (outlay_ratio > 1.0)

**Severity:** warning
**Category:** financial
**n_affected:** 59 (max ratio = 1.81)

Total outlays exceed total obligated amount. Causes: (a) accounting adjustments, (b)
sequencing where final outlays post after the obligation record closes, (c) supplemental
obligations not yet captured in the award record.

These grants can appear as `possible_freeze` candidates with `outlay_ratio < 0.10` only
after future de-obligations. More commonly they appear in `normal` or `untracked`.

**Status:** Expected USAspending behaviour. No fix needed; exclude from freeze ratio
analysis.

---

### DQ-05 — Negative outlay_ratio (clawbacks)

**Severity:** warning
**Category:** financial
**n_affected:** 16

`total_outlays < 0` — grant recovered more funds than it disbursed. Indicates a clawback
or recapture action in USAspending.

**Status:** Expected. These grants may be interesting for de-obligation analysis
(`detect_deobligations` target) but should be excluded from freeze ratio thresholds.

---

### DQ-06 — Future action_date values

**Severity:** warning
**Category:** temporal
**n_affected:** 134 (max: 2026-11-01)

`action_date` is in the future relative to pipeline run date. For multi-year grants,
USAspending records the anticipated modification date. These are not data errors.

**Status:** Expected. Exclude these rows from recency-based filters (e.g.,
"recently modified") or document the behaviour.

---

### DQ-07 — Pre-2000 action_date values

**Severity:** warning
**Category:** temporal
**n_affected:** 233 (min: 1975-06-28)

Awards with action dates before 2000 are still active in USAspending (long-running
programmes, multi-decade grants, or legacy records not retired). Not a data error.

**Status:** Expected. These awards are unlikely to be freeze candidates and can be
filtered by `action_date >= "2020-01-01"` for recent-termination analysis.

---

### DQ-08 — $1,000,000 sentinel award amounts

**Severity:** warning
**Category:** sentinel
**n_affected:** 412

Exactly 412 awards have `award_amount == 1000000`. This round number appearing 412 times
suggests either a batch processing default in USAspending ingest or a common NIH/NSF grant
tier. Investigate before using as a financial signal.

**Status:** Under investigation. Could be legitimate (many grants are awarded at exactly
$1M) or a system default. See `qa_findings.csv` round 5.

---

### DQ-09 — Boilerplate descriptions

**Severity:** info
**Category:** description
**n_affected:** 2,447 rows across 11 descriptions

The top descriptions are CFDA programme names, not grant-specific titles:
- `HEALTH CENTER CLUSTER` — 535 rows
- `HEAD START AND EARLY HEAD START` — 512 rows
- Others: biomaterials, collaborative research boilerplate

These are umbrella/block-grant CFDA awards that carry the programme name as their
description. Not useful for text-based grant classification.

**Status:** Expected. Filter `award_description` on these values if building a text
classifier.

---

### DQ-10 — NSF notice coverage at 29%

**Severity:** info
**Category:** coverage
**n_affected:** 1,178 unmatched NSF notices

489 of 1,667 NSF terminated notices (29%) match to a USAspending award. The remaining
1,178 are outside the USAspending query time window or used award IDs that don't match
the 7-digit format used in both systems.

**Status:** Expected; documented in `qa_findings.csv` round 6. The NSF exact-match path
is correct — the coverage gap is a data availability limitation, not a join error.

---

### DQ-11 — Fuzzy matches with identical org_name on both sides

**Severity:** info
**Category:** fuzzy-join
**n_affected:** 2,235

If both the notice and the award have the same `org_name`, the match could have been
an exact org-level match rather than fuzzy. These rows are likely high-quality fuzzy
matches but represent a possible efficiency improvement (dedup before fuzzy join).

**Status:** Info only. These are not false positives — the join is correct. Future
optimisation: exact-match on `org_name` before falling back to fuzzy.

---

### DQ-12 — Long-duration awards (>15 years)

**Severity:** info
**Category:** description
**n_affected:** 1,088

Awards with project duration > 15 years. These are typically: training grants (T32),
resource grants (P41/U24), cooperative agreements, or infrastructure awards. They are
legitimate but may skew the "elapsed ratio" heuristic since they stay "active" for
decades.

**Status:** Expected. The `file_c_features` target's temporal reconstruction already
handles this by using period-by-period outlay patterns rather than elapsed ratio alone.

---

---

### DQ-13 — IIJA def_code Q ubiquitous; excluded from emergency flag

**Severity:** warning
**Category:** def_codes
**n_affected:** 14,351 awards (82.3% of dataset)

DEFC `Q` (P.L. 117-58, Infrastructure Investment and Jobs Act) appears on nearly all
awards across all three agencies (HHS: 3,791; EPA: 3,788; NSF: 6,772). This pervasive
tagging reflects broad IIJA research mandates, not targeted emergency supplemental funding.

Including `Q` in `flag_emergency_exempt` produced a 90% flag rate across freeze-type
grants — rendering the flag useless as a political targeting signal.

**Fix applied:** `EMERGENCY_DEFC_CODES` constant restricts to COVID-19 and ARP codes only
(Z, L, M, N, 3–7). `Q` and infrastructure-era codes are excluded. Also excludes V, U, AAB,
AAK (seen on <1.5% each; provenance unconfirmed).

**Result after fix:** 607 grants flagged (3.5%) — a signal-grade prevalence.

---

### DQ-14 — recipient_uei: complete and valid

**Severity:** info
**Category:** completeness
**n_affected:** 0 missing

All 17,429 rows have a non-null, non-empty `recipient_uei`. USAspending made UEI mandatory
in April 2022 (replacing DUNS). All awards in our date range comply.

**Status:** No action needed.

---

### DQ-15 — generated_internal_id: complete and correctly formatted

**Severity:** info
**Category:** completeness
**n_affected:** 0 missing or malformed

All 17,429 rows follow the `ASST_NON_{award_id}_{agency_CGAC}` format exactly. File C
lookups using this ID are safe with no pre-flight format validation needed.

**Status:** No action needed.

---

### DQ-16 — last_modified_date: complete, 2,030 awards recently modified

**Severity:** info
**Category:** completeness

Range: 2024-10-17 to 2026-03-05. 2,030 awards modified in the last 30 days — these
represent recent USAspending updates and are worth monitoring for newly recorded
terminations or obligation changes that haven't yet propagated to notices.

**Status:** No action needed. Consider a "recently modified" alert in Shiny dashboard.

---

### DQ-17 — flag_emergency_exempt: 607 grants carry COVID/ARP code while frozen

**Severity:** info
**Category:** flag

607 grants (3.5% of all; 10.2% of freeze-type) carry at least one COVID-19 or ARP
def_code while classified as `possible_freeze` or `active_despite_terminated`.

Code breakdown in this subset: Z (Families First) dominates with 531; N (ARP) has 15;
L, M, and multi-code combinations account for the remainder.

**Interpretation:** These grants received congressionally mandated pandemic emergency
funding and are now frozen for regular research. The "selective interference" framing
is strongest here: emergency disbursements continued while academic research was halted.

**Status:** Signal is live. Confirmed by code audit (Q excluded). Ready for public use.

---

### DQ-18 — active_despite_terminated: transaction enrichment not populating

**Severity:** warning
**Category:** enrichment
**n_affected:** 693 (all ADT rows)

All 693 `active_despite_terminated` rows had `last_transaction_date = NA`,
`days_since_last_transaction = NA`, and `flag_confirmed_post_termination_outlays = FALSE`.

**Root cause found:** The `transaction_data` target in `_targets.R` had a hardcoded filter:
```r
discrepancies$grant_number[discrepancies$discrepancy_type %in%
  c("possible_freeze", "possible_freeze_no_data")]
```
This explicitly excluded `active_despite_terminated` grants. Since `transaction_data` never
contained ADT grant IDs, `enrich_with_transactions()` had nothing to join for them.

**Fix applied:** Changed to use `FREEZE_RELATED_DISCREPANCY_TYPES` constant which includes
all three types: `c("possible_freeze", "possible_freeze_no_data", "active_despite_terminated")`.

**Status:** Fixed and verified. After rebuild: all 693 ADT rows have `last_transaction_date`,
`days_since_last_transaction`, and `freeze_confidence` populated. None have `flag_confirmed_post_termination_outlays`
(that column is populated only by the File C path, not the transaction path).

---

### DQ-19 — Targeting columns 99.2% NA (expected)

**Severity:** info
**Category:** expected-NA
**n_affected:** 17,276 of 17,429 rows

Columns `outlays_before_targeting`, `outlays_during_targeting`, `months_zero_during_freeze`,
`pct_outlaid_at_targeting` are populated only when a grant has confirmed File C evidence
AND a GW-sourced targeting date. Only 13 grants in the dataset meet both criteria
(`freeze_evidence = "confirmed_freeze"`). The remaining 4,647 possible_freeze rows use
the simpler `outlay_ratio < 10%` heuristic and leave these columns null.

**Status:** Expected. These columns are populated by the calibration path
(`compute_file_c_features()`) which requires GW ground truth. As GW coverage improves,
these NAs will decrease. Not a pipeline bug.

---

### DQ-20 — Calibration gap: heuristic catches 0 of 34 GW-confirmed frozen grants

**Severity:** warning
**Category:** calibration
**n_affected:** 34 missed GW-confirmed frozen grants

At the current `outlay_ratio < 0.10` threshold, our heuristic had:
- Precision = 0, Recall = 0, F1 = 0 on the 72-grant calibration set

**Root cause found:** `compute_calibration_features()` in `calibrate_freeze.R` set:
```r
our_freeze_flag = discrepancy_type %in% c("possible_freeze", "possible_freeze_no_data")
```
But all 72 calibration-matched grants are `untracked` (GW uses TAGGS PDFs + court docs
we don't scrape; no matching termination notice in our data). So `our_freeze_flag` was
always `FALSE` regardless of actual financial state.

**Fix applied:** Changed to evaluate the financial signal directly:
```r
our_freeze_flag = !is.na(outlay_ratio) & outlay_ratio < FREEZE_RATIO_THRESHOLD
```
This correctly tests whether our methodology would flag each grant based on outlay data,
independent of whether we also have a matching termination notice.

**Expected calibration results post-fix:** GW's confirmed frozen grants have outlay_ratio
0.20–0.99. At `FREEZE_RATIO_THRESHOLD = 0.10`, still expect low recall. The calibration
results after the pipeline rebuild will reveal true performance. Optimal threshold is
likely ~0.50 based on earlier analysis (P=0.591, R=0.765, F1=0.667).

**Status:** Fixed and verified. After rebuild: calibration correctly shows `0 our freeze flag`
at threshold 0.10, proving GW's confirmed frozen grants have `outlay_ratio > 0.10` (they range
0.20–0.99). The threshold recommendation of 0.50 (F1=0.667) remains. The classifier AUC=0.695
is unchanged. The fix reveals the true calibration gap, enabling an informed threshold decision.

---

### DQ-21 — 4,151 expired grants excluded from freeze pool (expected)

**Severity:** info
**Category:** signal
**n_affected:** 4,151 grants with end_date in the past

4,151 awards have `end_date < today` but are classified as `untracked` or `normal`, not
`possible_freeze`. All possible_freeze grants have active end_dates. This is correct
behaviour — a grant cannot be "frozen" after its period of performance has ended.

**Status:** Expected. Confirms the freeze detection correctly excludes expired awards.

---

### DQ-22 — possible_freeze_no_data: 73% NSF, no emergency flags

**Severity:** info
**Category:** coverage
**n_affected:** 280

280 grants have low outlay signals but no USAspending financial data available to confirm
or deny the freeze (hence `possible_freeze_no_data`). Agency breakdown: NSF 206 (73%),
EPA 71 (25%), HHS 3 (1%). None carry COVID/ARP emergency def_codes
(`flag_emergency_exempt = 0`).

The NSF skew reflects that NSF grants are less represented in USAspending transaction
data (fewer transaction records per award vs. NIH). These are the weakest signals in
the freeze pool — lower confidence than `possible_freeze`.

**Status:** Expected. Keep separate from `possible_freeze` in any public-facing count.

### DQ-23 — HHS possible_freeze pool contaminated with Medicaid/TANF entitlements

**Severity:** fixed
**Category:** classification
**n_affected:** 198 of 201 HHS possible_freeze grants

198 out of 201 HHS `possible_freeze` grants were formula/entitlement block grants
(Medicaid, TANF, CHIP, ACF block grants) misclassified as research freezes. These
grants have structurally low outlay_ratios because entitlement disbursement follows
different timing patterns from competitive research grants, not because they are frozen.

Agency breakdown by sub-agency:
- Centers for Medicare and Medicaid Services (CFDA 93.798, 93.767): ~120 grants
- Administration for Children and Families (CFDA 93.558, 93.575): ~60 grants
- Health Resources and Services Administration: ~18 grants

**Root cause:** `classify_discrepancy()` lacked any agency-type awareness. Any HHS
award with low outlay_ratio was classified as `possible_freeze`, including multi-billion-
dollar Medicaid matching grants.

**Fix applied:** Added `NON_RESEARCH_HHS_SUBAGENCIES` constant in `transform.R` and
updated `classify_discrepancy()` to check `sub_agency` parameter. Grants from non-research
HHS sub-agencies (CMS, ACF, HRSA, SAMHSA, ACL, ASPR) are reclassified to `normal`.
The `sub_agency` column is now preserved through `.normalise_awards()` and passed into
`classify_discrepancy()` during `join_and_flag()`.

**Status:** Fixed and verified. After rebuild: HHS possible_freeze = 3 (down from 201), all 3 are
NIH research grants. 198 Medicaid/TANF/block grants correctly reclassified to `normal`.

---

## Recommended Pre-Reporting Filters

Apply these before any public-facing aggregate analysis:

```r
discrepancies_clean <- discrepancies_file_c |>
  dplyr::filter(
    award_amount < 1e9,           # DQ-01: exclude umbrella grants
    outlay_ratio >= 0,            # DQ-05: exclude clawbacks
    outlay_ratio <= 1.5,          # DQ-04: exclude over-disbursed
    action_date >= as.Date("2020-01-01")  # DQ-07: recent awards only
  )

# For per-grant financial claims — exact matches only
discrepancies_exact <- discrepancies_clean |>
  dplyr::filter(match_method == "exact")
```
