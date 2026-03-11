# Phase 1 Strategic Briefing: Reconnaissance Results

## Executive Summary

Nine reconnaissance scouts were deployed across the Grant Witness ecosystem and
five federal agency data landscapes. The findings reveal a clear strategy for the
PoC: **focus on data Grant Witness does not yet have**, demonstrating forensic
analysis capability that complements their existing coverage.

Grant Witness already maintains comprehensive termination/reinstatement tracking
for NIH, NSF, EPA, SAMHSA, and CDC via curated Airtable databases, CSV exports,
and crowdsourced researcher submissions. The highest-value PoC contribution is
therefore **novel data discovery** — finding signals, agencies, and granularity
levels they currently miss.

## Grant Witness Current Coverage

### Data Model (per agency)
- **Status tracking**: terminated, frozen, reinstated, at-risk (emoji-coded)
- **Provenance flags**: hhs_web_reported, hhs_pdf_reported, self_reported, court_reported
- **Financial**: award amounts, outlays, estimated remaining
- **Geographic**: org_state, org_city, congressional district, US representative
- **External links**: usaspending_url, taggs_url, reporter_url

### Infrastructure
- Quarto static site + Airtable backend + S3-hosted CSV/JSON exports
- 5 agency data pages (identical template)
- 24 weekly reports, 20 updates posts
- Choropleth maps with state-level disruption metrics
- Funding curves (NIH only, FY 2021-2026)

### Known Limitations (from their Methods page)
- Cumulative figures may not match when termination/reinstatement dates missing
- Multiple disruption cycles affect grant counts
- Frozen grant detection criteria actively being refined (as of Feb 2026)

## Priority Scraper Targets (Ranked by Novel Value)

### Tier 1: Direct API/CSV Sources (Trivial to Scrape)

#### 1. NIH Reporter API v2
- **URL**: `POST https://api.reporter.nih.gov/v2/projects/search`
- **Auth**: None
- **Rate limit**: 1 req/sec recommended
- **Data volume**: 170,620+ terminated projects (2024-2026)
- **Novel value**: Institute-level granularity (NIMH, NIAID, NCI, etc.), continuous
  monitoring for status changes between GW snapshot dates, `date_added` field for
  detecting when terminations entered the database
- **Key fields**: `is_active`, `project_end_date`, `date_added`, `award_amount`,
  `direct_cost_amt`, `organization.org_name`, `organization.org_state`

#### 2. NSF Terminated Awards CSV
- **URL**: `https://nsf-gov-resources.nsf.gov/files/NSF-Terminated-Awards.csv`
- **Auth**: None (S3/CloudFront, ~334 KB)
- **Data volume**: 1,667 terminated awards
- **Novel value**: Directorate-level analysis (MPS, EDU, CSE, etc.) — GW has the
  field but doesn't break down weekly reports by directorate
- **Key fields**: Award ID, Directorate, Recipient, Title, Obligated amount

#### 3. USAspending API v2
- **URL**: `POST https://api.usaspending.gov/api/v2/search/spending_by_award/`
- **Auth**: None
- **Pagination**: Max 5,000 records/page
- **Novel value**: Transaction-level forensics — obligation vs outlay timelines
  showing *when* money stopped flowing, not just final status. Covers ALL ~120
  federal agencies (not just GW's Big 5).
- **Key agency codes**: HHS (075), EPA (068), NSF (049), DOE (089), USDA (012), ED (091)
- **Freeze detection**: Awards with obligations > 0 but no recent action_date
- **Bulk download**: `POST /api/v2/bulk_download/awards/` returns zipped CSVs

### Tier 2: Structured but Requires Parsing

#### 4. EPA Newsroom (Grants Subject Filter)
- **URL**: `https://www.epa.gov/newsreleases/search?f[0]=subject:226199`
- **CMS**: Drupal 10, results loaded via AJAX
- **Challenge**: JavaScript-rendered results; may need rendered HTML
- **Novel value**: Press release text mining for freeze/termination language
  before formal status changes appear in databases

#### 5. NSF Updates on Priorities
- **URL**: `https://www.nsf.gov/updates-on-priorities`
- **Structure**: Drupal 10 layout builder, FAQ anchors
- **Novel value**: Policy announcements (IDC caps, reinstatement events) with
  exact dates — timeline reconstruction

#### 6. HHS TAGGS (Tracking Accountability in Government Grants System)
- **URL**: `https://taggs.hhs.gov`
- **Coverage**: All 12 HHS Operating Divisions since 1995
- **Data**: Transaction-level obligated grant funds
- **Novel value**: Historical baseline for HHS grant activity; pre-2025 comparison

### Tier 3: Lower Priority / Higher Difficulty

#### 7. EPA FOIA Reading Room (FOIAXpress)
- **URL**: `https://foiapublicaccessportal.epa.gov`
- **Tech**: ASP.NET, requires session management
- **1.8M records** but unsearchable without specific queries

#### 8. SAM.gov Suspension/Debarment
- **URL**: `https://sam.gov/content/assistance-listings`
- **Tech**: JavaScript-heavy reactive search
- **Covers**: Entities barred from federal funding (different from terminations)

## Recommended PoC Scraper Architecture

### Scrapers to Build (Phase 3)

| Module | Source | Method | Novel Contribution |
|--------|--------|--------|--------------------|
| `scrape_nih.R` | NIH Reporter API | POST JSON | Sub-institute breakdown, continuous monitoring |
| `scrape_nsf.R` | NSF CSV | GET + read.csv | Directorate-level analysis |
| `fetch_usaspending.R` | USAspending API | POST JSON | Transaction timelines, agencies beyond Big 5 |
| `scrape_epa_news.R` | EPA Newsroom | GET + rvest | Press release text mining |
| `transform.R` | All sources | dplyr joins | Cross-agency institution analysis |

### Cross-Reference Strategy
1. Pull GW existing CSVs as ground truth
2. Query NIH Reporter for terminated projects NOT in GW dataset
3. Query USAspending for obligation/outlay timelines on GW-tracked grants
4. Flag discrepancies: GW says "terminated" but USAspending shows recent outlays
5. Identify grants disrupted at agencies GW doesn't track (DOE, USDA, ED)

## Technical Notes

### Rate Limiting Strategy
- NIH Reporter: 1 req/sec, large jobs on weekends or 9PM-5AM EST
- USAspending: No documented limits, use 1 req/2 sec to be polite
- NSF CSV: Single GET, no rate concern
- EPA Newsroom: 1-2 sec delays between pages

### Data Volume Estimates
- NIH: ~170K records (paginate at 500/page = ~340 requests)
- NSF: ~1,667 records (single file)
- USAspending: Variable; bulk download for large queries
- EPA News: ~50-100 grants-tagged press releases

### Pagination Patterns
- NIH Reporter: `offset` + `limit` (max 500)
- USAspending: `page` + `limit` (max 5,000)
- EPA News: Client-side (AJAX)
