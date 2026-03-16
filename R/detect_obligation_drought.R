#' @title Obligation Drought Detection
#' @description Detects the "obligation drought" — the collapse in new federal
#'   grant obligations that is invisible to GW's terminated-grant methodology.
#'   Uses GTAS-sourced period-by-period obligation data from USAspending and
#'   Daily Treasury Statement withdrawal data to quantify the full disruption
#'   iceberg: formal terminations (GW-tracked) plus the pipeline stall (untracked).

#' Detect obligation drought — FY2026 pace vs. historical baseline
#'
#' For each agency × fiscal_period, compares FY2026 cumulative obligations
#' against the baseline mean. A "drought" is when FY2026 is below 50% of baseline.
#'
#' @param agency_obligations Tibble from `fetch_agency_obligations()`.
#' @param baseline_fiscal_years Integer vector of fiscal years to use as baseline.
#'   Default c(2023L, 2024L).
#' @return Tibble with columns: agency, fiscal_period, fy2026_obligations,
#'   fy2025_obligations, fy2024_obligations, fy2023_obligations,
#'   expected_cumulative, drought_severity, drought_flag.
#' @export
detect_obligation_drought <- function(
  agency_obligations,
  baseline_fiscal_years = c(2023L, 2024L)
) {
  if (nrow(agency_obligations) == 0L) {
    return(.empty_drought_tibble())
  }

  # Pivot so each fiscal_year is a column
  wide <- agency_obligations |>
    dplyr::select(agency, fiscal_year, fiscal_period, obligations_cumulative) |>
    tidyr::pivot_wider(
      names_from  = fiscal_year,
      values_from = obligations_cumulative,
      names_prefix = "fy"
    )

  # Compute expected_cumulative as mean of baseline years (NA-safe)
  baseline_cols <- paste0("fy", baseline_fiscal_years)
  # Only keep baseline cols that actually exist in wide
  baseline_cols <- intersect(baseline_cols, names(wide))

  wide <- wide |>
    dplyr::mutate(
      expected_cumulative = rowMeans(
        dplyr::across(dplyr::all_of(baseline_cols)),
        na.rm = TRUE
      ),
      # Coerce NaN (all-NA row) to NA
      expected_cumulative = dplyr::if_else(
        is.nan(expected_cumulative), NA_real_, expected_cumulative
      ),
      drought_severity = dplyr::if_else(
        !is.na(expected_cumulative) & expected_cumulative > 0 & !is.na(.data[["fy2026"]]),
        .data[["fy2026"]] / expected_cumulative,
        NA_real_
      ),
      drought_flag = dplyr::coalesce(drought_severity < 0.5, FALSE)
    )

  # Standardise output column names regardless of which FYs are present
  result <- wide |>
    dplyr::rename(
      fy2026_obligations = dplyr::any_of("fy2026"),
      fy2025_obligations = dplyr::any_of("fy2025"),
      fy2024_obligations = dplyr::any_of("fy2024"),
      fy2023_obligations = dplyr::any_of("fy2023")
    ) |>
    dplyr::select(
      agency, fiscal_period,
      dplyr::any_of(c(
        "fy2026_obligations", "fy2025_obligations",
        "fy2024_obligations", "fy2023_obligations"
      )),
      expected_cumulative, drought_severity, drought_flag
    )

  result
}

