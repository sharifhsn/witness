# Grant Witness PoC — Capability Tracker

## Mission

Demonstrate to Grant Witness that I can **find data they don't have** and build
production-grade data pipelines in their exact stack (R, targets, httr2, rvest,
tidyverse, assertr, PostgreSQL, GitHub Actions).

## Scorecard: Does This PoC Demonstrate Value?

### Novel Data Contributions (What GW Doesn't Have)

| # | Contribution | Status | Impact | Notes |
|---|---|---|---|---|
| 1 | **NIH Institute-level breakdown** — Which NIH institutes (NIMH, NIAID, NCI, etc.) are disproportionately affected | BUILT | HIGH | GW aggregates at agency level. `scrape_nih.R` extracts `institute` from `agency_ic_fundings`. Nobody else is publishing this granularity. |
| 2 | **Obligation-outlay discrepancies** — Grants where USAspending shows money obligated but outlays stopped or are suspiciously low | BUILT | HIGH | `transform.R` computes `outlay_ratio` and flags `possible_freeze`. This is the "frozen in practice but not on paper" signal GW can't detect from status fields alone. |
| 3 | **Active-despite-terminated detection** — Grants GW marks as terminated but USAspending still shows active outlays | BUILT | HIGH | `flag_active_despite_terminated` in `transform.R`. Direct contradiction between forensic and official data — exactly the kind of investigative finding journalists want. |
| 4 | **Untracked awards** — Grants in USAspending for tracked agencies that GW has no record of | BUILT | MEDIUM | `flag_not_in_gw` in `transform.R`. Reveals gaps in GW's coverage — grants they're missing entirely. |
| 5 | **NSF directorate-level analysis** — Which NSF directorates (MPS, EDU, CSE) are hit hardest | BUILT | MEDIUM | `scrape_nsf.R` preserves `directorate` field. GW has this column but doesn't break it down in weekly reports. |
| 6 | **Cross-agency institution analysis** — Same institutions hit across NIH + NSF simultaneously | PLANNED | HIGH | `org_name` is captured from both sources. A `group_by(org_name)` across the bound dataset would reveal multi-agency impact on single institutions. Not yet implemented as a target. |
| 7 | **Agencies beyond Big 5** — DOE, USDA, ED grant disruptions | READY | HIGH | `fetch_usaspending.R` accepts any agency name. Just needs parameter change to add DOE/USDA/ED. GW tracks zero data for these agencies. |
| 8 | **Transaction-level payment timelines** — When exactly did money stop flowing | PLANNED | MEDIUM | USAspending `/api/v2/transactions/` endpoint documented but not yet scraped. Would show payment-by-payment history. |
| 9 | **Funding curves for all agencies** — GW only does NIH funding curves | PLANNED | MEDIUM | NIH Reporter API data could generate FY-by-FY award curves. Extend to NSF/EPA. |
| 10 | **10 automated data quality flags** — CFDA-agency validation, state codes, grant number format, international detection, source concordance | BUILT | HIGH | `validate_notices()` and `validate_awards()` now produce 10 flags surfaced in the Parquet output and QA log. |
| 11 | **Elapsed ratio + freeze severity chart** — Time-aware freeze triage: 150 grants >80% elapsed with <10% outlay | BUILT | HIGH | `elapsed_ratio` in `join_and_flag()` output; `plot_freeze_severity()` new visualization. Methodological improvement over GW's binary $100 threshold. |
| 12 | **Source concordance flag** — Amount discrepancy between forensic notice and USAspending on exact matches | BUILT | MEDIUM | `flag_amount_mismatch` in `join_and_flag()`. Found 24 cases (4.9%) with >25% disagreement. See Plan B for UI extension. |

**Score: 7 BUILT / 1 READY / 1 PLANNED** *(updated 2026-03-11)*

---

### Technical Stack Match (Job Requirements vs. PoC)

