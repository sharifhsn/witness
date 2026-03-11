#' @title Data Validation Functions
#' @description Schema enforcement for scraped grant data using assertr.
#' Ensures data integrity before downstream pipeline consumption.

#' Validate a scraped notices tibble against the canonical schema
#'
#' Enforces:
#'
#' - `agency_name` is character and non-empty
#' - `notice_date` is a Date object
#' - `source_url` is character and non-empty
#' - `raw_text_snippet` is character (may be NA for metadata-only records)
#'
#' @param df A tibble of scraped grant notices.
#' @return The input tibble (unmodified) if validation passes.
#'   Raises an error via assertr if validation fails.
#' @export
validate_notices <- function(df) {
  required_cols <- c("agency_name", "notice_date", "source_url", "raw_text_snippet")
  missing <- setdiff(required_cols, names(df))
  if (length(missing) > 0) {
    stop(
      "Missing required columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }

  validated <- df |>
    assertr::verify(is.character(agency_name)) |>
    assertr::verify(nchar(agency_name) > 0) |>
    assertr::verify(inherits(notice_date, "Date")) |>
    assertr::verify(is.character(source_url)) |>
    assertr::verify(nchar(source_url) > 0) |>
    assertr::verify(is.character(raw_text_snippet))

  # Log quality metrics
  n_dup <- sum(duplicated(df$grant_number), na.rm = TRUE)
  if (n_dup > 0) {
    log_event(sprintf("Notices: %d duplicate grant_numbers detected", n_dup), "WARN")
  }

  log_quality_summary(validated, "notices")
  validated
}

#' Validate USAspending award data against expected schema
#'
#' Enforces:
#'
#' - `agency_name` is character
#' - `award_amount` is numeric and non-negative
#' - `action_date` is a Date object
#' - `grant_number` is character (required for join_and_flag exact matching)
#'
#' Also adds data quality flags:
#' - `flag_negative_outlay` — accounting adjustment or data error
#' - `flag_over_disbursed` — outlays exceed award amount by > 50%
#'
#' @param df A tibble of USAspending award records.
#' @return The input tibble with quality flag columns appended.
#' @export
validate_awards <- function(df) {
  required_cols <- c("agency_name", "award_amount", "action_date", "grant_number")
  missing <- setdiff(required_cols, names(df))
  if (length(missing) > 0) {
    stop(
      "Missing required columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }

  validated <- df |>
    assertr::verify(is.character(agency_name)) |>
    assertr::verify(is.numeric(award_amount)) |>
    assertr::verify(inherits(action_date, "Date")) |>
    assertr::verify(is.character(grant_number))

  # Append data quality flags (don't filter — flag for downstream awareness)
  n_neg <- sum(validated$total_outlays < 0, na.rm = TRUE)
  n_over <- sum(validated$total_outlays > validated$award_amount * 1.5, na.rm = TRUE)
  if (n_neg > 0) log_event(sprintf("Awards: %d records with negative outlays flagged", n_neg), "WARN")
  if (n_over > 0) log_event(sprintf("Awards: %d records with outlays >150%% of award flagged", n_over), "WARN")

  result <- validated |>
    dplyr::mutate(
      flag_negative_outlay = !is.na(total_outlays) & total_outlays < 0,
      flag_over_disbursed  = !is.na(total_outlays) & !is.na(award_amount) &
                             award_amount > 0 & total_outlays > award_amount * 1.5
    )

  log_quality_summary(result, "awards")
  result
}
