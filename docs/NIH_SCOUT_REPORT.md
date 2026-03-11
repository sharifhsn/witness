# Scout Report: NIH Grant Termination/Suspension Tracking

**Date:** 2026-03-10
**Objective:** Identify pages and APIs publishing grant terminations, funding freezes, award modifications, and access methods for programmatic retrieval.

**Crawled URLs:**
- https://api.reporter.nih.gov/ (API documentation & endpoints)
- https://reporter.nih.gov/ (web interface, JavaScript-heavy)
- https://reporter.nih.gov/exporter/ (bulk export)
- https://www.nih.gov/news-events/news-releases (press releases)
- https://grants.nih.gov/grants/ (funding hub)
- https://grants.nih.gov/searchguide/ (NIH Guide search)
- https://www.nih.gov/institutes-nih/nih-office-director/office-communications-public-liaison/freedom-information-act-office (FOIA)

---

## Key Findings

### PRIMARY DATA SOURCE: NIH Reporter API v2

**URL Structure:**
- API Base: `https://api.reporter.nih.gov/`
- Documentation: `https://api.reporter.nih.gov/docs/API`
- Project Search Endpoint: `POST https://api.reporter.nih.gov/v2/projects/search`
- Publication Search Endpoint: `POST https://api.reporter.nih.gov/v2/publications/search`

**Access Method:**
```bash
curl -X POST "https://api.reporter.nih.gov/v2/projects/search" \
  -H "Content-Type: application/json" \
  -d '{
    "criteria": {
      "include_active_projects": false,
      "project_end_date": {
        "from_date": "2024-01-01",
        "to_date": "2026-03-10"
      }
    },
    "offset": 0,
    "limit": 500
  }'
```

**Response Format:** JSON with pagination metadata

**Rate Limiting:**
- X-Rate-Limit-Limit: 1m (per minute)
- X-Rate-Limit-Remaining: (count)
- X-Rate-Limit-Reset: (timestamp)
- Recommended: ≤1 request/second; large jobs weekends or 9PM-5AM EST

---

## Grant Status Tracking Fields

### Identifying Terminated/Inactive Grants

| Field | Type | Purpose | Example |
|-------|------|---------|---------|
| `is_active` | boolean | Current grant status | `false` for ended grants |
| `project_end_date` | ISO 8601 | End date of award period | `2025-04-30T00:00:00` |
| `project_start_date` | ISO 8601 | Award start date | `2022-05-01T00:00:00` |
| `award_notice_date` | ISO 8601 | Date award was notified | `2023-04-07T00:00:00` |
| `budget_end` | ISO 8601 | Current budget period end | `2024-04-30T00:00:00` |
| `date_added` | ISO 8601 | When added to Reporter DB | `2023-05-04T16:18:27` |
| `fiscal_year` | integer | Fiscal year of award | `2023` |
| `award_amount` | decimal | Total award value | `71792` |
| `project_num` | string | Unique project identifier | `5F32DK132864-02` |

### No Direct Termination Reason Field
- API does not expose "termination reason" or "suspension cause"
- Must infer status from `is_active: false` combined with date fields
- For specific termination reasons, institutional records or FOIA requests needed

---

## API Search Criteria for Finding Terminated Grants

**Endpoint:** `POST /v2/projects/search`

**Payload Parameters:**

| Criteria | Type | Usage | Example |
|----------|------|-------|---------|
| `include_active_projects` | boolean | Restrict to inactive only | `false` |
| `project_end_date` | object | Date range filtering | `{"from_date": "2024-01-01", "to_date": "2026-03-10"}` |
| `fiscal_years` | array | Filter by FY | `[2024, 2025]` |
| `project_nums` | array | Search specific grant | `["5R01AI178795-11"]` |
| `award_notice_date` | object | Filter by award date | `{"from_date": "2024-01-01"}` |
| `award_amount_range` | object | Filter by funding amount | `{"min_amount": 0, "max_amount": 50000000}` |
| `agencies` | array | Filter by agency (IC) | `["NIAID", "NCI"]` |
| `activity_codes` | array | Filter by award type | `["R01", "F32", "R35"]` |
| `org_names` | array | Filter by institution | `["HARVARD UNIVERSITY"]` |
| `date_added` | object | Filter by when added to DB | `{"from_date": "2026-02-01"}` |