#' Compute the obligation pipeline gap — the "iceberg" analysis
#'
#' Compares the YoY obligation shortfall against GW's tracked terminations to
#' estimate how much of the funding disruption is invisible to GW's methodology.
#'
#' @param agency_obligations Tibble from `fetch_agency_obligations()`.
#' @param gw_terminated_data Optional tibble with a `estimated_remaining` or
#'   `gw_remaining` column (from `fetch_gw_nih()` output). If NULL or zero-row,
#'   `gw_lost_funding` and `pipeline_gap_estimate` are set to NA.
#' @note `gw_terminated_data` from `fetch_gw_nih()` covers NIH only. NSF row
#'   will have `gw_lost_funding = NA` unless NSF GW data is also passed.
#' @return Tibble with columns: agency, comparison_period, fy2026_obligations,
#'   fy2025_obligations, obligation_shortfall, gw_lost_funding,
#'   pipeline_gap_estimate, pipeline_gap_pct.
#' @export
compute_pipeline_gap <- function(
  agency_obligations,
  gw_terminated_data = NULL
) {
  if (nrow(agency_obligations) == 0L) {
    return(.empty_pipeline_gap_tibble())
  }

  # Find the latest fiscal_period available in FY2026 data
  fy2026 <- agency_obligations |>
    dplyr::filter(fiscal_year == 2026L)

  if (nrow(fy2026) == 0L) {
    log_event("compute_pipeline_gap: no FY2026 data found", "WARN")
    return(.empty_pipeline_gap_tibble())
  }

  # Latest period shared across agencies (use min so comparison is fair)
  latest_period <- fy2026 |>
    dplyr::group_by(agency) |>
    dplyr::summarise(max_period = max(fiscal_period, na.rm = TRUE), .groups = "drop") |>
    dplyr::pull(max_period) |>
    min(na.rm = TRUE)

  fy2026_at_period <- fy2026 |>
    dplyr::filter(fiscal_period == latest_period) |>
    dplyr::select(agency, fy2026_obligations = obligations_cumulative)

  fy2025_at_period <- agency_obligations |>
    dplyr::filter(fiscal_year == 2025L, fiscal_period == latest_period) |>
    dplyr::select(agency, fy2025_obligations = obligations_cumulative)

  # Compute GW lost funding by agency (NIH only from gw_terminated_data)
  gw_by_agency <- .compute_gw_lost_funding(gw_terminated_data)

  result <- fy2026_at_period |>
    dplyr::left_join(fy2025_at_period, by = "agency") |>
    dplyr::left_join(gw_by_agency,     by = "agency") |>
    dplyr::mutate(
      comparison_period     = latest_period,
      obligation_shortfall  = dplyr::if_else(
        !is.na(fy2025_obligations) & !is.na(fy2026_obligations),
        fy2025_obligations - fy2026_obligations,
        NA_real_
      ),
      pipeline_gap_estimate = dplyr::if_else(
        !is.na(obligation_shortfall) & !is.na(gw_lost_funding),
        obligation_shortfall - gw_lost_funding,
        NA_real_
      ),
      pipeline_gap_pct = dplyr::if_else(
        !is.na(pipeline_gap_estimate) & !is.na(obligation_shortfall) & obligation_shortfall > 0,
        pipeline_gap_estimate / obligation_shortfall,
        NA_real_
      )
    ) |>
    dplyr::select(
      agency, comparison_period,
      fy2026_obligations, fy2025_obligations,
      obligation_shortfall, gw_lost_funding,
      pipeline_gap_estimate, pipeline_gap_pct
    )

  result
}

#' Detect DTS anomalies using rolling 7-day YoY comparison
#'
#' Reconstructs daily withdrawal increments from MTD totals, computes a
#' 7-day rolling sum, and compares to the same window one year prior.
#' Flags days where current-year withdrawals are below 60% of prior year.
#'
#' @param dts_data Tibble from `fetch_dts_withdrawals()`.
#' @param reference_period_days Integer. Not currently used (kept for API
#'   compatibility); rolling window is fixed at 7 days.
#' @return Tibble with columns: record_date, agency, mtd_withdrawals,
#'   daily_increment, roll7_withdrawals, prior_yr_roll7, yoy_ratio,
#'   dts_anomaly_flag.
#' @export
detect_dts_anomaly <- function(dts_data, reference_period_days = 30L) {
  if (nrow(dts_data) == 0L) {
    return(.empty_dts_anomaly_tibble())
  }

  # Reconstruct daily increments from MTD totals.
  # Reset to mtd_withdrawals on the first day of each month (lag would cross month).
  daily <- dts_data |>
    dplyr::arrange(agency, record_date) |>
    dplyr::group_by(agency) |>
    dplyr::mutate(
      prev_mtd      = dplyr::lag(mtd_withdrawals, 1L),
      prev_date     = dplyr::lag(record_date, 1L),
      # Cross-month: MTD resets on the 1st, so use mtd directly
      same_month    = !is.na(prev_date) &
                        format(record_date, "%m") == format(prev_date, "%m") &
                        format(record_date, "%Y") == format(prev_date, "%Y"),
      daily_increment = dplyr::if_else(
        same_month & !is.na(prev_mtd),
        mtd_withdrawals - prev_mtd,
        mtd_withdrawals   # first day of month: daily = mtd
      )
    ) |>
    dplyr::ungroup()

  # 7-day rolling sum of daily_increment
  daily <- daily |>
    dplyr::group_by(agency) |>
    dplyr::mutate(
      roll7_withdrawals = slider::slide_dbl(
        daily_increment, sum, na.rm = TRUE,
        .before = 6L, .after = 0L, .complete = FALSE
      )
    ) |>
    dplyr::ungroup()

  # Prior-year same window: shift record_date by +365 days, then join
  prior_year <- daily |>
    dplyr::mutate(record_date_shifted = record_date + 365L) |>
    dplyr::select(agency, record_date_shifted, prior_yr_roll7 = roll7_withdrawals)

  result <- daily |>
    dplyr::left_join(
      prior_year,
      by = c("agency", "record_date" = "record_date_shifted")
    ) |>
    dplyr::mutate(
      yoy_ratio = dplyr::if_else(
        !is.na(prior_yr_roll7) & prior_yr_roll7 > 0,
        roll7_withdrawals / prior_yr_roll7,
        NA_real_
      ),
      dts_anomaly_flag = dplyr::coalesce(yoy_ratio < 0.60, FALSE)
    ) |>
    dplyr::select(
      record_date, agency,
      mtd_withdrawals, daily_increment,
      roll7_withdrawals, prior_yr_roll7,
      yoy_ratio, dts_anomaly_flag
    )

  result
}

