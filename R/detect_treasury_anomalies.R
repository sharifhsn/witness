#' @title Treasury Spending Anomaly Detection
#' @description Detects month-over-month and year-over-year spending anomalies
#'   in Treasury MTS data and cross-references them against grant-level
#'   discrepancy flags from our pipeline.

#' Detect spending anomalies in MTS outlay data
#'
#' For each bureau, computes month-over-month and year-over-year changes,
#' z-scores against trailing 12-month average, and flags anomalous drops.
#'
#' @param mts_data Tibble from `fetch_mts_outlays()`.
#' @param mom_threshold Numeric. Month-over-month drop threshold (negative = drop).
#'   Default -0.20 (20% drop).
#' @param yoy_threshold Numeric. Year-over-year drop threshold. Default -0.15.
#' @param z_threshold Numeric. Z-score threshold for flagging. Default -2.0.
#' @return Tibble of anomaly records with columns: agency, bureau, record_date,
#'   month_outlays, pct_change_mom, pct_change_yoy, z_score, anomaly_flag.
#' @export
detect_spending_anomalies <- function(
  mts_data,
  mom_threshold = -0.20,
  yoy_threshold = -0.15,
  z_threshold   = -2.0
) {
  if (nrow(mts_data) == 0L) {
    log_event("detect_spending_anomalies: no data", "WARN")
    return(.empty_anomaly_tibble())
  }

  result <- mts_data |>
    dplyr::arrange(bureau, record_date) |>
    dplyr::group_by(bureau, agency) |>
    dplyr::mutate(
      prev_month_outlays = dplyr::lag(month_outlays, 1L),
      pct_change_mom = dplyr::if_else(
        !is.na(prev_month_outlays) & abs(prev_month_outlays) > 0,
        (month_outlays - prev_month_outlays) / abs(prev_month_outlays),
        NA_real_
      ),
      roll_mean = slider::slide_dbl(
        month_outlays, mean, na.rm = TRUE,
        .before = 12L, .after = -1L, .complete = FALSE
      ),
      roll_sd = slider::slide_dbl(
        month_outlays, stats::sd, na.rm = TRUE,
        .before = 12L, .after = -1L, .complete = FALSE
      ),
      z_score = dplyr::if_else(
        !is.na(roll_sd) & roll_sd > 0,
        (month_outlays - roll_mean) / roll_sd,
        NA_real_
      )
    ) |>
    dplyr::ungroup()

  # Year-over-year: join same fiscal_month from prior fiscal_year.
  # distinct() guards against duplicate MTS records inflating the join.
  prior_year <- mts_data |>
    dplyr::mutate(fiscal_year = fiscal_year + 1L) |>
    dplyr::select(bureau, fiscal_year, fiscal_month, prior_year_outlays = month_outlays) |>
    dplyr::distinct(bureau, fiscal_year, fiscal_month, .keep_all = TRUE)

  result |>
    dplyr::left_join(prior_year, by = c("bureau", "fiscal_year", "fiscal_month")) |>
    dplyr::mutate(
      pct_change_yoy = dplyr::if_else(
        !is.na(prior_year_outlays) & abs(prior_year_outlays) > 0,
        (month_outlays - prior_year_outlays) / abs(prior_year_outlays),
        NA_real_
      ),
      anomaly_flag = dplyr::coalesce(
        (!is.na(pct_change_mom) & pct_change_mom < mom_threshold) |
        (!is.na(pct_change_yoy) & pct_change_yoy < yoy_threshold) |
        (!is.na(z_score) & z_score < z_threshold),
        FALSE
      )
    ) |>
    dplyr::select(
      agency, bureau, record_date, fiscal_year, fiscal_month,
      month_outlays, pct_change_mom, pct_change_yoy, z_score, anomaly_flag
    ) |>
    (\(df) {
      log_event(sprintf(
        "Treasury anomaly detection: %d anomalous months out of %d total",
        sum(df$anomaly_flag), nrow(df)
      ))
      df
    })()
}

#' Cross-reference Treasury anomalies with grant-level discrepancies
#'
#' For each anomaly row, joins grant-level summary stats by agency to produce
#' a corroboration score: do macro spending drops correlate with our
#' grant-level freeze/termination flags?
#'
#' @param anomalies Tibble from `detect_spending_anomalies()`.
#' @param discrepancies_enriched Tibble from the pipeline's enriched discrepancies.
#' @return Enriched anomalies tibble with additional columns: n_grants_agency,
#'   n_freeze_flagged, n_active_terminated, corroboration_score.
#' @export
cross_reference_anomalies <- function(anomalies, discrepancies_enriched) {
  if (nrow(anomalies) == 0L || nrow(discrepancies_enriched) == 0L) {
    log_event("cross_reference_anomalies: empty input", "WARN")
    return(anomalies |>
      dplyr::mutate(
        n_grants_agency = NA_integer_,
        n_freeze_flagged = NA_integer_,
        n_active_terminated = NA_integer_,
        corroboration_score = NA_real_
      ))
  }

  # Summarize grant-level signals by agency, then join directly.
  # Treasury `agency` and pipeline `agency_name` use the same strings.
  grant_summary <- discrepancies_enriched |>
    dplyr::group_by(agency_name) |>
    dplyr::summarise(
      n_grants_agency     = dplyr::n(),
      n_freeze_flagged    = sum(
        discrepancy_type %in% c("possible_freeze", "possible_freeze_no_data"),
        na.rm = TRUE
      ),
      n_active_terminated = sum(
        discrepancy_type == "active_despite_terminated",
        na.rm = TRUE
      ),
      .groups = "drop"
    )

  enriched <- anomalies |>
    dplyr::left_join(grant_summary, by = c("agency" = "agency_name")) |>
    dplyr::mutate(
      corroboration_score = dplyr::if_else(
        !is.na(n_grants_agency) & n_grants_agency > 0L,
        (dplyr::coalesce(n_freeze_flagged, 0L) + dplyr::coalesce(n_active_terminated, 0L)) /
          n_grants_agency,
        NA_real_
      )
    )

  log_event(sprintf(
    "Treasury cross-reference: %d anomaly rows enriched with grant-level context",
    nrow(enriched)
  ))

  enriched
}

