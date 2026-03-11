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

  df |>
    assertr::verify(is.character(agency_name)) |>
    assertr::verify(nchar(agency_name) > 0) |>
    assertr::verify(inherits(notice_date, "Date")) |>
    assertr::verify(is.character(source_url)) |>
    assertr::verify(nchar(source_url) > 0) |>
    assertr::verify(is.character(raw_text_snippet))
}

#' Validate USAspending award data against expected schema
#'
#' Enforces:
#'
#' - `agency_name` is character
#' - `award_amount` is numeric
#' - `action_date` is a Date object
#' - `grant_number` is character (required for join_and_flag exact matching)
#'
#' @param df A tibble of USAspending award records.
#' @return The input tibble if validation passes.
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

  df |>
    assertr::verify(is.character(agency_name)) |>
    assertr::verify(is.numeric(award_amount)) |>
    assertr::verify(inherits(action_date, "Date")) |>
    assertr::verify(is.character(grant_number))
}