| Requirement (from apply.html) | PoC Implementation | Status |
|---|---|---|
| **R** | Entire codebase is R (~1,200 lines across 6 modules) | DEMONSTRATED |
| **targets framework** | `_targets.R` with 8 wired targets: scrape → validate → join → export | DEMONSTRATED |
| **Web scraping** | `httr2` + `rvest` for NIH API, NSF CSV, USAspending API | DEMONSTRATED |
| **Git / GitHub / GitHub Actions** | `.github/workflows/targets.yaml` with renv restore + weekly tar_make() | BUILT |
| **PostgreSQL** | DBI + RPostgres in package list; export target uses Parquet (swap to PG trivially) | SCAFFOLDED |
| **AirTable** | Not yet — could add Airtable API read of GW's existing data | NOT STARTED |
| **S3 cloud storage** | arrow::write_parquet to S3 trivial; output target writes local Parquet | SCAFFOLDED |
| **Design automated data pipelines** | Full pipeline: scrape → validate → join → flag → export | DEMONSTRATED |
| **Analyze federal spending data** | USAspending API integration with discrepancy detection | DEMONSTRATED |
| **Public-facing visualizations** | Not yet — need at least one plot/table output | NOT STARTED |
| **Respond to urgent requests** | Pipeline designed for re-runs via `tar_make()` | DEMONSTRATED |

**Score: 7/10 demonstrated or built, 2 scaffolded, 1 not started**

---

### Code Quality Indicators

| Metric | Status | Notes |
|---|---|---|
| Roxygen2 documentation | ALL public functions documented | Consistent @param, @return, @export |
| assertr validation | 2 validation functions enforcing schema | `validate_notices()`, `validate_awards()` |
| Error handling | All scrapers handle failures gracefully | tryCatch with logging, graceful degradation |
| Rate limiting | Global throttle via `build_request()` | 1 req/2 sec, exponential backoff |
| testthat tests | COMPLETE | 230 tests covering all 7 modules; regression guards for 10 past bug classes |
| Code style | tidyverse idiomatic | Pipe operators, dplyr verbs, purrr::map |
| Reproducibility | renv + targets | `.Rprofile` sources renv, `_targets.R` caches results |
| CI/CD | GitHub Actions workflow | Weekly schedule + manual dispatch |

---

## Gap Analysis: What's Still Missing

### HIGH priority

- [ ] **Cross-agency institution analysis** — `group_by(org_name)` across NIH + NSF to show institutions hit simultaneously across agencies (see Plan C, requires grant structure research first)
- [ ] **Add DOE/USDA/ED to USAspending fetch** — trivial parameter change; `fetch_usaspending.R` already accepts any agency name vector
- [ ] **Transaction-level payment scraper** — `/api/v2/transactions/` endpoint for payment-by-payment history (required for Plan A heuristic training)
- [ ] **NIH award_notice_number field** — investigate if this maps to USAspending FAIN; if so, replaces fuzzy join with exact for NIH grants entirely

### MEDIUM priority

- [ ] **PostgreSQL integration** — swap Parquet export for PG write (DBI + RPostgres already in scope)
- [ ] **Funding curves replication** — reproduce GW's NIH funding curve methodology, extend to NSF/EPA
- [ ] **Discrepancy UI** — surface `flag_amount_mismatch` and other quality flags in a Shiny/Quarto interface (see Plan B)

### LOW priority

- [ ] **SAMHSA/CDC scrapers** — complete the Big 5 coverage; GW has no published methodology for either
- [ ] **Scheduled monitoring** — delta scraping via NIH Reporter API to detect new terminations without full re-scrape
- [ ] **Airtable API integration** — read GW's data as ground truth for Plan A training set construction

---

## Research Roadmap

These are the next-stage directions — each requires investigation before implementation.

---

### Plan A: Evidence-Based Frozen Grant Heuristic

**Current state:** The freeze detector uses a single threshold — `outlay_ratio < 10%` on an active award. This is a heuristic with no empirical grounding. Grant Witness's own method uses `< $100 outlays in the freeze period`, also a threshold without a validated training set.

**The plan:** Build a labeled dataset of *confirmed* frozen grants by mining open sources where experts or whistleblowers have named specific grants as frozen. Then analyze what their USAspending signatures look like to calibrate the detector against reality instead of intuition.

