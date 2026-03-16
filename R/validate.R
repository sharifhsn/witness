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

# --------------------------------------------------------------------------- #
# Data quality — USAspending reporting submission status
# --------------------------------------------------------------------------- #

#' Check USAspending data freshness and quality for key agencies
#'
#' Queries `/api/v2/reporting/agencies/overview/` to flag agencies with stale
#' or uncertified submissions. Should be run before interpreting any drought
#' analysis — a "missing data" finding may reflect submission lag, not actual
#' spending behavior.
#'
#' @param fiscal_year Integer fiscal year. Default current FY.
#' @param fiscal_period Integer fiscal period 2-12. Default most recent period.
#' @param agency_codes Character vector of toptier codes to check.
#' @return Tibble with columns: agency_name, toptier_code,
#'   recent_publication_date, recent_publication_date_certified,
#'   days_since_publication, unlinked_assistance_award_count,
#'   obligation_difference, data_quality_flag.
#' @export
check_data_quality <- function(
  fiscal_year   = .current_fiscal_year(),
  fiscal_period = .current_fiscal_period(),
  agency_codes  = unname(AGENCY_TOPTIER_CODES)
) {
  url <- sprintf(
    "https://api.usaspending.gov/api/v2/reporting/agencies/overview/?fiscal_year=%d&fiscal_period=%d&limit=100",
    as.integer(fiscal_year),
    as.integer(fiscal_period)
  )

  log_event(sprintf(
    "check_data_quality: FY%d P%d, %d agencies",
    fiscal_year, fiscal_period, length(agency_codes)
  ))

  raw <- .usaspending_get(url, label = "reporting/agencies/overview")
  if (is.null(raw)) {
    log_event("check_data_quality: API call failed", "WARN")
    return(.empty_data_quality_tibble())
  }

  results <- raw[["results"]] %||% list()
  if (length(results) == 0L) return(.empty_data_quality_tibble())

  rows <- lapply(results, function(r) {
    pub_date <- tryCatch(
      as.Date(substr(as.character(r[["recent_publication_date"]] %||% NA_character_), 1L, 10L)),
      error = function(e) as.Date(NA)
    )
    dplyr::tibble(
      agency_name                       = as.character(r[["agency_name"]]    %||% NA_character_),
      toptier_code                      = as.character(r[["toptier_code"]]   %||% NA_character_),
      recent_publication_date           = pub_date,
      recent_publication_date_certified = isTRUE(r[["recent_publication_date_certified"]]),
      days_since_publication            = as.integer(Sys.Date() - pub_date),
      unlinked_assistance_award_count   = as.integer(r[["unlinked_assistance_award_count"]] %||% NA_integer_),
      obligation_difference             = .safe_as_numeric(r[["obligation_difference"]]),
      data_quality_flag                 = (
        !isTRUE(r[["recent_publication_date_certified"]]) ||
        (as.integer(Sys.Date() - pub_date) > 45L)
      )
    )
  })

  combined <- dplyr::bind_rows(rows)
  if (length(agency_codes) > 0L) {
    combined <- combined |> dplyr::filter(toptier_code %in% agency_codes)
  }

  flagged <- sum(combined$data_quality_flag, na.rm = TRUE)
  if (flagged > 0L) {
    log_event(sprintf(
      "check_data_quality: %d/%d agencies have data quality flags",
      flagged, nrow(combined)
    ), "WARN")
  }
  combined
}

#' @keywords internal
.current_fiscal_year <- function() {
  today <- Sys.Date()
  yr    <- as.integer(format(today, "%Y"))
  mo    <- as.integer(format(today, "%m"))
  if (mo >= 10L) yr + 1L else yr
}

#' @keywords internal
.current_fiscal_period <- function() {
  today <- Sys.Date()
  mo    <- as.integer(format(today, "%m"))
  raw_fp <- if (mo >= 10L) mo - 9L else mo + 3L
  min(max(raw_fp - 1L, 2L), 11L)
}

#' @keywords internal
.empty_data_quality_tibble <- function() {
  dplyr::tibble(
    agency_name                       = character(0),
    toptier_code                      = character(0),
    recent_publication_date           = as.Date(character(0)),
    recent_publication_date_certified = logical(0),
    days_since_publication            = integer(0),
    unlinked_assistance_award_count   = integer(0),
    obligation_difference             = double(0),
    data_quality_flag                 = logical(0)
  )
}
