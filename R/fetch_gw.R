#' @title Grant Witness Ground Truth Data Fetcher
#' @description Downloads and parses Grant Witness's published CSV datasets
#'   containing labeled frozen/terminated/reinstated grants. These serve as
#'   ground truth for calibrating our freeze detection heuristic.

# --------------------------------------------------------------------------- #
# File C outlay parser
# --------------------------------------------------------------------------- #

#' Parse Grant Witness file_c_outlays string into a tibble
#'
#' @param file_c_string Character. Format: "- Oct/Nov 2024: $5,834,240\n- Dec 2024: $1,142,547\n..."
#' @return Tibble with columns: period (character), amount (numeric), period_date (Date).
#' @export
parse_file_c_outlays <- function(file_c_string) {
  if (is.na(file_c_string) || nchar(trimws(file_c_string)) == 0L) {
    return(dplyr::tibble(period = character(0), amount = numeric(0), period_date = as.Date(character(0))))
  }

  lines <- strsplit(file_c_string, "\n")[[1]]
  lines <- trimws(lines)
  lines <- lines[nchar(lines) > 0L]
  # Strip leading "- "
  lines <- sub("^-\\s*", "", lines)

  # Parse "Period: $Amount" pattern
  pattern <- "^(.+?):\\s*\\$?([0-9,.]+)$"
  matches <- regmatches(lines, regexec(pattern, lines))

  periods <- character(length(matches))
  amounts <- numeric(length(matches))
  keep <- logical(length(matches))

  for (i in seq_along(matches)) {
    m <- matches[[i]]
    if (length(m) == 3L) {
      periods[i] <- trimws(m[2])
      amounts[i] <- as.numeric(gsub(",", "", m[3]))
      keep[i] <- TRUE
    }
  }

  if (!any(keep)) {
    return(dplyr::tibble(period = character(0), amount = numeric(0), period_date = as.Date(character(0))))
  }

  periods <- periods[keep]
  amounts <- amounts[keep]

  dplyr::tibble(
    period = periods,
    amount = amounts,
    period_date = .parse_period_to_date(periods)
  )
}

#' Parse period strings like "Oct/Nov 2024", "Dec 2024" to first-of-month Date
#' @keywords internal
.parse_period_to_date <- function(periods) {
  # Use the first month if combined (e.g., "Oct/Nov 2024" -> "Oct 2024")
  simplified <- sub("/[A-Za-z]+", "", periods)
  # Try "%b %Y" format
  parsed <- as.Date(paste0("01 ", simplified), format = "%d %b %Y")
  parsed
}

# --------------------------------------------------------------------------- #
# GW NIH data fetcher
# --------------------------------------------------------------------------- #

#' Fetch and parse Grant Witness NIH termination CSV
#'
#' Downloads the published CSV and selects/renames key columns for analysis.
#' The full dataset (~38K rows) is returned with standardized column names.
#'
#' @param url Character. URL to the GW NIH CSV.
#' @return Tibble with standardized columns for calibration analysis.
#' @export
fetch_gw_nih <- function(url = "https://files.grant-witness.us/nih_terminations.csv") {
  log_event(sprintf("Fetching GW NIH data from %s", url))

  resp <- build_request(url) |>
    httr2::req_perform()

  raw_text <- httr2::resp_body_string(resp)

  df <- readr::read_csv(
    raw_text,
    col_types = readr::cols(.default = readr::col_character()),
    show_col_types = FALSE
  )

  log_event(sprintf("GW NIH raw: %d rows, %d columns", nrow(df), ncol(df)))

  # Standardize column names — GW uses snake_case already but be explicit
  result <- df |>
    dplyr::transmute(
      gw_award_id        = core_award_number,
      gw_status          = status,
      ever_frozen         = (tolower(ever_frozen) == "true") & !is.na(ever_frozen),
      targeted_start_date = parse_date_flexible(targeted_start_date),
      targeted_end_date   = parse_date_flexible(targeted_end_date),
      frozen_date         = parse_date_flexible(frozen_date),
      unfrozen_date       = parse_date_flexible(unfrozen_date),
      file_c_outlays_raw  = file_c_outlays,
      gw_total_award      = as.numeric(total_award),
      gw_total_outlays    = as.numeric(total_estimated_outlays),
      gw_remaining        = as.numeric(total_estimated_remaining),
      org_name            = org_name,
      org_state           = org_state,
      activity_code       = activity_code,
      reinstatement_indicator = reinstatement_indicator,
      last_payment_date   = parse_date_flexible(last_payment_date),
      last_payment_month  = last_payment_month
    )

  log_event(sprintf(
    "GW NIH parsed: %d rows, %d ever_frozen, status breakdown: %s",
    nrow(result),
    sum(result$ever_frozen, na.rm = TRUE),
    paste(names(table(result$gw_status)), table(result$gw_status), sep = "=", collapse = ", ")
  ))

  result
}

#' Fetch and parse Grant Witness NSF termination CSV
#'
#' @param url Character. URL to the GW NSF CSV.
#' @return Tibble with standardized columns.
#' @export
fetch_gw_nsf <- function(url = "https://files.grant-witness.us/nsf_terminations.csv") {
  log_event(sprintf("Fetching GW NSF data from %s", url))

  resp <- build_request(url) |>
    httr2::req_perform()

  raw_text <- httr2::resp_body_string(resp)

  df <- readr::read_csv(
    raw_text,
    col_types = readr::cols(.default = readr::col_character()),
    show_col_types = FALSE
  )

  log_event(sprintf("GW NSF raw: %d rows, %d columns", nrow(df), ncol(df)))

  result <- df |>
    dplyr::transmute(
      gw_award_id        = award_id,
      gw_status          = status,
      termination_date   = parse_date_flexible(termination_date),
      reinstatement_date = parse_date_flexible(reinstatement_date),
      gw_total_outlays   = as.numeric(usasp_outlaid),
      gw_total_obligated = as.numeric(usasp_total_obligated),
      gw_remaining       = as.numeric(estimated_remaining),
      obligation_hist    = usasp_obligation_hist,
      directorate        = directorate,
      division           = division
    )

  log_event(sprintf(
    "GW NSF parsed: %d rows, status breakdown: %s",
    nrow(result),
    paste(names(table(result$gw_status)), table(result$gw_status), sep = "=", collapse = ", ")
  ))

  result
}