# --------------------------------------------------------------------------- #
# Internal helpers
# --------------------------------------------------------------------------- #

#' Compute GW lost funding by agency from GW terminated data.
#' Returns a tibble with agency and gw_lost_funding columns.
#' @keywords internal
.compute_gw_lost_funding <- function(gw_terminated_data) {
  if (is.null(gw_terminated_data) || nrow(gw_terminated_data) == 0L) {
    return(dplyr::tibble(agency = character(0), gw_lost_funding = double(0)))
  }

  # GW NIH data uses `estimated_remaining` column (from fetch_gw_nih output)
  remaining_col <- intersect(
    c("estimated_remaining", "gw_remaining", "remaining_obligation"),
    names(gw_terminated_data)
  )

  if (length(remaining_col) == 0L) {
    log_event("compute_pipeline_gap: gw_terminated_data has no remaining column", "WARN")
    return(dplyr::tibble(agency = character(0), gw_lost_funding = double(0)))
  }

  # GW NIH data covers NIH → map to HHS parent agency used in obligations data
  gw_terminated_data |>
    dplyr::mutate(
      agency = "Department of Health and Human Services",
      .remaining = .data[[remaining_col[1L]]]
    ) |>
    dplyr::group_by(agency) |>
    dplyr::summarise(
      gw_lost_funding = sum(.remaining, na.rm = TRUE) / 1e6,  # convert to $M
      .groups = "drop"
    )
}

#' @keywords internal
.empty_drought_tibble <- function() {
  dplyr::tibble(
    agency              = character(0),
    fiscal_period       = integer(0),
    fy2026_obligations  = double(0),
    fy2025_obligations  = double(0),
    fy2024_obligations  = double(0),
    fy2023_obligations  = double(0),
    expected_cumulative = double(0),
    drought_severity    = double(0),
    drought_flag        = logical(0)
  )
}

#' @keywords internal
.empty_pipeline_gap_tibble <- function() {
  dplyr::tibble(
    agency                = character(0),
    comparison_period     = integer(0),
    fy2026_obligations    = double(0),
    fy2025_obligations    = double(0),
    obligation_shortfall  = double(0),
    gw_lost_funding       = double(0),
    pipeline_gap_estimate = double(0),
    pipeline_gap_pct      = double(0)
  )
}

#' @keywords internal
.empty_dts_anomaly_tibble <- function() {
  dplyr::tibble(
    record_date       = as.Date(character(0)),
    agency            = character(0),
    mtd_withdrawals   = double(0),
    daily_increment   = double(0),
    roll7_withdrawals = double(0),
    prior_yr_roll7    = double(0),
    yoy_ratio         = double(0),
    dts_anomaly_flag  = logical(0)
  )
}