# --------------------------------------------------------------------------- #
# File C cross-reference
# --------------------------------------------------------------------------- #

#' Cross-reference Treasury anomalies with File C grant-level data
#'
#' For each Treasury anomaly month, counts how many of our tracked grants
#' had $0 outlays in that same month per File C data. Computes a
#' `file_c_corroboration_score`: what fraction of grants with File C data
#' show zero outlays in the anomaly month.
#'
#' This is the payoff: "Treasury shows NIH dropped 40% in February; here are
#' 200 grants where File C outlays went to $0 that same month."
#'
#' @param anomalies Tibble from `detect_spending_anomalies()`.
#' @param file_c_data Tibble from `fetch_file_c()`.
#' @param discrepancies Tibble with grant_number and agency_name for lookup.
#' @return Enriched anomalies tibble with additional columns:
#'   n_grants_with_file_c, n_grants_zero_that_month,
#'   file_c_corroboration_score.
#' @export
cross_reference_file_c_anomalies <- function(anomalies, file_c_data,
                                             discrepancies) {
  if (nrow(anomalies) == 0L) {
    log_event("cross_reference_file_c_anomalies: no anomalies", "WARN")
    return(anomalies |>
      dplyr::mutate(
        n_grants_with_file_c       = NA_integer_,
        n_grants_zero_that_month   = NA_integer_,
        file_c_corroboration_score = NA_real_
      ))
  }

  if (nrow(file_c_data) == 0L) {
    log_event("cross_reference_file_c_anomalies: no File C data", "WARN")
    return(anomalies |>
      dplyr::mutate(
        n_grants_with_file_c       = NA_integer_,
        n_grants_zero_that_month   = NA_integer_,
        file_c_corroboration_score = NA_real_
      ))
  }

  # Map grants to agencies
  agency_lookup <- discrepancies |>
    dplyr::select(grant_number, agency_name) |>
    dplyr::distinct()

  # Add agency to File C data
  file_c_with_agency <- file_c_data |>
    dplyr::inner_join(agency_lookup, by = "grant_number")

  if (nrow(file_c_with_agency) == 0L) {
    log_event("cross_reference_file_c_anomalies: no File C-agency matches", "WARN")
    return(anomalies |>
      dplyr::mutate(
        n_grants_with_file_c       = NA_integer_,
        n_grants_zero_that_month   = NA_integer_,
        file_c_corroboration_score = NA_real_
      ))
  }

  # Summarize File C per agency-month: how many grants have data,
  # how many show $0 outlays
  file_c_monthly <- file_c_with_agency |>
    dplyr::mutate(
      calendar_month = as.integer(format(reporting_date, "%m")),
      calendar_year  = as.integer(format(reporting_date, "%Y"))
    ) |>
    dplyr::group_by(agency_name, calendar_year, calendar_month) |>
    dplyr::summarise(
      n_grants_with_file_c     = dplyr::n_distinct(grant_number),
      n_grants_zero_that_month = dplyr::n_distinct(
        grant_number[is.na(outlay_amount) | outlay_amount == 0]
      ),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      file_c_corroboration_score = dplyr::if_else(
        n_grants_with_file_c > 0L,
        as.numeric(n_grants_zero_that_month) / n_grants_with_file_c,
        NA_real_
      )
    )

  # Join anomalies to File C monthly summary.
  # Treasury anomalies use fiscal_month (calendar month) and record_date.
  # Extract calendar year/month from anomaly record_date.
  enriched <- anomalies |>
    dplyr::mutate(
      calendar_month = as.integer(format(record_date, "%m")),
      calendar_year  = as.integer(format(record_date, "%Y"))
    ) |>
    dplyr::left_join(
      file_c_monthly,
      by = c("agency" = "agency_name", "calendar_year", "calendar_month")
    ) |>
    dplyr::select(-calendar_month, -calendar_year)

  n_corroborated <- sum(!is.na(enriched$file_c_corroboration_score) &
                          enriched$file_c_corroboration_score > 0.5, na.rm = TRUE)

  log_event(sprintf(
    "File C Treasury cross-reference: %d anomaly rows enriched, %d strongly corroborated (>50%% grants at $0)",
    nrow(enriched), n_corroborated
  ))

  enriched
}

# --------------------------------------------------------------------------- #
# Internal helpers
# --------------------------------------------------------------------------- #

#' @keywords internal
.empty_anomaly_tibble <- function() {
  dplyr::tibble(
    agency         = character(0),
    bureau         = character(0),
    record_date    = as.Date(character(0)),
    fiscal_year    = integer(0),
    fiscal_month   = integer(0),
    month_outlays  = double(0),
    pct_change_mom = double(0),
    pct_change_yoy = double(0),
    z_score        = double(0),
    anomaly_flag   = logical(0)
  )
}