**Response Parameters:**
- `offset`: Starting record (0-14999 max)
- `limit`: Records per request (1-500, default 50)
- `sort_field`: Field to sort by
- `sort_order`: "asc" or "desc"

**Test Result:**
```
Query: inactive projects ending 2024-2026
Total results: 170,620 projects
Sample project: F32DK132864-02 (ended 2025-04-30, is_active: false)
```

---

## Complete Project Record Example

Field groups returned in API response:

**Project Details:**
- IC code, Support Year, Application Type, Activity Code
- Serial Number, Suffix Code, Project Number, Core Project Number
- Project Start/End Dates, Sub-Project ID
- Abstract, Title, Public Health Relevance, RCDC Terms
- Project Detail URL

**Study Section Information:**
- SRG Code, SRG Flex, SRA Designator, Study Section Name

**Personnel:**
- Principal Investigators (profile IDs, names, contact PI flag)
- Program Officers

**Organization:**
- Organization Name, City, State, Country
- Organization Type, Department, DUNS, UEI
- Congressional District, FIPS code, ZIP code

**Funding Information:**
- Award Notice Date, Fiscal Year, Opportunity Number
- Award Amount, Direct/Indirect Costs
- Funding Mechanism, Budget Start/End Dates
- CFDA Code, COVID-19 Response flags, ARRA Indicator

---

## Web Interface & Bulk Download

**GUI Interface:** https://reporter.nih.gov/ and https://reporter.nih.gov/exporter/
- Heavily JavaScript-dependent
- Not suitable for automated crawling
- Provides interactive search and CSV export
- Qualtrics survey integration (analytics)

**Search Results Sharing:**
- Format: `https://reporter.nih.gov/search/{search_id}/projects`
- Example: `https://reporter.nih.gov/search/OPA7dNOqHEiL1iswi7sX1A/projects`
- Allows sharing specific filtered result sets

---

## NIH Press Releases (Secondary Source)

**URL:** https://www.nih.gov/news-events/news-releases

**Structure:**
- Pagination: 182 pages of releases (2018-2026 available)
- Filter: Year dropdown (2018-2025)
- Search: Full text search box

**Content Type:**
- Primarily research findings and clinical trial updates
- Occasional policy announcements (e.g., "NIH Proposes Embryonic Stem Cell Research Shift")
- NOT a primary source for grant termination announcements
- Tested pages 1-2: No grant suspension/termination announcements observed

**CSS Selectors (approx):**
- Pagination: `.pagination` or similar
- Release date: Date meta-tags or structured data
- Headlines: `<h2>` or `<h3>` elements

---

## NIH Grants Guide

**URL:** https://grants.nih.gov/grants/guide/

**Search Endpoint:** `/searchguide/Search_Guide_Results.cfm?pastoo=0&rfastoo=0&noticestoo=1&OrderOn=RelDate&OrderDirection=DESC`

**Status:** 500 error during testing; endpoint structure known but untested

**Expected Content:**
- Policy notices affecting grants
- Funding opportunity announcements
- Grant suspension/modification notices

**Note:** Guide contains historical notices; requires successful endpoint access for systematic crawling

---

## NIH FOIA Resources

**URL:** https://www.nih.gov/institutes-nih/nih-office-director/office-communications-public-liaison/freedom-information-act-office

**Available:**
- FOIA Library with document repository
- FOIA Coordinators Directory (by IC)
- Reference guides and exemption information

**Grant Termination Data:**
- NOT published systematically via FOIA portal
- Individual IC coordinators may maintain records
- Requires targeted FOIA request per IC

---

## Other URLs Explored

| URL | Status | Content |
|-----|--------|---------|
| https://grants.nih.gov/grants/ | Redirect | Main funding hub; no direct content |
| https://grants.nih.gov/grants/policy/ | Redirect | Policy section; access via JavaScript |
| https://grants.nih.gov/grants/oer.htm | 404 | Office of Extramural Research |
| https://grants.nih.gov/grants/policy/nihgps/index.htm | Redirect | NIH Grants Policy Statement |
| https://www.grants.gov/ | Accessible | Federal grants.gov (not NIH-specific) |

---

## Rate Limiting & Access Restrictions

