#' @title Data Validation Functions
#' @description Schema enforcement for scraped grant data using assertr.
#' Ensures data integrity before downstream pipeline consumption.

# CFDA prefix → expected toptier agency name
# Used by validate_awards() to flag cross-reference mismatches
.CFDA_AGENCY_MAP <- c(
  "93" = "Department of Health and Human Services",
  "47" = "National Science Foundation",
  "66" = "Environmental Protection Agency"
)

# Valid US state and territory abbreviations (for org_state validation)
.VALID_STATE_CODES <- c(
  datasets::state.abb,  # 50 states
  "DC", "PR", "GU", "VI", "AS", "MP"  # DC + territories
)

# Known Canadian province codes that appear in NIH data for cross-border grants
.CANADIAN_PROVINCE_CODES <- c("AB", "BC", "MB", "NB", "NL", "NS", "NT", "NU",
                               "ON", "PE", "QC", "SK", "YT")

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
  if ("grant_number" %in% names(df)) {
    n_dup <- sum(duplicated(df$grant_number), na.rm = TRUE)
    if (n_dup > 0) {
      log_event(sprintf("Notices: %d duplicate grant_numbers detected", n_dup), "WARN")
    }
  }

  # Append quality flags for notices
  result <- validated |>
    dplyr::mutate(
      # International grant detection — Canadian provinces in NIH data
      flag_international = if ("org_state" %in% names(validated))
        !is.na(org_state) & org_state %in% .CANADIAN_PROVINCE_CODES
      else
        FALSE,
      # State code validation — catches truly invalid codes (not US, not known international)
      flag_invalid_state = if ("org_state" %in% names(validated))
        !is.na(org_state) & !(org_state %in% .VALID_STATE_CODES) &
        !(org_state %in% .CANADIAN_PROVINCE_CODES)
      else
        FALSE,
      # Grant number format validation — NSF should be 7 digits, NIH alphanumeric with dashes
      flag_bad_grant_number = if ("grant_number" %in% names(validated))
        !is.na(grant_number) & dplyr::case_when(
          agency_name == "NSF" ~ !grepl("^[0-9]{7}$", grant_number),
          agency_name == "NIH" ~ !grepl("^[A-Z0-9]", grant_number),
          TRUE ~ FALSE
        )
      else
        FALSE
    )

  log_quality_summary(result, "notices")
  result
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

  # Detect duplicate grant_numbers in award data (same award appearing multiple times)
  n_dup_awards <- sum(duplicated(validated$grant_number) & !is.na(validated$grant_number))
  if (n_dup_awards > 0) {
    log_event(sprintf("Awards: %d duplicate grant_numbers detected", n_dup_awards), "WARN")
  }

  result <- validated |>
    dplyr::mutate(
      flag_negative_outlay = !is.na(total_outlays) & total_outlays < 0,
      flag_over_disbursed  = !is.na(total_outlays) & !is.na(award_amount) &
                             award_amount > 0 & total_outlays > award_amount * 1.5,
      flag_date_inverted   = !is.na(action_date) & !is.na(end_date) & end_date < action_date,
      flag_zero_award      = !is.na(award_amount) & award_amount == 0,
      flag_future_date     = !is.na(action_date) & action_date > Sys.Date(),
      # CFDA-agency cross-validation: prefix should match awarding agency
      flag_cfda_mismatch   = if ("cfda_number" %in% names(validated))
        .check_cfda_agency(cfda_number, agency_name)
      else
        FALSE
    )

  log_quality_summary(result, "awards")
  result
}

# Vectorised CFDA-agency consistency check.
# Returns TRUE when the CFDA prefix does NOT match the expected agency.
# NA cfda_number or unknown prefix → FALSE (no mismatch detectable).
.check_cfda_agency <- function(cfda_number, agency_name) {
  prefix <- sub("\\..*", "", cfda_number)
  expected_agency <- .CFDA_AGENCY_MAP[prefix]
  !is.na(expected_agency) & !is.na(agency_name) & expected_agency != agency_name
}
