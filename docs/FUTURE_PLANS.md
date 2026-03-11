# Future Plans

## Novel Data Narrative

### 1. NIH Institute-Level Breakdown
GW tracks NIH at agency level. `scrape_nih.R` extracts IC abbreviation from
`agency_ic_fundings` — answers "which NIH institutes are disproportionately
affected by terminations?" GW's weekly reports can't answer this.

### 2. Obligation-vs-Outlay Discrepancies
`transform.R` computes `outlay_ratio` and flags grants where money was obligated
but outlays stopped. Detects "frozen in practice but not on paper" — silent
payment stoppages that GW can't detect from status fields alone.

### 3. Active-Despite-Terminated Detection
Finds grants marked terminated by notices but USAspending still shows active
outlays with future end date. Direct contradictions between forensic and official
data.

### 4. Untracked Awards
Grants in USAspending for tracked agencies with no corresponding forensic notice.
Gaps in GW's coverage.

### 5. NSF Directorate-Level Analysis
`scrape_nsf.R` preserves `directorate` field. GW has this column but doesn't
break it down in weekly reports.

### 6. Agencies Beyond Big 5
`fetch_usaspending.R` accepts any agency name. Adding DOE, USDA, ED is a
parameter change. GW tracks zero data for these agencies.

---

## Visualization Ideas (aligned with GW style)

1. **Institute-Level Bar Chart** — NIH institutes ranked by terminated grant
   count, viridis color by dollar exposure. `ggplot2::geom_col() + coord_flip()`

2. **Obligation-Outlay Gap Scatter** — X: award_amount, Y: outlay_ratio, colored
   by discrepancy_type, sized by dollar exposure. Interactive Plotly.

3. **Discrepancy Summary Table** — Agency-level rollup matching GW weekly report
   format. `gt` or `kableExtra` with viridis shading.

4. **Cross-Agency Funding Curve** — Extend GW's NIH-only funding curves to
   NSF + EPA. `ggplot2::geom_line() + facet_wrap(~agency_name)`

5. **Geographic Heatmap** — `org_state` from NIH Reporter enables state-level
   choropleth. `usmap::plot_usmap()` with viridis palette.