**robots.txt directives:**
- Disallows: `/core/`, `/profiles/`, various `.md` and configuration files
- Allows: CSS, JS, images with explicit paths
- No explicit API blocking

**HTTP Headers:**
- Strict-Transport-Security enabled
- Content-Security-Policy restricts frame sources
- X-Frame-Options: SAMEORIGIN
- Rate limit headers present (1/minute)

**Recommendations:**
- Respect 1 request/second soft limit
- Schedule batch jobs outside 5AM-9PM EST
- Cache responses when possible
- Use search_id to avoid duplicate queries

---

## Gaps & Limitations

1. **No Explicit Termination Reason:** API does not expose why a grant was terminated
2. **No Suspension Status:** Grants are marked `is_active: false` but not categorized as suspended vs. ended vs. defunded
3. **News Coverage Limited:** Press releases rarely mention grant suspensions
4. **Historical Coverage Gaps:** Pre-2000s grants have sparse data
5. **Guide Search 500 Error:** NIH Guide search endpoint not functional during testing
6. **Foreign Grants:** Coverage of non-US institution awards is incomplete
7. **Real-time Lag:** `date_added` field may lag actual grant issuance by days/weeks
8. **No Webhook/Notification:** Must poll API manually; no push notifications for changes

---

## Recommended Follow-up for Forensic Analysis

1. **Automated Daily Polling:**
   - Query `date_added` field for projects added in past 24 hours with `is_active: false`
   - Compare against known active projects to detect deactivations
   - Archive all snapshots for temporal analysis

2. **Bulk Historical Export:**
   - Test https://reporter.nih.gov/exporter/ with different date ranges
   - Determine if CSV exports are available programmatically
   - Compare API data against exported records for consistency

3. **IC-Specific Tracking:**
   - Query by `agencies` parameter for each IC separately
   - Track funding changes by agency over time
   - Cross-reference with IC-level announcements

4. **Amendment Chain Analysis:**
   - Use `core_project_num` to link all versions of a grant (different support years)
   - Track `award_amount` changes across renewal years
   - Identify budget reductions or early terminations

5. **FOIA Targeted Requests:**
   - Contact FOIA coordinators for specific ICs
   - Request termination reason documentation
   - Request policy memoranda about funding freezes

6. **NIH Guide Archive:**
   - Once Guide search endpoint is available, crawl historical notices
   - Look for policy changes affecting grant types
   - Document dates of funding mechanism changes

---

## Actionable Data Extraction Points

**For Monitoring Terminated Grants:**

```json
{
  "criteria": {
    "include_active_projects": false,
    "project_end_date": {"from_date": "2026-01-01"},
    "date_added": {"from_date": "2026-02-01"}
  },
  "offset": 0,
  "limit": 500
}
```

**For Tracking Recent Modifications:**

```json
{
  "criteria": {
    "award_notice_date": {"from_date": "2026-02-01"},
    "fiscal_years": [2026]
  },
  "offset": 0,
  "limit": 500
}
```

**For Cross-Agency Analysis:**

```json
{
  "criteria": {
    "agencies": ["NIAID", "NCI", "NIDDK"],
    "include_active_projects": false,
    "project_end_date": {"from_date": "2024-01-01"}
  },
  "offset": 0,
  "limit": 500
}
```

---

## DOM/CSS Selectors (Web Interface)

**RePORTER Web Interface** (https://reporter.nih.gov/):
- Heavy Vue.js/React framework; no static HTML crawlable elements
- Data loaded dynamically from API calls
- Recommend using API directly instead of GUI scraping

**Press Releases Page** (https://www.nih.gov/news-events/news-releases):
- Release cards: Look for `<article>` or `.release-card` patterns
- Date elements: `<time>` tags or data attributes
- Pagination: `.pagination` or numbered link list
- Year filter: `<select>` or button group with year values

---

## Summary

**Primary Data Source:** NIH Reporter API v2 at `https://api.reporter.nih.gov/v2/projects/search`

**Key Grant Status Indicators:**
- `is_active: false` + `project_end_date` in past

**Sample Data:** 170,620+ inactive projects in database

**Recommended Collection Method:** Automated API polling with pagination

**Limitations:** No termination reason exposed; must infer from status changes
