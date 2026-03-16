# Grant Witness PoC — Claude Context

## Project Purpose

R data pipeline that cross-references federal grant termination data with USAspending.gov to surface discrepancies. Built as a job-application PoC targeting a Data Scientist role at [Grant Witness](https://grant-witness.us/).

## Pipeline

```
notices_nih ──┐
               ├─ validated_notices ─┐
notices_nsf ──┘                      │
                                     ├─ discrepancies ─┬─ transaction_data
usaspending_awards ─ validated_awards ┘                 ├─ discrepancies_enriched
                                                        ├─ file_c_data ─── file_c_features
                                                        ├─ discrepancies_file_c
                                                        ├─ discrepancy_summary
                                                        ├─ plot_files
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
| Possible Freeze (confirmed) | 4,660 |
| Possible Freeze (no data) | 280 |
| Untracked | 11,310 |

## R Modules (R/ directory, ~4,200 lines total across 14 files)

| File | Lines | Purpose |
|---|---|---|
| utils.R | 89 | `build_request()`, `parse_date_flexible()`, `log_event()` |
| validate.R | 163 | `validate_notices()`, `validate_awards()` — assertr schemas |
| scrape_nih.R | 199 | NIH Reporter API v2 paginated scraper |
| scrape_nsf.R | 205 | NSF Terminated Awards CSV parser |
| fetch_usaspending.R | 556 | USAspending.gov award + transaction + subaward fetcher |
| fetch_file_c.R | 260 | USAspending File C fetcher — period-by-period outlays via `/api/v2/awards/funding/` |
| fetch_treasury.R | 248 | Treasury Fiscal Data MTS Table 5 fetcher |
| fetch_gw.R | 169 | Grant Witness CSV downloader + parser |
| detect_treasury_anomalies.R | 268 | Spending anomaly detection + File C cross-referencing |
| calibrate_freeze.R | 488 | Calibration analysis against GW ground truth |
| transform.R | 970 | Exact/fuzzy join, discrepancy flags, File C temporal reconstruction |
| visualize.R | 308 | 5 ggplot2 charts (GW visual style) |
| visualize_calibration.R | 285 | Calibration-specific plots |
| visualize_treasury.R | 104 | Treasury timeline + anomaly corroboration plots |
| fetch_dts.R | ~155 | Daily Treasury Statement fetcher (1-day lag, real-time withdrawal signal) |
| fetch_usaspending_budget.R | ~185 | USAspending agency budget execution (GTAS-sourced period obligations) |
| detect_obligation_drought.R | ~230 | Obligation drought + pipeline gap ("iceberg") analysis + DTS anomaly |
| visualize_obligation.R | ~175 | 4 obligation drought / pipeline gap / DTS daily charts |

## Grant Witness Terminology and Status Categories

Grant Witness uses a richer status taxonomy than our binary flags. Their categories:

**Termination statuses:**
- "Terminated" — confirmed terminated via TAGGS PDF, NIH RePORTER, DOGE, self-report, or court docs
- "Possibly Reinstated" — project date re-extended (USAspending/NGGS/File C) or court-ordered reinstatement
- "Reinstated" — "Possibly Reinstated" AND has received outlays since reinstatement

**Freeze statuses (NIH only):**
- "Frozen" — at a targeted institution, no outlays during freeze period, meets all 8 criteria (see below)
- "Possibly Unfrozen" — previously frozen, institution no longer known to be targeted, but no outlays yet
- "Unfrozen" — "Possibly Unfrozen" AND has received outlays after targeting ended

**CDC-specific:**
- "At-Risk" — grants identified as targeted for termination but not yet formally terminated

**Mapping to our `discrepancy_type` values:**
- Our `possible_freeze` roughly corresponds to their "Frozen" but is much coarser (see methodology gap below)
- Our `active_despite_terminated` has no direct GW equivalent — they don't cross-reference outlay flow against termination status
- We have no equivalents for "Possibly Reinstated", "Reinstated", "Possibly Unfrozen", or "Unfrozen"

## Grant Witness Data Sources vs. Ours

| Source | GW Uses | We Use | Notes |
|---|---|---|---|
| NIH RePORTER | Yes (scraping, not API — terminations not in API) | Yes (API) | GW scrapes web pages; terminations are not in the programmatic API |
| USAspending.gov awards | Yes | Yes | GW uses for award amounts, obligations, outlays |
| USAspending File C (monthly outlays) | Yes — core of freeze detection | No | Period-by-period outlay history; essential for their frozen grant methodology |
| HHS TAGGS PDF | Yes — periodic PDF of terminated grants | No | Could add as supplementary termination source |
| HHS TAGGS transactions | Yes — daily financial transactions | No | More granular than USAspending for HHS grants |
| NIH X feed (@NIH posts) | Yes — early detection | No | Social media monitoring |
| Doge.gov | Yes — cross-reference | No | Lists cancelled grants but often incomplete/inaccurate per GW |
| NSF Award Search | Yes | Partial (CSV only) | GW augments with NSF's own award search |
| NSF Terminated Awards CSV | Yes | Yes | Our primary NSF source |
| NGGS (EPA) | Yes | No | EPA grant tracking system; GW's primary EPA source |
| PI self-reports (Google Forms) | Yes — crowdsourced | No | Critical to GW's early detection; not reproducible |
| Court filings | Yes — reinstatement detection | No | Massachusetts v. RFK Jr., APHA v. NIH, Thakur v. Trump |
| News reports / social media | Yes | No | Supplementary verification |
| Treasury Fiscal Data (MTS Table 5) | No | Yes | Bureau-level monthly outlays with ~30 day lag; early warning signal for agency spending drops |
| Daily Treasury Statement (DTS) | No | Yes | Daily agency withdrawal line items with ~1-day lag; real-time confirmation of spending pace |
| USAspending budgetary resources (GTAS) | No | Yes | Period-by-period agency-level obligations sourced from Treasury GTAS — independent of award-level data |

## Grant Witness Frozen Grant Methodology (Critical Detail)

GW's frozen grant detection has evolved through 4+ iterations (Jun 2025 through Feb 2026). Key criteria as of Feb 2026:

1. At an institution **known** to have funding frozen (Harvard, Columbia, Brown, Cornell, Weill Cornell, Northwestern, Duke, UPenn)
2. Project end date after freeze began
3. Between targeting start and end, received only outlays < $100 (using File C period-by-period data)
4. Had total outlays of at least $100 in the 6 months prior to targeting
5. At least 20% of pre-Jan-2025 periods had positive outlays
6. Not 100% outlaid (total outlaid != total award)
7. If within 3 periods of project end, not >95% outlaid
8. Not already terminated

**Critical methodological difference from our approach:**
- GW checks whether a grant was fully paid out **at the time of institutional targeting**, not at current time. Their Feb 2026 update ("Refining our criteria") fixed a bug where grants that received additional obligations/outlays after unfreezing appeared to not be fully paid out, causing false negatives. They subtract post-freeze outlays/obligations from current totals to reconstruct the state at freeze onset.
- Our `possible_freeze` uses current `outlay_ratio < 10%` on any active award — no institution targeting requirement, no temporal reconstruction, no File C data. This is a fundamentally different (and weaker) signal.

**GW distinguishes "full freeze" vs. "partial freeze":**
- Full freeze (Columbia, Brown): all grants at institution considered frozen after targeting begins
- Partial freeze: stricter rules requiring $0 outlays during targeting period

**Duke University anomaly (as of Feb 2026):** Many Duke grants were frozen in July 2025 but some received outlays in Dec 2025 despite the institutional freeze reportedly still being in place. GW removed 116 Duke grants because they don't meet the strict "no outlays during freeze" criterion. This is an active area of investigation.

## Grant Witness Team and Job Requirements

**Team:** Noam Ross (lead), Scott Delaney, Anthony Barente, Emma Mairson, Eric Scott (Eric R. Scott), Mally Shan, plus additional volunteers.

**Data Scientist role requirements (from job posting):**
- R (primary language)
- Web scraping (httr2, rvest)
- Git / GitHub / GitHub Actions
- PostgreSQL
- Cloud services (S3, etc.)
- AirTable
- Design automated data pipelines
- Analyze federal spending data
- Create public-facing visualizations
- Respond to urgent requests (breaking news cycle)

**ML capability:** GW built a 342-class XGBoost model to predict NIH RCDC spending categories for recent grants (AUC 0.984, F1 0.804). Trained on 88K+ historical grants using grant text, institute, study section, and CFDA code.

## Agencies Tracked

| Agency | GW Tracks | We Track | Notes |
|---|---|---|---|
| NIH | Yes | Yes | GW's most mature tracker |
| NSF | Yes | Yes | |
| EPA | Yes | Yes (USAspending only) | GW uses NGGS + USAspending + DOGE + self-reports |
| SAMHSA | Yes (since Jan 2026) | No | 2,700+ grants terminated Jan 13 2026, $2B+; most reinstated within 24h |
| CDC | Yes (since Feb 2026) | No | $730M+ in grants to CA, MN, CO, IL; includes "at-risk" category |
| DOE | No | No (READY to add) | |
| USDA | No | No (READY to add) | |
| ED | No | No (READY to add) | |

## USAspending API Contracts (authoritative schema source)

**API Blueprint contracts** (field-level schemas for every endpoint, confirmed authoritative):
```
https://github.com/fedspendingtransparency/usaspending-api/tree/master/usaspending_api/api_contracts/contracts/v2/
```
No Swagger/OpenAPI exists. Each endpoint is a `.md` file with embedded JSON Schema.
Raw contract URL pattern: `https://raw.githubusercontent.com/fedspendingtransparency/usaspending-api/master/usaspending_api/api_contracts/contracts/v2/{endpoint_path}.md`

Key contracts:
- `search/spending_by_award.md` — complete `fields` list and AdvancedFilterObject schema
- `search/spending_by_transaction.md` — all requestable transaction fields
- `search/spending_by_category.md` — 18 category types, correct request schema
- `awards/funding.md` — File C complete response field list
- `reporting/agencies/overview.md` — data quality fields

---

## Critical API Constraints

- **NIH Reporter**: Hard offset cap at 14,999. Use `req_body_json()` not `req_body_raw(toJSON(...))` (fails in callr).
- **USAspending Awards**: Hard page cap at 100. Date fields are `"Start Date"` / `"End Date"` (NOT "Period of Performance...").
- **USAspending Transactions**: `/api/v2/search/spending_by_transaction/` — page cap 100, same rate limits. Filter by `award_ids` list.
- **USAspending File C**: `POST /api/v2/awards/funding/` — period-by-period outlay data per award. Requires `generated_internal_id` (NOT plain Award ID). Format: `ASST_NON_{award_id}_{agency_CGAC_code}`. Agency codes: HHS=075, NSF=049, EPA=068. Returns `gross_outlay_amount` and `transaction_obligated_amount` per `reporting_fiscal_year`/`reporting_fiscal_month`. **CRITICAL**: `reporting_fiscal_month` is the FISCAL month (1=Oct, 2=Nov, ..., 4=Jan, ..., 12=Sep), NOT the calendar month. Convert with `calendar_month = ((fiscal_month + 8) %% 12) + 1`; fiscal months 1-3 (Oct-Dec) fall in `fiscal_year - 1`. Same pagination as other endpoints (hasNext, page cap ~100). Fetched in `R/fetch_file_c.R`.
- **NSF CSV**: Latin-1 encoding — must `iconv()` before parsing.
- **Treasury MTS Table 5**: GET endpoint, no auth. Page size up to 10,000 (default 100). Filter syntax: `?filter=field:eq:value`. Pagination via `page[number]` and `page[size]`. Response includes `meta.total-pages`. `classification_desc` is hierarchical text, not a code. HHS sub-agencies (NIH, CDC, etc.) have direct outlay data at `record_type_cd="B"`. Independent agencies (NSF, EPA) are headers with `null` outlays — actual totals are in `"Total--{name}"` rows at `record_type_cd="C"`. The API returns string `"null"` (not JSON null) for missing amounts. `record_calendar_month` is calendar month (1-12), while fiscal year starts in October.
- **Daily Treasury Statement (DTS)**: GET endpoint at `https://api.fiscaldata.treasury.gov/services/api/fiscal_service/v1/accounting/dts/deposits_withdrawals_operating_cash`. Same Treasury API pattern as MTS (same `.treasury_get()` helper). Amounts in **millions of dollars**. Amount fields: `transaction_today_amt`, `transaction_mtd_amt`, `transaction_fytd_amt`. **DO NOT** use `:in:()` filter on `transaction_catg` — commas in category names (e.g., "HHS - National Institutes of Health") conflict with the API filter separator. Always fetch with `transaction_type:eq:Withdrawals` and post-filter in R.
- **USAspending budgetary_resources (GTAS)**: `GET /api/v2/agency/{toptier_code}/budgetary_resources/`. **Use toptier_code, NOT agency_id**: HHS=`075`, NSF=`049`, EPA=`068`. Returns ALL fiscal years at once in `agency_data_by_year` list — no `fiscal_year` param needed. Period obligation data is in `agency_obligation_by_period` (NOT `obligations_by_period`). Fiscal period 1=Oct, 2=Nov, ..., 12=Sep. This is GTAS-certified Treasury data, independent of award-level USAspending data. Implemented in `R/fetch_usaspending_budget.R` using `.usaspending_get()` (GET helper, not `.usaspending_post()`).
- **USAspending spending_over_time**: `POST /api/v2/search/spending_over_time/` with `"group": "month"`. **CRITICAL**: `month` field in response = FISCAL month (1=Oct, 2=Nov, ..., 12=Sep), same convention as File C. NOT calendar month. Do NOT confuse with MTS `record_calendar_month`. Confirmed empirically: query for Oct–Dec 2024 returns `fiscal_year: "2025"`, `month: "1"`, `"2"`, `"3"`. Valid `group` values: `"month"`, `"quarter"`, `"fiscal_year"`, `"calendar_year"` (NOT `"fiscal_month"`). `new_awards_over_time` endpoint is NOT usable for agency-level queries — requires `recipient_id` param. Use `spending_over_time` instead. Implemented via `fetch_award_obligations_flow()` in `R/fetch_usaspending_budget.R`.
- **USAspending spending_by_category**: **CRITICAL**: category goes in the URL PATH, NOT the request body. Correct: `POST /api/v2/search/spending_by_category/cfda/`. Wrong: `POST /api/v2/search/spending_by_category/` with `{"category": "cfda"}` (returns 404). 18 valid categories: `cfda`, `awarding_subagency`, `funding_subagency`, `state_territory`, `federal_account`, `program_activity`, `object_class`, `defc`, `naics`, `psc`, etc. `spending_level` param: `"transactions"` (default), `"awards"`, `"subawards"`, `"award_financial"`. Filter is standard AdvancedFilterObject but `keywords` field is optional despite contract docs suggesting otherwise. Implemented via `fetch_cfda_breakdown()` in `R/fetch_usaspending_budget.R`.
- **USAspending reporting/agencies/overview**: `GET /api/v2/reporting/agencies/overview/?fiscal_year=YYYY&fiscal_period=N`. fiscal_period 2–12 (P1 often not submitted). Returns: `recent_publication_date`, `recent_publication_date_certified` (bool), `unlinked_assistance_award_count`, `obligation_difference` (File A vs File B). Verified: NSF FY2026 P4 last published 2026-03-03, not certified, $0 obligation difference, 12 unlinked assistance awards. Implemented via `check_data_quality()` in `R/validate.R`.

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

`tests/testthat/test-parsers.R` — ~184 test blocks, 450+ assertions covering 13 of 18 modules (visualize*.R untested) + regression guards for the 10 bug classes above.

## Next Priorities (from TRACKER.md)

**HIGH**
- SAMHSA + CDC scrapers (GW already tracks both; we should too)
- ~~USAspending File C integration~~ DONE — `fetch_file_c.R` + temporal reconstruction + Treasury corroboration
- ~~Obligation drought analysis~~ DONE — `fetch_dts.R` + `fetch_usaspending_budget.R` + `detect_obligation_drought.R` + `visualize_obligation.R`
- Reinstatement tracking (GW's "Possibly Reinstated" / "Reinstated" statuses)
- Cross-agency institution analysis (`group_by(org_name)` across NIH + NSF)

**MEDIUM**
- ~~Temporal freeze reconstruction~~ DONE — `compute_file_c_features()` with targeting dates
- PostgreSQL export (DBI + RPostgres — interface designed, just needs `DATABASE_URL`)
- Overdue funding detection (GW tracks grants >60 days overdue for new Notice of Award)
- Discrepancy UI (Shiny/Quarto surfacing `flag_amount_mismatch`)

**LOW**
- Add DOE/USDA/ED to `fetch_usaspending.R` (trivial parameter change; GW doesn't track these)
- HHS TAGGS integration (supplementary termination source)
- Spending category prediction (ML model, GW already has this)

## Output

- `output/discrepancies.parquet` — full joined dataset
- `output/*.png` — 5 plots (institute bars, discrepancy summary, outlay scatter, freeze severity, state map)