**Where to find confirmed frozen grants:**
- Science.org, Nature News, STAT News — reporters who name specific grant numbers in termination stories
- Congressional testimony transcripts — researchers who testified before committees often cite their own grant numbers
- University press releases — institutions like Columbia, Harvard, and UNC have publicly named affected grants
- Twitter/X threads from PIs — "#NIHGrants frozen" threads frequently include award numbers
- AAAS, Federation of American Societies for Experimental Biology (FASEB) public statements
- Legal filings in *Massachusetts v. RFK Jr.*, *APHA v. NIH*, *Thakur v. Trump* — exhibit lists contain grant IDs

**Analysis once the training set exists:**
- Compare `outlay_ratio`, `elapsed_ratio`, and transaction frequency distributions for confirmed-frozen vs. control grants
- Look for leading indicators: does transaction frequency drop *before* official termination date? Does it drop suddenly or gradually?
- The transaction-level USAspending endpoint (`/api/v2/transactions/`) would be essential here — payment-by-payment history rather than the aggregate outlay we use now
- Calibrate `FREEZE_RATIO_THRESHOLD` against the training set empirically rather than picking 10% arbitrarily
- Potential: a logistic regression or random forest on these features, producing a probability-of-freeze score rather than a binary flag

**Why this matters:** A probability score instead of a binary flag would let the UI surface "likely frozen" grants even when they don't yet cross the threshold — giving earlier warning.

---

### Plan B: Cross-Source Discrepancy UI

**Current state:** `flag_amount_mismatch` identifies 24 exact-matched grants where the termination notice and USAspending disagree on award amount by >25% (largest gap: 2.5×). Other discrepancies captured: `flag_date_inverted`, `flag_negative_outlay`, `flag_cfda_mismatch`, `flag_over_disbursed`. These flags exist in the Parquet output but are not surfaced anywhere.

**The plan:** Make discrepancies a first-class UI element, not a footnote in a data pipeline log.

**Proposed UI treatment:**
- On any grant detail page, show a "Source Discrepancy" badge next to affected fields
- Color band by severity: >10% = yellow warning, >25% = orange, >50% = red
- Tooltip explaining both values: "Notice reports $1.7M; USAspending reports $680K — possible different performance periods or reporting error"
- Link to both raw source records so a journalist or researcher can investigate directly
- Aggregate view: a "Data Quality" tab listing all flagged grants with sortable severity, agency, and flag type columns

**Beyond amounts — other discrepancies worth surfacing:**
- `flag_date_inverted`: end date before start date — suggests a data entry error at the agency level
- `flag_over_disbursed`: outlays exceed award amount — might indicate unreported modifications or USAspending lag
- `flag_future_date`: 37 awards with future start dates — not errors, but worth labeling "scheduled, not yet active" so users don't misinterpret them as current frozen grants
- `flag_cfda_mismatch`: CFDA prefix inconsistent with awarding agency — rare but when it appears, it's likely a miscategorized grant

**Why this matters:** Grant Witness's authors have explicitly stated "the government has often provided incorrect and shifting information." The UI currently hides that uncertainty — discrepancy indicators make it explicit and give researchers the raw material to investigate further.

---

### Plan C: Per-IC Granularity (Requires Grant Structure Research First)

**Current state:** The pipeline extracts institute abbreviation (`NIAID`, `NCI`, `NIGMS`, etc.) from NIH Reporter's `agency_ic_fundings` field. The institute bar chart is already implemented. But "IC" is not a simple concept.

**What needs to be understood before building further:**

NIH grant numbers encode structure: `5R01AI123456-01` breaks down as:
- `5` — type code (new vs. renewal)
- `R01` — activity code (research project grant)
- `AI` — institute code (NIAID)
- `123456` — serial number
- `01` — support year

A single research project can have: a parent grant, multiple supplements (same grant number with suffix), and subawards to collaborating institutions. Grant Witness documents that they track these separately in USAspending but count them under a single identifier. The IC in `agency_ic_fundings` reflects the *primary funder*, but multi-IC grants exist (e.g., two ICs co-fund a single award).

**Questions to answer before deeper IC analysis:**
1. What fraction of NIH grants in our dataset are multi-IC funded? (If it's >10%, per-IC dollar totals double-count)
2. Do activity codes (R01, P01, U01, F31, K99) cluster differently across institutes in the termination data? (A disproportionate termination of F-series training grants would hit early-career researchers harder than senior PIs)
3. What is the relationship between our `grant_number` (project_num from NIH Reporter) and USAspending's FAIN? They use different identifier formats — NIH project numbers are not FAINs, which is why exact matching works only for NSF (which uses the same award number in both systems)

**Planned additions once structure is understood:**
- Activity code field and flag: distinguish research grants (R01, P01) from training grants (F31, K99) and career awards (K-series)
- Multi-IC indicator: flag grants with multiple funding sources so IC-level dollar totals aren't misleading
- `institute_disruption_score`: for each IC, the ratio of disrupted grants to total active grants (not just raw count) — gives a better sense of which institutes are proportionally most affected

---

### Note on Fuzzy Matching

The fuzzy join (org name + date proximity) is a fallback strategy, not a primary analysis tool. It exists because NIH project numbers and USAspending FAINs are different identifiers — there is no shared key to join on for NIH grants. For NSF, exact matching works well because NSF uses the same 7-digit award ID in both systems.

The fuzzy join has known limitations: even after tightening the Jaro-Winkler threshold to 0.08 and adding the distinctive-token filter, it connects *different grants from the same organization at similar times*, not the *same grant* in two databases. This means the `active_despite_terminated` flag on a fuzzy match is a weaker signal than the same flag on an exact match.

**Long-term direction:** The right solution is a shared identifier. NIH Reporter does expose a FAIN-like field (`award_notice_number`) that may map to USAspending FAIN — that's worth investigating. If it does, we can replace the fuzzy join with an exact join for NIH grants, which would make the entire cross-reference more defensible.

---

## Key Selling Points for Application

1. **"I found data you don't have."** — Institute-level NIH breakdowns, obligation-outlay discrepancies, untracked awards across your five agencies, and potential coverage of agencies you don't track yet (DOE, USDA, ED).

2. **"I built it in your exact stack."** — R, targets, httr2, assertr, GitHub Actions. Not a Python prototype that needs translating.

3. **"The pipeline finds contradictions."** — The discrepancy flagger identifies grants that are terminated on paper but still flowing money, and grants that should be active but have suspicious payment gaps. This is forensic analysis, not just data collection.

4. **"It extends your methodology."** — Your funding curves are NIH-only. Your weekly reports don't break down by NIH institute or NSF directorate. Your coverage stops at 5 agencies. This PoC addresses all three gaps.

5. **"It's production-ready."** — Validated schemas, error handling, rate limiting, CI/CD, Parquet export, Roxygen docs, testthat tests. Not a notebook — a pipeline.

---

## File Inventory

```
witness/
├── SEED.md                          # Original project directive
├── TRACKER.md                       # THIS FILE — progress tracking
├── .Rprofile                        # renv activation
├── .gitignore                       # R/targets/OS exclusions
├── witness.Rproj                    # RStudio project config
├── _targets.R                       # Pipeline: 8 targets wired
├── R/
│   ├── utils.R              (98 L)  # build_request, parse_date_flexible, %||%, safe_text, log_event
│   ├── validate.R           (58 L)  # validate_notices, validate_awards (assertr)
│   ├── scrape_nih.R        (205 L)  # NIH Reporter API (paginated POST, institute extraction)
│   ├── scrape_nsf.R        (211 L)  # NSF CSV download + currency parsing
│   ├── fetch_usaspending.R (263 L)  # USAspending API (multi-agency, paginated)
│   └── transform.R        (356 L)  # Exact/fuzzy join + 4 discrepancy flags + summary
├── tests/
│   ├── testthat.R                   # Test runner
│   └── testthat/                    # Unit tests (in progress)
├── docs/
│   ├── recon_briefing.md            # Phase 1 strategic briefing
│   ├── NIH_SCOUT_REPORT.md          # NIH recon findings
│   ├── NIH_API_SCHEMA.json          # NIH API request/response schema
│   ├── NIH_API_EXAMPLES.sh          # Executable API examples
│   └── README_NIH_SCOUT.md          # NIH quick reference
└── .github/
    └── workflows/
        └── targets.yaml             # Weekly CI with renv + tar_make
```

**Total R code: ~1,191 lines across 6 modules**

---

*Last updated: 2026-03-11*
