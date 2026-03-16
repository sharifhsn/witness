# test-parsers.R
# Comprehensive unit tests for the Grant Witness PoC scraper pipeline.
#
# Covers: utils.R, validate.R, scrape_nsf.R (parse_nsf_obligated), transform.R
#
# Run from the project root (not as a package — this project uses targets):
#   testthat::test_file("tests/testthat/test-parsers.R")

library(testthat)

# Source all R modules.  Use the project root as the base so this file can be
# run from any working directory (R CMD check sets wd to package root; ad-hoc
# runs may be from tests/testthat/).
.find_root <- function(start) {
  path <- normalizePath(start, mustWork = FALSE)
  for (i in seq_len(6L)) {
    if (file.exists(file.path(path, "_targets.R"))) return(path)
    path <- dirname(path)
  }
  NULL
}

.proj_root <- function() {
  # Try: walk up from this file's location
  root <- tryCatch(
    .find_root(dirname(sys.frame(1)$ofile)),
    error = function(e) NULL
  )
  if (!is.null(root)) return(root)
  # Fallback: walk up from cwd (testthat may set wd to tests/testthat/)
  root <- .find_root(getwd())
  if (!is.null(root)) return(root)
  getwd()
}

.root <- .proj_root()

suppressMessages({
  source(file.path(.root, "R/utils.R"))
  source(file.path(.root, "R/validate.R"))
  source(file.path(.root, "R/scrape_nih.R"))
  source(file.path(.root, "R/scrape_nsf.R"))
  source(file.path(.root, "R/transform.R"))
  source(file.path(.root, "R/fetch_usaspending.R"))
  source(file.path(.root, "R/fetch_gw.R"))
  source(file.path(.root, "R/calibrate_freeze.R"))
  source(file.path(.root, "R/fetch_file_c.R"))
  source(file.path(.root, "R/fetch_usaspending_budget.R"))
})

# ---------------------------------------------------------------------------
# Shared test data builders
# ---------------------------------------------------------------------------

.valid_notices <- function(...) {
  tibble::tibble(
    agency_name      = "NSF",
    notice_date      = as.Date("2025-03-01"),
    source_url       = "https://www.nsf.gov/awardsearch/showAward?AWD_ID=2301234",
    raw_text_snippet = "Molecular Basis of Neural Plasticity",
    grant_number     = "2301234",
    org_name         = "State University",
    ...
  )
}

.valid_awards <- function(...) {
  tibble::tibble(
    agency_name   = "NSF",
    award_amount  = 500000,
    action_date   = as.Date("2025-01-15"),
    grant_number  = "2301234",
    org_name      = "State University",
    total_outlays = 10000,
    end_date      = Sys.Date() + 365L,
    ...
  )
}

# ===========================================================================
# 1. utils.R
# ===========================================================================

# ---------------------------------------------------------------------------
# parse_date_flexible()
# ---------------------------------------------------------------------------

test_that("parse_date_flexible: long-form month name", {
  result <- parse_date_flexible("January 5, 2025")
  expect_s3_class(result, "Date")
  expect_equal(result, as.Date("2025-01-05"))
})

test_that("parse_date_flexible: MM/DD/YYYY format", {
  result <- parse_date_flexible("01/05/2025")
  expect_s3_class(result, "Date")
  expect_equal(result, as.Date("2025-01-05"))
})

test_that("parse_date_flexible: ISO 8601 format", {
  result <- parse_date_flexible("2025-01-05")
  expect_s3_class(result, "Date")
  expect_equal(result, as.Date("2025-01-05"))
})

test_that("parse_date_flexible: NA input returns NA Date", {
  result <- parse_date_flexible(NA_character_)
  expect_s3_class(result, "Date")
  expect_true(is.na(result))
})

test_that("parse_date_flexible: empty string returns NA Date", {
  result <- parse_date_flexible("")
  expect_s3_class(result, "Date")
  expect_true(is.na(result))
})

test_that("parse_date_flexible: garbage string returns NA Date", {
  result <- parse_date_flexible("not-a-date-at-all")
  expect_s3_class(result, "Date")
  expect_true(is.na(result))
})

test_that("parse_date_flexible: vectorised input handles mixed valid/invalid", {
  input  <- c("March 15, 2024", "garbage", "2023-06-01", NA)
  result <- parse_date_flexible(input)
  expect_length(result, 4L)
  expect_s3_class(result, "Date")
  expect_equal(result[1], as.Date("2024-03-15"))
  expect_true(is.na(result[2]))
  expect_equal(result[3], as.Date("2023-06-01"))
  expect_true(is.na(result[4]))
})

test_that("parse_date_flexible: first matching format wins (ambiguous MM/DD vs DD/MM)", {
  # "01/05/2025" with default formats: %m/%d/%Y fires before %Y-%m-%d
  result <- parse_date_flexible("01/05/2025")
  expect_equal(result, as.Date("2025-01-05"))
})

test_that("parse_date_flexible: custom formats parameter is respected", {
  result <- parse_date_flexible("2025/01/05", formats = "%Y/%m/%d")
  expect_equal(result, as.Date("2025-01-05"))
})

# ---------------------------------------------------------------------------
# log_event()
# ---------------------------------------------------------------------------

test_that("log_event: does not error with INFO level", {
  expect_no_error(log_event("test message"))
})

test_that("log_event: does not error with WARN level", {
  expect_no_error(log_event("something unusual", level = "WARN"))
})

test_that("log_event: does not error with ERROR level", {
  expect_no_error(log_event("something failed", level = "ERROR"))
})

test_that("log_event: returns invisible NULL", {
  result <- withVisible(log_event("test", level = "INFO"))
  expect_null(result$value)
  expect_false(result$visible)
})

test_that("log_event: output is written to stderr (message channel)", {
  # expect_message captures calls to message()
  expect_message(log_event("check stderr"), regexp = "check stderr")
})

test_that("log_event: timestamp appears in the log line", {
  expect_message(
    log_event("ts test"),
    # ISO timestamp pattern at the start
    regexp = "^\\[\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\]"
  )
})

# ===========================================================================
# 2. validate.R
# ===========================================================================

# ---------------------------------------------------------------------------
# validate_notices()
# ---------------------------------------------------------------------------

test_that("validate_notices: accepts a fully valid tibble", {
  df     <- .valid_notices()
  result <- validate_notices(df)
  expect_s3_class(result, "data.frame")
  expect_equal(nrow(result), 1L)
})

test_that("validate_notices: returns the input unchanged when valid", {
  df     <- .valid_notices()
  result <- validate_notices(df)
  expect_equal(result$agency_name, "NSF")
  expect_equal(result$notice_date, as.Date("2025-03-01"))
})

test_that("validate_notices: accepts multiple valid rows", {
  df <- tibble::tibble(
    agency_name      = c("NSF", "NIH"),
    notice_date      = as.Date(c("2025-01-01", "2025-02-15")),
    source_url       = c("https://nsf.gov/a", "https://nih.gov/b"),
    raw_text_snippet = c("Study A", "Study B")
  )
  expect_no_error(validate_notices(df))
})

test_that("validate_notices: errors on missing agency_name column", {
  df <- tibble::tibble(
    notice_date      = as.Date("2025-01-01"),
    source_url       = "https://example.com",
    raw_text_snippet = "text"
  )
  expect_error(validate_notices(df), regexp = "agency_name")
})

test_that("validate_notices: errors on missing notice_date column", {
  df <- tibble::tibble(
    agency_name      = "NSF",
    source_url       = "https://example.com",
    raw_text_snippet = "text"
  )
  expect_error(validate_notices(df), regexp = "notice_date")
})

test_that("validate_notices: errors when multiple required columns are missing", {
  df     <- tibble::tibble(extra = 1)
  err_rx <- "agency_name|notice_date|source_url|raw_text_snippet"
  expect_error(validate_notices(df), regexp = err_rx)
})

test_that("validate_notices: errors when notice_date is character instead of Date", {
  df <- .valid_notices()
  df$notice_date <- "2025-03-01"  # character, not Date
  expect_error(validate_notices(df))
})

test_that("validate_notices: errors on empty string in agency_name", {
  df <- .valid_notices()
  df$agency_name <- ""
  expect_error(validate_notices(df))
})

test_that("validate_notices: errors on empty string in source_url", {
  df <- .valid_notices()
  df$source_url <- ""
  expect_error(validate_notices(df))
})

test_that("validate_notices: allows NA in raw_text_snippet (metadata-only records)", {
  df <- .valid_notices()
  df$raw_text_snippet <- NA_character_
  # raw_text_snippet may be NA — the assertr rule only checks is.character
  expect_no_error(validate_notices(df))
})

test_that("validate_notices: errors on non-character agency_name (e.g. factor)", {
  df <- .valid_notices()
  df$agency_name <- factor("NSF")
  expect_error(validate_notices(df))
})

# ---------------------------------------------------------------------------
# validate_awards()
# ---------------------------------------------------------------------------

test_that("validate_awards: accepts a fully valid tibble", {
  df <- .valid_awards()
  expect_no_error(validate_awards(df))
})

test_that("validate_awards: returns input unchanged when valid", {
  df     <- .valid_awards()
  result <- validate_awards(df)
  expect_equal(nrow(result), nrow(df))
  expect_equal(result$award_amount, 500000)
})

test_that("validate_awards: errors on missing agency_name column", {
  df <- tibble::tibble(award_amount = 1000, action_date = Sys.Date(), grant_number = "X")
  expect_error(validate_awards(df), regexp = "agency_name")
})

test_that("validate_awards: errors on missing award_amount column", {
  df <- tibble::tibble(agency_name = "NSF", action_date = Sys.Date(), grant_number = "X")
  expect_error(validate_awards(df), regexp = "award_amount")
})

test_that("validate_awards: errors on missing action_date column", {
  df <- tibble::tibble(agency_name = "NSF", award_amount = 1000, grant_number = "X")
  expect_error(validate_awards(df), regexp = "action_date")
})

test_that("validate_awards: errors on missing grant_number column", {
  df <- tibble::tibble(agency_name = "NSF", award_amount = 1000, action_date = Sys.Date())
  expect_error(validate_awards(df), regexp = "grant_number")
})

test_that("validate_awards: errors when award_amount is character", {
  df <- .valid_awards()
  df$award_amount <- "500000"
  expect_error(validate_awards(df))
})

test_that("validate_awards: errors when action_date is character instead of Date", {
  df <- .valid_awards()
  df$action_date <- "2025-01-15"
  expect_error(validate_awards(df))
})

test_that("validate_awards: errors when grant_number is numeric instead of character", {
  df <- .valid_awards()
  df$grant_number <- 2301234
  expect_error(validate_awards(df))
})

test_that("validate_awards: accepts NA in award_amount (numeric NA is still numeric)", {
  df <- .valid_awards()
  df$award_amount <- NA_real_
  expect_no_error(validate_awards(df))
})

# ===========================================================================
# 3. scrape_nsf.R — parse_nsf_obligated()
# ===========================================================================

test_that("parse_nsf_obligated: standard dollar-comma format", {
  expect_equal(parse_nsf_obligated("$44,434,393 "), 44434393)
})

test_that("parse_nsf_obligated: small value", {
  expect_equal(parse_nsf_obligated("$1,200"), 1200)
})

test_that("parse_nsf_obligated: zero", {
  expect_equal(parse_nsf_obligated("0"), 0)
})

test_that("parse_nsf_obligated: quoted string with dollar sign", {
  expect_equal(parse_nsf_obligated('"$5,000"'), 5000)
})

test_that("parse_nsf_obligated: empty string returns NA", {
  result <- parse_nsf_obligated("")
  expect_true(is.na(result))
})

test_that("parse_nsf_obligated: NA input returns NA", {
  result <- parse_nsf_obligated(NA_character_)
  expect_true(is.na(result))
})

test_that("parse_nsf_obligated: 'N/A' string returns NA and emits a warning log", {
  # Non-empty, non-numeric text triggers a WARN via log_event (message channel)
  expect_message(
    result <- parse_nsf_obligated("N/A"),
    regexp = "could not be coerced"
  )
  expect_true(is.na(result))
})

test_that("parse_nsf_obligated: garbage text returns NA with warning", {
  expect_message(
    result <- parse_nsf_obligated("TBD"),
    regexp = "could not be coerced"
  )
  expect_true(is.na(result))
})

test_that("parse_nsf_obligated: vectorised — mixed valid, NA, empty, garbage", {
  input    <- c('$44,434,393 ', '"$1,200"', '', 'N/A')
  expected <- c(44434393, 1200, NA_real_, NA_real_)
  # Suppress the WARN message for N/A
  result <- suppressMessages(parse_nsf_obligated(input))
  expect_equal(result, expected)
})

test_that("parse_nsf_obligated: negative value preserved as negative numeric", {
  expect_equal(parse_nsf_obligated("-$500"), -500)
})

test_that("parse_nsf_obligated: all-NA vector returns all NA without error", {
  result <- parse_nsf_obligated(c(NA_character_, NA_character_))
  expect_equal(length(result), 2L)
  expect_true(all(is.na(result)))
})

test_that("parse_nsf_obligated: all-zero vector returns numeric zeros", {
  result <- parse_nsf_obligated(c("0", "$0", "$0.00"))
  expect_equal(result, c(0, 0, 0))
})

test_that("parse_nsf_obligated: result is always numeric class", {
  result <- parse_nsf_obligated(c("$100", NA, ""))
  expect_type(result, "double")
})

# ===========================================================================
# 4. scrape_nih.R — parse_nih_page() and extract_ic_abbrev()
# ===========================================================================

# Mock a minimal NIH Reporter API response
.mock_nih_response <- function(n = 2L) {
  list(
    meta = list(total = n),
    results = lapply(seq_len(n), function(i) {
      list(
        appl_id          = 10000L + i,
        project_title    = paste("Mock Project", i),
        project_num      = paste0("R01AI", 100000L + i),
        project_end_date = "2025-06-30T00:00:00",
        date_added       = "2025-01-15",
        award_amount     = 250000 * i,
        is_active        = FALSE,
        organization     = list(org_name = paste("University", i), org_state = "CA"),
        agency_ic_fundings = list(list(abbreviation = "NIAID")),
        ic_name          = NULL
      )
    })
  )
}

test_that("parse_nih_page: produces tibble with correct columns and types", {
  result <- parse_nih_page(.mock_nih_response(), page = 1L, n_pages = 1L)
  expect_s3_class(result, "tbl_df")
  expect_equal(nrow(result), 2L)
  expect_true(all(c("agency_name", "institute", "notice_date", "source_url",
                     "raw_text_snippet", "grant_number", "org_name") %in% names(result)))
  expect_equal(result$agency_name, c("NIH", "NIH"))
  expect_s3_class(result$notice_date, "Date")
  expect_type(result$award_amount, "double")
})

test_that("parse_nih_page: extracts IC abbreviation from agency_ic_fundings", {
  result <- parse_nih_page(.mock_nih_response(), page = 1L, n_pages = 1L)
  expect_equal(result$institute, c("NIAID", "NIAID"))
})

test_that("extract_ic_abbrev: falls back to ic_name when fundings empty", {
  record <- list(agency_ic_fundings = list(), ic_name = "NCI")
  expect_equal(extract_ic_abbrev(record), "NCI")
})

test_that("extract_ic_abbrev: returns NA when no IC info available", {
  record <- list(agency_ic_fundings = list(), ic_name = NULL)
  expect_identical(extract_ic_abbrev(record), NA_character_)
})

test_that("parse_nih_page: empty results returns empty tibble", {
  empty_resp <- list(meta = list(total = 0), results = list())
  result <- parse_nih_page(empty_resp, page = 1L, n_pages = 1L)
  expect_equal(nrow(result), 0L)
})

# ===========================================================================
# 5. transform.R — internal helpers
# ===========================================================================

test_that(".normalise_awards: maps recipient_name to org_name when org_name absent", {
  awards <- tibble::tibble(
    agency_name    = "NSF",
    award_amount   = 1000,
    action_date    = Sys.Date(),
    grant_number   = "X-001",
    recipient_name = "Acme University"
  )
  result <- .normalise_awards(awards)
  expect_true("org_name" %in% names(result))
  expect_equal(result$org_name, "ACME UNIVERSITY")
})

test_that(".normalise_awards: prefers org_name over recipient_name when both exist", {
  awards <- tibble::tibble(
    agency_name    = "NSF",
    award_amount   = 1000,
    action_date    = Sys.Date(),
    grant_number   = "X-001",
    org_name       = "Beta College",
    recipient_name = "BETA COLLEGE INC"
  )
  result <- .normalise_awards(awards)
  expect_equal(result$org_name, "BETA COLLEGE")
})

test_that(".normalise_awards: org_name is NA when neither org_name nor recipient_name exist", {
  awards <- tibble::tibble(
    agency_name  = "NSF",
    award_amount = 1000,
    action_date  = Sys.Date(),
    grant_number = "X-001"
  )
  result <- .normalise_awards(awards)
  expect_identical(result$org_name, NA_character_)
})

test_that("classify_discrepancy: vectorized over multiple rows", {
  result <- classify_discrepancy(
    flag_active_despite_terminated = c(TRUE, FALSE, FALSE, FALSE, FALSE),
    flag_no_recent_activity        = c(FALSE, TRUE, TRUE, FALSE, FALSE),
    flag_missing_outlay_data       = c(FALSE, FALSE, TRUE, FALSE, FALSE),
    flag_not_in_gw                 = c(FALSE, FALSE, FALSE, TRUE, FALSE)
  )
  expect_equal(result, c("active_despite_terminated", "possible_freeze",
                          "possible_freeze_no_data", "untracked", "normal"))
})

# ===========================================================================
# 6. transform.R — classify_discrepancy() and summarize_discrepancies()
# ===========================================================================

# ---------------------------------------------------------------------------
# classify_discrepancy()
# ---------------------------------------------------------------------------

# Convenience wrapper with default-FALSE flags so tests only set what they care about.
.cd <- function(flag_active_despite_terminated = FALSE,
                flag_no_recent_activity        = FALSE,
                flag_missing_outlay_data       = FALSE,
                flag_not_in_gw                 = FALSE,
                sub_agency                     = NA_character_) {
  classify_discrepancy(
    flag_active_despite_terminated,
    flag_no_recent_activity,
    flag_missing_outlay_data,
    flag_not_in_gw,
    sub_agency = sub_agency
  )
}

test_that("classify_discrepancy: active_despite_terminated when first flag TRUE", {
  result <- classify_discrepancy(
    flag_active_despite_terminated = TRUE,
    flag_no_recent_activity        = FALSE,
    flag_missing_outlay_data       = FALSE,
    flag_not_in_gw                 = FALSE
  )
  expect_equal(result, "active_despite_terminated")
})

test_that("classify_discrepancy: active_despite_terminated wins over possible_freeze", {
  result <- classify_discrepancy(
    flag_active_despite_terminated = TRUE,
    flag_no_recent_activity        = TRUE,
    flag_missing_outlay_data       = FALSE,
    flag_not_in_gw                 = FALSE
  )
  expect_equal(result, "active_despite_terminated")
})

test_that("classify_discrepancy: active_despite_terminated wins over all other flags", {
  result <- classify_discrepancy(
    flag_active_despite_terminated = TRUE,
    flag_no_recent_activity        = TRUE,
    flag_missing_outlay_data       = TRUE,
    flag_not_in_gw                 = TRUE
  )
  expect_equal(result, "active_despite_terminated")
})

test_that("classify_discrepancy: possible_freeze when no_recent_activity TRUE and has outlay data", {
  result <- classify_discrepancy(
    flag_active_despite_terminated = FALSE,
    flag_no_recent_activity        = TRUE,
    flag_missing_outlay_data       = FALSE,
    flag_not_in_gw                 = FALSE
  )
  expect_equal(result, "possible_freeze")
})

test_that("classify_discrepancy: possible_freeze_no_data when no_recent_activity TRUE and missing outlay data", {
  result <- classify_discrepancy(
    flag_active_despite_terminated = FALSE,
    flag_no_recent_activity        = TRUE,
    flag_missing_outlay_data       = TRUE,
    flag_not_in_gw                 = FALSE
  )
  expect_equal(result, "possible_freeze_no_data")
})

test_that("classify_discrepancy: possible_freeze wins over untracked", {
  result <- classify_discrepancy(
    flag_active_despite_terminated = FALSE,
    flag_no_recent_activity        = TRUE,
    flag_missing_outlay_data       = FALSE,
    flag_not_in_gw                 = TRUE
  )
  expect_equal(result, "possible_freeze")
})

test_that("classify_discrepancy: untracked when only not_in_gw is TRUE", {
  result <- classify_discrepancy(
    flag_active_despite_terminated = FALSE,
    flag_no_recent_activity        = FALSE,
    flag_missing_outlay_data       = FALSE,
    flag_not_in_gw                 = TRUE
  )
  expect_equal(result, "untracked")
})

test_that("classify_discrepancy: normal when all flags FALSE", {
  result <- classify_discrepancy(
    flag_active_despite_terminated = FALSE,
    flag_no_recent_activity        = FALSE,
    flag_missing_outlay_data       = FALSE,
    flag_not_in_gw                 = FALSE
  )
  expect_equal(result, "normal")
})

test_that("classify_discrepancy: returns a single character string", {
  result <- classify_discrepancy(TRUE, FALSE, FALSE, FALSE)
  expect_type(result, "character")
  expect_length(result, 1L)
})

test_that("classify_discrepancy: non-research HHS sub_agency prevents possible_freeze → normal", {
  # ACF (index 1) is the canonical non-research sub-agency in the constant
  expect_equal(.cd(flag_no_recent_activity = TRUE,
                   sub_agency = NON_RESEARCH_HHS_SUBAGENCIES[[1]]), "normal")
})

test_that("classify_discrepancy: non-research HHS sub_agency prevents possible_freeze_no_data → normal", {
  # CMS (index 2) with missing outlay data should also resolve to normal
  expect_equal(.cd(flag_no_recent_activity = TRUE, flag_missing_outlay_data = TRUE,
                   sub_agency = NON_RESEARCH_HHS_SUBAGENCIES[[2]]), "normal")
})

test_that("classify_discrepancy: NIH sub_agency still classifies possible_freeze normally", {
  expect_equal(.cd(flag_no_recent_activity = TRUE,
                   sub_agency = "National Institutes of Health"), "possible_freeze")
})

test_that("classify_discrepancy: sub_agency=NA (default) does not suppress possible_freeze", {
  expect_equal(.cd(flag_no_recent_activity = TRUE), "possible_freeze")
})

test_that("classify_discrepancy: non-research sub_agency does NOT suppress active_despite_terminated", {
  # ADT fires before the non-research guard in case_when
  expect_equal(.cd(flag_active_despite_terminated = TRUE,
                   sub_agency = NON_RESEARCH_HHS_SUBAGENCIES[[1]]), "active_despite_terminated")
})

# ---------------------------------------------------------------------------
# summarize_discrepancies()
# ---------------------------------------------------------------------------

# Build a mock joined tibble that would realistically come from join_and_flag()
.mock_joined <- function() {
  tibble::tibble(
    agency_name                    = c("NSF", "NSF", "NIH", "NSF"),
    award_amount                   = c(1e6, 5e5, 2e5, 3e5),
    total_outlays                  = c(50000, 0, 0, 180000),
    discrepancy_type               = c(
      "active_despite_terminated",
      "possible_freeze",
      "untracked",
      "normal"
    ),
    flag_active_despite_terminated = c(TRUE,  FALSE, FALSE, FALSE),
    flag_no_recent_activity        = c(FALSE, TRUE,  FALSE, FALSE),
    flag_not_in_gw                 = c(FALSE, FALSE, TRUE,  FALSE),
    match_method                   = c("exact", "exact", "unmatched_award", "exact")
  )
}

test_that("summarize_discrepancies: excludes 'normal' rows", {
  summary <- summarize_discrepancies(.mock_joined())
  expect_false("normal" %in% summary$discrepancy_type)
})

test_that("summarize_discrepancies: returns one row per agency+discrepancy_type", {
  summary <- summarize_discrepancies(.mock_joined())
  # 3 non-normal rows: NSF/active_despite_terminated, NSF/possible_freeze, NIH/untracked
  expect_equal(nrow(summary), 3L)
})

test_that("summarize_discrepancies: n_grants counts correctly", {
  summary <- summarize_discrepancies(.mock_joined())
  # Each non-normal discrepancy type has exactly 1 row in the mock
  expect_true(all(summary$n_grants == 1L))
})

test_that("summarize_discrepancies: total_award_amount is correct per group", {
  summary <- summarize_discrepancies(.mock_joined())
  nsf_active <- dplyr::filter(summary,
    agency_name == "NSF", discrepancy_type == "active_despite_terminated")
  expect_equal(nsf_active$total_award_amount, 1e6)
})

test_that("summarize_discrepancies: total_outlays sums correctly", {
  summary <- summarize_discrepancies(.mock_joined())
  nsf_active <- dplyr::filter(summary,
    agency_name == "NSF", discrepancy_type == "active_despite_terminated")
  expect_equal(nsf_active$total_outlays, 50000)
})

test_that("summarize_discrepancies: result has required columns", {
  summary <- summarize_discrepancies(.mock_joined())
  expected_cols <- c("agency_name", "discrepancy_type", "n_grants",
                     "total_award_amount", "total_outlays")
  expect_true(all(expected_cols %in% names(summary)))
})

test_that("summarize_discrepancies: all-normal input returns zero-row tibble", {
  all_normal <- tibble::tibble(
    agency_name      = "NSF",
    award_amount     = 100000,
    total_outlays    = 90000,
    discrepancy_type = "normal"
  )
  result <- summarize_discrepancies(all_normal)
  expect_equal(nrow(result), 0L)
})

test_that("summarize_discrepancies: requires agency_name column", {
  df <- .mock_joined()
  # join_and_flag now always produces canonical agency_name (from award side)
  expect_true("agency_name" %in% names(df))
  result <- summarize_discrepancies(df)
  expect_true("agency_name" %in% names(result))
})

# ---------------------------------------------------------------------------
# FUZZY_ORG_DISTANCE and FUZZY_DATE_WINDOW_DAYS constants are sane
# ---------------------------------------------------------------------------

test_that("FUZZY_ORG_DISTANCE is between 0 and 0.5 (not too strict, not too loose)", {
  expect_gt(FUZZY_ORG_DISTANCE, 0)
  expect_lt(FUZZY_ORG_DISTANCE, 0.5)
})

test_that("FUZZY_DATE_WINDOW_DAYS is a positive integer", {
  expect_true(is.numeric(FUZZY_DATE_WINDOW_DAYS))
  expect_gt(FUZZY_DATE_WINDOW_DAYS, 0)
  expect_equal(FUZZY_DATE_WINDOW_DAYS %% 1, 0)  # whole number
})

test_that("FREEZE_RATIO_THRESHOLD is between 0 and 1 exclusive", {
  expect_gt(FREEZE_RATIO_THRESHOLD, 0)
  expect_lt(FREEZE_RATIO_THRESHOLD, 1)
})

# ===========================================================================
# 5. Integration-style tests: validate -> join_and_flag
# ===========================================================================
#
# These tests exercise the full validate -> join_and_flag path using inline
# mock data.  No real network calls are made.
# ---------------------------------------------------------------------------

# Helper: build a terminated notice (notice_date is non-NA = terminated in this pipeline)
.terminated_notice <- function(grant_number, org_name, notice_date = as.Date("2025-02-01")) {
  tibble::tibble(
    agency_name      = "NSF",
    notice_date      = notice_date,
    source_url       = paste0("https://nsf.gov/award/", grant_number),
    raw_text_snippet = paste("Terminated grant", grant_number),
    grant_number     = grant_number,
    org_name         = org_name
  )
}

# Helper: build an award record with controllable financial state
.award_row <- function(grant_number, org_name,
                       award_amount  = 500000,
                       total_outlays = 0,
                       end_date      = Sys.Date() + 365L,
                       action_date   = as.Date("2025-01-15")) {
  tibble::tibble(
    agency_name   = "NSF",
    award_amount  = award_amount,
    action_date   = action_date,
    grant_number  = grant_number,
    org_name      = org_name,
    total_outlays = total_outlays,
    end_date      = end_date
  )
}

test_that("integration: terminated grant with positive outlays flags active_despite_terminated", {
  # A grant whose notice_date is set (= terminated) but USAspending still shows
  # money flowing and the end_date is in the future.
  notices <- validate_notices(.terminated_notice("GR-001", "Acme University"))
  awards  <- validate_awards(.award_row(
    grant_number  = "GR-001",
    org_name      = "Acme University",
    total_outlays = 75000,        # positive outlays — suspicious
    end_date      = Sys.Date() + 180L
  ))

  result <- join_and_flag(notices, awards)

  matched <- dplyr::filter(result, grant_number == "GR-001")
  expect_equal(nrow(matched), 1L)
  expect_equal(matched$discrepancy_type, "active_despite_terminated")
  expect_true(matched$flag_active_despite_terminated)
})

test_that("integration: zero outlays with future end_date flags possible_freeze", {
  # Notice exists (grant terminated) but outlays are zero — possible budget freeze.
  notices <- validate_notices(.terminated_notice("GR-002", "Beta College",
                                                 notice_date = as.Date("2025-02-01")))
  awards  <- validate_awards(.award_row(
    grant_number  = "GR-002",
    org_name      = "Beta College",
    total_outlays = 0,
    end_date      = Sys.Date() + 365L
  ))

  result <- join_and_flag(notices, awards)

  matched <- dplyr::filter(result, grant_number == "GR-002")
  expect_equal(nrow(matched), 1L)
  # Both flags could fire on a terminated+zero-outlay record; active_despite_terminated
  # requires total_outlays > 0, so this should resolve to possible_freeze.
  expect_equal(matched$discrepancy_type, "possible_freeze")
  expect_true(matched$flag_no_recent_activity)
  expect_false(matched$flag_active_despite_terminated)
})

test_that("integration: award with no matching notice is flagged as untracked", {
  # Award exists in USAspending but was never reported in the forensic dataset.
  # Use a *different* grant number in the notice so there is no match.
  # end_date in the past avoids triggering flag_no_recent_activity, which would
  # outrank untracked in the classify_discrepancy precedence.
  notices <- validate_notices(.terminated_notice("GR-NOTICE-ONLY", "Gamma Institute"))
  awards  <- validate_awards(.award_row(
    grant_number  = "GR-AWARD-ONLY",   # deliberately mismatched — will not join
    org_name      = "Delta Institute", # different org — fuzzy join won't catch it either
    total_outlays = 400000,
    end_date      = Sys.Date() - 30L   # closed award — only flag_not_in_gw fires
  ))

  result <- join_and_flag(notices, awards)

  untracked <- dplyr::filter(result, grant_number == "GR-AWARD-ONLY")
  expect_equal(nrow(untracked), 1L)
  expect_equal(untracked$discrepancy_type, "untracked")
  expect_true(untracked$flag_not_in_gw)
})

test_that("integration: matched grant with healthy spending is classified as normal", {
  # A properly matched grant where outlays are well above the freeze threshold
  # and the end_date is in the past (award closed) — should be normal.
  notices <- validate_notices(.terminated_notice(
    "GR-003", "Epsilon Labs",
    notice_date = as.Date("2024-06-01")
  ))
  awards <- validate_awards(.award_row(
    grant_number  = "GR-003",
    org_name      = "Epsilon Labs",
    award_amount  = 200000,
    total_outlays = 195000,        # > FREEZE_RATIO_THRESHOLD
    end_date      = Sys.Date() - 30L  # past end date — award closed
  ))

  result <- join_and_flag(notices, awards)

  matched <- dplyr::filter(result, grant_number == "GR-003")
  expect_equal(nrow(matched), 1L)
  expect_equal(matched$discrepancy_type, "normal")
  expect_false(matched$flag_active_despite_terminated)
  expect_false(matched$flag_no_recent_activity)
  expect_false(matched$flag_not_in_gw)
})

test_that("integration: join_and_flag result has all expected output columns", {
  notices <- validate_notices(.terminated_notice("GR-100", "Test Org"))
  awards  <- validate_awards(.award_row("GR-100", "Test Org", total_outlays = 5000))

  result <- join_and_flag(notices, awards)

  expected_cols <- c(
    "match_method", "outlay_ratio",
    "flag_active_despite_terminated", "flag_no_recent_activity", "flag_not_in_gw",
    "discrepancy_type"
  )
  expect_true(all(expected_cols %in% names(result)))
})

test_that("integration: outlay_ratio computed correctly", {
  notices <- validate_notices(.terminated_notice("GR-101", "Ratio Corp"))
  awards  <- validate_awards(.award_row(
    grant_number  = "GR-101",
    org_name      = "Ratio Corp",
    award_amount  = 1000000,
    total_outlays = 250000
  ))

  result <- join_and_flag(notices, awards)
  matched <- dplyr::filter(result, grant_number == "GR-101")

  expect_equal(matched$outlay_ratio, 0.25, tolerance = 1e-9)
})

test_that("integration: outlay_ratio is NA when award_amount is zero", {
  notices <- validate_notices(.terminated_notice("GR-102", "Zero Inc"))
  awards  <- validate_awards(.award_row(
    grant_number  = "GR-102",
    org_name      = "Zero Inc",
    award_amount  = 0,
    total_outlays = 0
  ))

  result <- join_and_flag(notices, awards)
  matched <- dplyr::filter(result, grant_number == "GR-102")
  expect_true(is.na(matched$outlay_ratio))
})

test_that("integration: multiple notices and awards produce correct row count", {
  notices <- validate_notices(dplyr::bind_rows(
    .terminated_notice("GR-A", "Alpha U"),
    .terminated_notice("GR-B", "Beta U"),
    .terminated_notice("GR-C", "Gamma U")
  ))
  awards <- validate_awards(dplyr::bind_rows(
    .award_row("GR-A", "Alpha U", total_outlays = 10000),
    .award_row("GR-B", "Beta U",  total_outlays = 0),
    .award_row("GR-D", "Delta U", total_outlays = 5000,
               end_date = Sys.Date() - 30L)  # unmatched; past end_date avoids freeze flag
  ))

  result <- join_and_flag(notices, awards)

  # GR-A matched, GR-B matched, GR-C notice unmatched (no award), GR-D award untracked
  # Expected rows: GR-A (exact), GR-B (exact), GR-D (unmatched_award)
  # GR-C notice has no corresponding award and does not appear as an award row
  expect_equal(nrow(result), 3L)

  untracked <- dplyr::filter(result, discrepancy_type == "untracked")
  expect_equal(nrow(untracked), 1L)
  expect_equal(untracked$grant_number, "GR-D")
})

# ===========================================================================
# Robustness guards — prevent recurring bug classes
# ===========================================================================

test_that("_targets.R declares all packages used by R/ modules", {
  # Parse the packages vector from _targets.R
  targets_src <- readLines(file.path(.root, "_targets.R"))
  pkg_lines <- targets_src[grep("packages\\s*=\\s*c\\(", targets_src):
                           grep("^\\)\\)", targets_src)[1]]
  declared <- unlist(regmatches(pkg_lines, gregexpr('"[^"]+"', pkg_lines)))
  declared <- gsub('"', '', declared)

  # Scan R/ files for explicit namespace calls (pkg::fn)
  r_files <- list.files(file.path(.root, "R"), pattern = "[.]R$", full.names = TRUE)
  all_code <- unlist(lapply(r_files, readLines))
  ns_calls <- regmatches(all_code, gregexpr("[a-zA-Z][a-zA-Z0-9.]+::", all_code))
  used_pkgs <- unique(gsub("::", "", unlist(ns_calls)))
  # Exclude base/stats/datasets (always available) and the package itself
  base_pkgs <- c("base", "stats", "datasets", "utils", "methods", "grDevices", "graphics")
  used_pkgs <- setdiff(used_pkgs, base_pkgs)

  missing <- setdiff(used_pkgs, declared)
  expect_true(
    length(missing) == 0L,
    info = sprintf("Packages used in R/ but not declared in _targets.R: %s",
                   paste(missing, collapse = ", "))
  )
})

test_that("no R files use NA_Date_ (not a real R constant)", {
  r_files <- list.files(file.path(.root, "R"), pattern = "[.]R$", full.names = TRUE)
  for (f in r_files) {
    lines <- readLines(f)
    bad <- grep("\\bNA_Date_\\b", lines)
    expect_true(
      length(bad) == 0L,
      info = sprintf("%s uses NA_Date_ on line(s) %s — use as.Date(NA) instead",
                     basename(f), paste(bad, collapse = ", "))
    )
  }
})

test_that("USAspending limit never exceeds API max page size", {
  # build_usaspending_body default should be <= USASPENDING_MAX_PAGE_SIZE
  body <- build_usaspending_body("test", "2025-01-01", "2025-12-31", 1L)
  expect_true(body$limit <= USASPENDING_MAX_PAGE_SIZE)

  # Even if caller passes a huge limit, it gets capped
  body_large <- build_usaspending_body("test", "2025-01-01", "2025-12-31", 1L, limit = 9999L)
  expect_true(body_large$limit <= USASPENDING_MAX_PAGE_SIZE)
})

test_that("NIH pagination respects offset cap", {
  # Verify the constant exists and is 14999
  expect_equal(NIH_MAX_OFFSET, 14999L)
  # Verify page size doesn't exceed API limit
  expect_true(NIH_PAGE_SIZE <= 500L)
})

test_that("USAspending requests 'Start Date'/'End Date' (not 'Period of Performance')", {
  # The API returns null for "Period of Performance Start Date" / "...Current End Date"
  # but populates "Start Date" / "End Date". This was a root cause of 100% missing dates.
  expect_true("Start Date" %in% USASPENDING_FIELDS)
  expect_true("End Date" %in% USASPENDING_FIELDS)
  expect_false("Period of Performance Start Date" %in% USASPENDING_FIELDS)
  expect_false("Period of Performance Current End Date" %in% USASPENDING_FIELDS)
})

test_that("USASPENDING_FIELDS includes the four high-value additional fields", {
  # Recipient UEI: stable identifier replacing deprecated DUNS
  expect_true("Recipient UEI" %in% USASPENDING_FIELDS)
  # Last Modified Date: detect recent admin changes without full transaction scan
  expect_true("Last Modified Date" %in% USASPENDING_FIELDS)
  # def_codes: identifies COVID/IIJA emergency awards (political targeting signal)
  expect_true("def_codes" %in% USASPENDING_FIELDS)
  # generated_internal_id: direct File C lookup key (avoids reconstructing ASST_NON_{id}_{cgac})
  expect_true("generated_internal_id" %in% USASPENDING_FIELDS)
})

test_that("def_codes array collapses to comma-separated string correctly", {
  # Test the collapsing logic used in fetch_usaspending_page() inline
  dc_list <- list("L", "M")
  result  <- paste(unlist(dc_list), collapse = ",")
  expect_equal(result, "L,M")

  # NULL def_codes (no emergency funding) → NA_character_
  dc_null <- NULL
  result_null <- if (is.null(dc_null) || length(dc_null) == 0L) NA_character_
                 else paste(unlist(dc_null), collapse = ",")
  expect_true(is.na(result_null))

  # Single code
  dc_single <- list("B")
  result_single <- paste(unlist(dc_single), collapse = ",")
  expect_equal(result_single, "B")
})

test_that("USASPENDING_FIELDS does not contain deprecated DUNS field", {
  # DUNS is deprecated in favor of UEI as of April 2022
  expect_false("Recipient DUNS Number" %in% USASPENDING_FIELDS)
  expect_true("Recipient UEI" %in% USASPENDING_FIELDS)
})

test_that("no R files use req_body_raw with jsonlite::toJSON", {
  r_files <- list.files(file.path(.root, "R"), pattern = "[.]R$", full.names = TRUE)
  for (f in r_files) {
    lines <- readLines(f)
    bad <- grep("req_body_raw.*toJSON|toJSON.*req_body_raw", lines)
    expect_true(
      length(bad) == 0L,
      info = sprintf("%s uses req_body_raw+toJSON on line(s) %s — use req_body_json() instead",
                     basename(f), paste(bad, collapse = ", "))
    )
  }
})

test_that("NIH scraper deduplicates by grant_number", {
  lines <- readLines(file.path(.root, "R/scrape_nih.R"))
  expect_true(
    any(grepl("distinct.*grant_number", lines)),
    info = "scrape_nih.R must deduplicate by grant_number (pagination overlap bug)"
  )
})

test_that("NIH scraper filters out is_active=TRUE records", {
  lines <- readLines(file.path(.root, "R/scrape_nih.R"))
  expect_true(
    any(grepl("is_active", lines) & grepl("filter", lines)),
    info = "scrape_nih.R must filter out is_active=TRUE (they're not terminated)"
  )
})

test_that("validate_awards adds quality flag columns", {
  # Build minimal awards tibble
  df <- dplyr::tibble(
    agency_name   = c("HHS", "NSF"),
    award_amount  = c(1000, 500),
    total_outlays = c(-100, 900),
    action_date   = as.Date(c("2025-01-01", "2025-06-01")),
    end_date      = as.Date(c("2026-01-01", "2026-06-01")),
    grant_number  = c("G001", "G002")
  )
  result <- suppressMessages(validate_awards(df))
  expect_true("flag_negative_outlay" %in% names(result))
  expect_true("flag_over_disbursed" %in% names(result))
  # The negative outlay should be flagged
  expect_true(result$flag_negative_outlay[1])
  expect_false(result$flag_negative_outlay[2])
})

test_that("org name normalizer handles campus suffixes and punctuation", {
  source(file.path(.root, "R/transform.R"))
  expect_equal(
    .normalise_org("ARIZONA STATE UNIVERSITY-TEMPE CAMPUS"),
    .normalise_org("ARIZONA STATE UNIVERSITY")
  )
  expect_equal(
    .normalise_org("CARNEGIE-MELLON UNIVERSITY"),
    .normalise_org("CARNEGIE MELLON UNIVERSITY")
  )
  expect_equal(
    .normalise_org("THE BROAD INSTITUTE, INC."),
    .normalise_org("BROAD INSTITUTE")
  )
  expect_equal(
    .normalise_org("BOSTON UNIVERSITY (CHARLES RIVER CAMPUS)"),
    .normalise_org("BOSTON UNIVERSITY")
  )
  expect_equal(
    .normalise_org("AUBURN UNIVERSITY AT AUBURN"),
    .normalise_org("AUBURN UNIVERSITY")
  )
})

test_that("USAspending description cleaning strips HTML and CDATA", {
  # Simulate the cleaning logic from fetch_usaspending_page
  descs <- c(
    "DESCRIPTION:THIS AWARD PROVIDES FUNDING",
    "THE DIABETES <![CDATA[MATCH INITIATIVE]]>",
    "NORMAL DESCRIPTION",
    "<b>BOLD</b> text here"
  )
  descs <- sub("^DESCRIPTION:\\s*", "", descs)
  descs <- gsub("<!\\[CDATA\\[|\\]\\]>", "", descs)
  descs <- gsub("<[^>]+>", "", descs)
  expect_equal(descs[1], "THIS AWARD PROVIDES FUNDING")
  expect_equal(descs[2], "THE DIABETES MATCH INITIATIVE")
  expect_equal(descs[3], "NORMAL DESCRIPTION")
  expect_equal(descs[4], "BOLD text here")
})

test_that("validate_awards flags negative and over-disbursed outlays", {
  df <- dplyr::tibble(
    agency_name   = c("HHS", "EPA", "NSF"),
    award_amount  = c(1000, 500, 200),
    total_outlays = c(-100, 1000, 100),
    action_date   = rep(as.Date("2025-01-01"), 3),
    end_date      = rep(as.Date("2026-01-01"), 3),
    grant_number  = c("A", "B", "C")
  )
  result <- suppressMessages(validate_awards(df))
  expect_true(result$flag_negative_outlay[1])
  expect_false(result$flag_negative_outlay[2])
  expect_true(result$flag_over_disbursed[2])   # 1000 > 500 * 1.5
  expect_false(result$flag_over_disbursed[3])  # 100 < 200 * 1.5
})

test_that("validate_awards flags inverted dates", {
  df <- dplyr::tibble(
    agency_name   = c("HHS", "NSF"),
    award_amount  = c(1000, 500),
    total_outlays = c(500, 200),
    action_date   = as.Date(c("2025-06-01", "2025-01-01")),
    end_date      = as.Date(c("2024-01-01", "2026-01-01")),  # first is inverted
    grant_number  = c("A", "B")
  )
  result <- suppressMessages(validate_awards(df))
  expect_true(result$flag_date_inverted[1])
  expect_false(result$flag_date_inverted[2])
})

test_that("distinctive token filter rejects shared-prefix false positives", {
  source(file.path(.root, "R/transform.R"))
  # Same distinctive token = TRUE
  expect_true(.share_distinctive_token("UNIVERSITY OF CHICAGO", "UNIVERSITY OF CHICAGO"))
  expect_true(.share_distinctive_token("HARVARD UNIVERSITY", "HARVARD"))
  expect_true(.share_distinctive_token("STANFORD UNIVERSITY", "STANFORD RESEARCH"))
  # No shared distinctive token = FALSE (these are false positives)
  expect_false(.share_distinctive_token("UNIVERSITY OF CHICAGO", "UNIVERSITY OF UTAH"))
  expect_false(.share_distinctive_token("UNIVERSITY OF MIAMI", "UNIVERSITY OF WYOMING"))
  expect_false(.share_distinctive_token("UNIVERSITY OF IOWA", "UNIVERSITY OF ILLINOIS"))
})

test_that("fuzzy join distance threshold is strict enough", {
  # After audit: 0.15 caused 71% false positive rate, tightened to 0.08
  source(file.path(.root, "R/transform.R"))
  expect_true(FUZZY_ORG_DISTANCE <= 0.10)
})

# ---------------------------------------------------------------------------
# elapsed_ratio — grant lifecycle context
# ---------------------------------------------------------------------------

test_that("integration: elapsed_ratio is in join_and_flag output", {
  notices <- validate_notices(.terminated_notice("ER-001", "Elapsed Corp"))
  awards  <- validate_awards(.award_row("ER-001", "Elapsed Corp",
    action_date = Sys.Date() - 365L, end_date = Sys.Date() + 365L))
  result <- join_and_flag(notices, awards)
  expect_true("elapsed_ratio" %in% names(result))
})

test_that("integration: elapsed_ratio is between 0 and 1 for active awards", {
  notices <- validate_notices(.terminated_notice("ER-002", "Midlife Corp"))
  awards  <- validate_awards(.award_row("ER-002", "Midlife Corp",
    action_date = Sys.Date() - 180L,
    end_date    = Sys.Date() + 180L))  # 50% through
  result <- join_and_flag(notices, awards)
  matched <- dplyr::filter(result, grant_number == "ER-002")
  expect_gte(matched$elapsed_ratio, 0.45)
  expect_lte(matched$elapsed_ratio, 0.55)
})

test_that("integration: elapsed_ratio is NA when dates are missing", {
  notices <- validate_notices(.terminated_notice("ER-003", "No Date Corp"))
  awards  <- validate_awards(dplyr::tibble(
    agency_name   = "NSF",
    award_amount  = 100000,
    action_date   = as.Date(NA),
    end_date      = as.Date(NA),
    grant_number  = "ER-003",
    org_name      = "No Date Corp",
    total_outlays = 0
  ))
  result <- join_and_flag(notices, awards)
  matched <- dplyr::filter(result, grant_number == "ER-003")
  expect_true(is.na(matched$elapsed_ratio))
})

test_that("integration: elapsed_ratio capped at 1.0 for expired awards", {
  notices <- validate_notices(.terminated_notice("ER-004", "Expired Corp"))
  awards  <- validate_awards(.award_row("ER-004", "Expired Corp",
    action_date = Sys.Date() - 730L,   # 2 years ago
    end_date    = Sys.Date() - 365L))  # ended 1 year ago
  result <- join_and_flag(notices, awards)
  matched <- dplyr::filter(result, grant_number == "ER-004")
  expect_equal(matched$elapsed_ratio, 1.0)
})

test_that("integration: elapsed_ratio floored at 0.0 for future-start awards", {
  notices <- validate_notices(.terminated_notice("ER-005", "Future Corp"))
  awards  <- validate_awards(.award_row("ER-005", "Future Corp",
    action_date = Sys.Date() + 30L,   # starts in the future
    end_date    = Sys.Date() + 395L))
  result <- join_and_flag(notices, awards)
  matched <- dplyr::filter(result, grant_number == "ER-005")
  expect_equal(matched$elapsed_ratio, 0.0)
})

# ---------------------------------------------------------------------------
# flag_amount_mismatch — notice vs official award amount concordance
# ---------------------------------------------------------------------------

test_that("integration: flag_amount_mismatch is in join_and_flag output", {
  notices <- validate_notices(.terminated_notice("AM-001", "Amount Corp"))
  awards  <- validate_awards(.award_row("AM-001", "Amount Corp"))
  result <- join_and_flag(notices, awards)
  expect_true("flag_amount_mismatch" %in% names(result))
})

test_that("integration: flag_amount_mismatch TRUE when exact-match amounts differ >25%", {
  # Both sides have grant_number "AM-002" so it will be an exact match.
  # notice says $1M, USAspending says $300K — >25% discrepancy.
  notices <- validate_notices(dplyr::tibble(
    agency_name      = "NSF",
    notice_date      = as.Date("2025-02-01"),
    source_url       = "https://nsf.gov/award/AM-002",
    raw_text_snippet = "Test",
    grant_number     = "AM-002",
    org_name         = "Mismatch Corp",
    award_amount     = 1000000
  ))
  awards <- validate_awards(.award_row("AM-002", "Mismatch Corp", award_amount = 300000))
  result <- join_and_flag(notices, awards)
  matched <- dplyr::filter(result, grant_number == "AM-002")
  expect_equal(matched$match_method, "exact")
  expect_true(matched$flag_amount_mismatch)
})

test_that("integration: flag_amount_mismatch FALSE when exact-match amounts agree within 25%", {
  notices <- validate_notices(dplyr::tibble(
    agency_name      = "NSF",
    notice_date      = as.Date("2025-02-01"),
    source_url       = "https://nsf.gov/award/AM-003",
    raw_text_snippet = "Test",
    grant_number     = "AM-003",
    org_name         = "Close Corp",
    award_amount     = 500000
  ))
  awards <- validate_awards(.award_row("AM-003", "Close Corp", award_amount = 510000))
  result <- join_and_flag(notices, awards)
  matched <- dplyr::filter(result, grant_number == "AM-003")
  expect_equal(matched$match_method, "exact")
  expect_false(matched$flag_amount_mismatch)
})

test_that("integration: flag_amount_mismatch FALSE for fuzzy matches (cross-grant comparison invalid)", {
  # Different grant numbers, same org. Will fuzzy-match. Amount comparison meaningless.
  notices <- validate_notices(dplyr::tibble(
    agency_name      = "NSF",
    notice_date      = as.Date("2025-02-01"),
    source_url       = "https://nsf.gov/award/AM-NOTICE",
    raw_text_snippet = "Test",
    grant_number     = NA_character_,  # no grant_number forces fuzzy path
    org_name         = "Stanford University",
    award_amount     = 5000000  # very different from award
  ))
  awards <- validate_awards(dplyr::tibble(
    agency_name   = "NSF",
    award_amount  = 100000,
    action_date   = as.Date("2025-01-15"),
    grant_number  = NA_character_,
    org_name      = "Stanford University",
    total_outlays = 0,
    end_date      = Sys.Date() + 365L
  ))
  result <- join_and_flag(notices, awards)
  # If a fuzzy match occurs, the flag should still be FALSE for it
  fuzzy_rows <- dplyr::filter(result, match_method == "fuzzy")
  expect_true(all(!fuzzy_rows$flag_amount_mismatch))
})

test_that("integration: flag_amount_mismatch FALSE for unmatched awards (no notice amount)", {
  notices <- validate_notices(.terminated_notice("AM-NOTICE", "Notice Only Corp"))
  awards  <- validate_awards(.award_row("AM-AWARD-ONLY", "Different Corp",
    end_date = Sys.Date() - 30L))
  result <- join_and_flag(notices, awards)
  orphan <- dplyr::filter(result, grant_number == "AM-AWARD-ONLY")
  expect_false(orphan$flag_amount_mismatch)
})

# ---------------------------------------------------------------------------
# CFDA-agency cross-validation
# ---------------------------------------------------------------------------

test_that("CFDA-agency check catches mismatched prefix", {
  source(file.path(.root, "R/validate.R"))
  # 93.xxx should be HHS, not NSF
  expect_true(.check_cfda_agency("93.395", "National Science Foundation"))
  # 47.xxx should be NSF, not HHS
  expect_true(.check_cfda_agency("47.041", "Department of Health and Human Services"))
})

test_that("CFDA-agency check passes when prefix matches correctly", {
  source(file.path(.root, "R/validate.R"))
  expect_false(.check_cfda_agency("93.395", "Department of Health and Human Services"))
  expect_false(.check_cfda_agency("47.041", "National Science Foundation"))
  expect_false(.check_cfda_agency("66.001", "Environmental Protection Agency"))
})

test_that("CFDA-agency check returns FALSE for NA or unknown prefix", {
  source(file.path(.root, "R/validate.R"))
  expect_false(.check_cfda_agency(NA_character_, "NSF"))
  expect_false(.check_cfda_agency("99.999", "Unknown Agency"))
})

# ---------------------------------------------------------------------------
# Zero award, future date, duplicate detection
# ---------------------------------------------------------------------------

test_that("validate_awards flags zero-dollar awards", {
  df <- dplyr::tibble(
    agency_name   = c("HHS", "NSF"),
    award_amount  = c(0, 500000),
    total_outlays = c(0, 200000),
    action_date   = rep(as.Date("2025-01-01"), 2),
    end_date      = rep(as.Date("2026-01-01"), 2),
    grant_number  = c("Z001", "Z002")
  )
  result <- suppressMessages(validate_awards(df))
  expect_true("flag_zero_award" %in% names(result))
  expect_true(result$flag_zero_award[1])
  expect_false(result$flag_zero_award[2])
})

test_that("validate_awards flags future action dates", {
  df <- dplyr::tibble(
    agency_name   = c("HHS", "NSF"),
    award_amount  = c(100000, 200000),
    total_outlays = c(50000, 100000),
    action_date   = as.Date(c("2099-01-01", "2025-01-01")),
    end_date      = as.Date(c("2100-01-01", "2026-01-01")),
    grant_number  = c("F001", "F002")
  )
  result <- suppressMessages(validate_awards(df))
  expect_true("flag_future_date" %in% names(result))
  expect_true(result$flag_future_date[1])
  expect_false(result$flag_future_date[2])
})

test_that("validate_awards detects CFDA-agency mismatch via flag", {
  df <- dplyr::tibble(
    agency_name   = c("Department of Health and Human Services", "National Science Foundation"),
    award_amount  = c(100000, 200000),
    total_outlays = c(50000, 100000),
    action_date   = rep(as.Date("2025-01-01"), 2),
    end_date      = rep(as.Date("2026-01-01"), 2),
    grant_number  = c("C001", "C002"),
    cfda_number   = c("47.041", "47.041")  # NSF prefix on HHS award = mismatch
  )
  result <- suppressMessages(validate_awards(df))
  expect_true(result$flag_cfda_mismatch[1])  # 47 prefix but HHS agency
  expect_false(result$flag_cfda_mismatch[2]) # 47 prefix and NSF agency
})

# ---------------------------------------------------------------------------
# State code validation in notices
# ---------------------------------------------------------------------------

test_that("validate_notices flags invalid state codes", {
  df <- tibble::tibble(
    agency_name      = c("NIH", "NIH", "NIH", "NIH"),
    notice_date      = rep(as.Date("2025-01-01"), 4),
    source_url       = rep("https://example.com", 4),
    raw_text_snippet = rep("Test", 4),
    org_state        = c("CA", "XX", "PR", "ON")  # CA valid, XX invalid, PR territory, ON Canadian
  )
  result <- suppressMessages(validate_notices(df))
  expect_true("flag_invalid_state" %in% names(result))
  expect_false(result$flag_invalid_state[1])  # CA is valid US state
  expect_true(result$flag_invalid_state[2])   # XX is truly invalid
  expect_false(result$flag_invalid_state[3])  # PR is valid territory
  expect_false(result$flag_invalid_state[4])  # ON is Canadian (not invalid, just international)
})

test_that("validate_notices detects international grants via Canadian province codes", {
  df <- tibble::tibble(
    agency_name      = c("NIH", "NIH", "NIH"),
    notice_date      = rep(as.Date("2025-01-01"), 3),
    source_url       = rep("https://example.com", 3),
    raw_text_snippet = rep("Test", 3),
    org_state        = c("BC", "CA", "QC")
  )
  result <- suppressMessages(validate_notices(df))
  expect_true("flag_international" %in% names(result))
  expect_true(result$flag_international[1])   # BC = British Columbia
  expect_false(result$flag_international[2])  # CA = California (not international)
  expect_true(result$flag_international[3])   # QC = Quebec
})

test_that("validate_notices handles missing org_state column gracefully", {
  df <- .valid_notices()  # no org_state column
  result <- suppressMessages(validate_notices(df))
  expect_true("flag_invalid_state" %in% names(result))
  expect_false(result$flag_invalid_state[1])  # all FALSE when column absent
})

test_that("VALID_STATE_CODES includes all 50 states plus DC and territories", {
  source(file.path(.root, "R/validate.R"))
  expect_true("CA" %in% .VALID_STATE_CODES)
  expect_true("NY" %in% .VALID_STATE_CODES)
  expect_true("DC" %in% .VALID_STATE_CODES)
  expect_true("PR" %in% .VALID_STATE_CODES)
  expect_true("GU" %in% .VALID_STATE_CODES)
  expect_length(.VALID_STATE_CODES, 56L)  # 50 states + DC + 5 territories
})

# ---------------------------------------------------------------------------
# Grant number format validation
# ---------------------------------------------------------------------------

test_that("validate_notices flags malformed NSF grant numbers", {
  df <- tibble::tibble(
    agency_name      = c("NSF", "NSF", "NSF"),
    notice_date      = rep(as.Date("2025-01-01"), 3),
    source_url       = rep("https://example.com", 3),
    raw_text_snippet = rep("Test", 3),
    grant_number     = c("2301234", "ABC", "12345678")  # valid, invalid, too long
  )
  result <- suppressMessages(validate_notices(df))
  expect_true("flag_bad_grant_number" %in% names(result))
  expect_false(result$flag_bad_grant_number[1])  # 7 digits = valid NSF
  expect_true(result$flag_bad_grant_number[2])   # letters = invalid NSF
  expect_true(result$flag_bad_grant_number[3])   # 8 digits = invalid NSF
})

test_that("validate_notices accepts valid NIH grant number formats", {
  df <- tibble::tibble(
    agency_name      = c("NIH", "NIH"),
    notice_date      = rep(as.Date("2025-01-01"), 2),
    source_url       = rep("https://example.com", 2),
    raw_text_snippet = rep("Test", 2),
    grant_number     = c("1R01AI123456-01", "5F30EY033692-02")
  )
  result <- suppressMessages(validate_notices(df))
  expect_false(result$flag_bad_grant_number[1])
  expect_false(result$flag_bad_grant_number[2])
})

# ===========================================================================
# fetch_gw.R — File C outlay parser
# ===========================================================================

test_that("parse_file_c_outlays parses standard format", {
  input <- "- Oct/Nov 2024: $5,834,240\n- Dec 2024: $1,142,547"
  result <- parse_file_c_outlays(input)
  expect_equal(nrow(result), 2L)
  expect_equal(result$amount[1], 5834240)
  expect_equal(result$amount[2], 1142547)
  expect_s3_class(result$period_date, "Date")
})

test_that("parse_file_c_outlays handles single period", {
  result <- parse_file_c_outlays("- Jan 2025: $100")
  expect_equal(nrow(result), 1L)
  expect_equal(result$amount, 100)
  expect_equal(result$period, "Jan 2025")
})

test_that("parse_file_c_outlays returns empty tibble for NA/empty input", {
  expect_equal(nrow(parse_file_c_outlays(NA_character_)), 0L)
  expect_equal(nrow(parse_file_c_outlays("")), 0L)
  expect_equal(nrow(parse_file_c_outlays("  ")), 0L)
})

test_that("parse_file_c_outlays handles zero amounts", {
  result <- parse_file_c_outlays("- Mar 2025: $0")
  expect_equal(nrow(result), 1L)
  expect_equal(result$amount, 0)
})

test_that("parse_file_c_outlays handles combined month periods", {
  result <- parse_file_c_outlays("- Oct/Nov 2024: $500,000")
  expect_equal(nrow(result), 1L)
  expect_equal(result$period, "Oct/Nov 2024")
  # period_date should be first month
  expect_equal(format(result$period_date, "%m"), "10")
})

test_that(".parse_period_to_date converts month-year strings", {
  dates <- .parse_period_to_date(c("Jan 2025", "Dec 2024", "Oct/Nov 2024"))
  expect_equal(dates[1], as.Date("2025-01-01"))
  expect_equal(dates[2], as.Date("2024-12-01"))
  expect_equal(dates[3], as.Date("2024-10-01"))
})

# ===========================================================================
# calibrate_freeze.R
# ===========================================================================

test_that("join_gw_usaspending joins on award ID", {
  gw <- tibble::tibble(
    gw_award_id = c("R01AI123456", "R01MH999999"),
    gw_status = c("Frozen", "Terminated"),
    ever_frozen = c(TRUE, FALSE)
  )
  ours <- tibble::tibble(
    grant_number = c("R01AI123456", "U01CA000001"),
    outlay_ratio = c(0.05, 0.80),
    discrepancy_type = c("possible_freeze", "normal"),
    award_amount = c(500000, 1000000)
  )
  result <- suppressMessages(join_gw_usaspending(gw, ours))
  expect_equal(nrow(result), 1L)
  expect_equal(result$gw_award_id, "R01AI123456")
})

test_that("compute_calibration_features creates expected columns", {
  joined <- tibble::tibble(
    gw_award_id = "R01AI123456",
    gw_status = "\U0001f9ca Frozen Funding",
    ever_frozen = TRUE,
    targeted_start_date = as.Date("2025-03-01"),
    targeted_end_date = as.Date(NA),
    file_c_outlays_raw = "- Jan 2025: $100",
    gw_total_award = 500000,
    activity_code = "R01",
    last_payment_date = as.Date("2025-01-15"),
    outlay_ratio = 0.05,
    elapsed_ratio = 0.30,
    discrepancy_type = "possible_freeze",
    freeze_confidence = "high",
    days_since_last_transaction = 200L
  )
  result <- suppressMessages(compute_calibration_features(joined))
  expect_true("gw_frozen" %in% names(result))
  expect_true("activity_code_group" %in% names(result))
  expect_true(result$gw_frozen)
  expect_equal(result$activity_code_group, "R")
})

test_that("evaluate_heuristic returns expected structure", {
  cal_data <- tibble::tibble(
    gw_frozen = c(TRUE, TRUE, FALSE, FALSE, TRUE),
    our_outlay_ratio = c(0.02, 0.05, 0.50, 0.80, 0.30),
    our_elapsed_ratio = c(0.5, 0.7, 0.3, 0.9, 0.6),
    our_freeze_flag = c(TRUE, TRUE, FALSE, FALSE, FALSE),
    our_freeze_confidence = c("high", "high", "low", "low", "medium"),
    org_name = rep("TEST UNIVERSITY", 5),
    activity_code_group = rep("R", 5),
    gw_status_detail = c("Frozen", "Frozen", "Normal", "Normal", "Frozen"),
    gw_award_id = paste0("R01AI", 1:5),
    discrepancy_type = c("possible_freeze", "possible_freeze", "normal", "normal", "normal"),
    elapsed_ratio = c(0.5, 0.7, 0.3, 0.9, 0.6),
    award_amount = rep(500000, 5)
  )
  result <- suppressMessages(evaluate_heuristic(cal_data))
  expect_type(result, "list")
  expect_true("confusion_matrix" %in% names(result))
  expect_true("threshold_sweep" %in% names(result))
  expect_true("optimal_threshold" %in% names(result))
  expect_true("precision" %in% names(result))
  expect_true("recall" %in% names(result))
})

test_that(".compute_auc returns sensible values", {
  # Perfect separation
  expect_equal(.compute_auc(c(0.9, 0.8, 0.1, 0.2), c(1, 1, 0, 0)), 1.0)
  # Random
  expect_true(.compute_auc(c(0.5, 0.5, 0.5, 0.5), c(1, 1, 0, 0)) == 0.5)
  # Edge: empty

  expect_true(is.na(.compute_auc(numeric(0), numeric(0))))
})

# ===========================================================================
# De-obligation detection (transform.R)
# ===========================================================================

test_that("detect_deobligations identifies negative obligations", {
  txns <- tibble::tibble(
    grant_number = c("R01AI1", "R01AI1", "R01AI1", "R01AI2"),
    transaction_date = as.Date(c("2025-01-15", "2025-02-15", "2025-03-15", "2025-01-20")),
    obligation_amount = c(-5000, -3000, 1000, -2000),
    transaction_desc = rep("test", 4),
    action_type = rep("B", 4),
    modification_number = rep("1", 4)
  )
  result <- suppressMessages(detect_deobligations(txns, min_amount = 1000, min_events = 2L))
  # R01AI1 has 2 de-obligations > $1000, R01AI2 has 1
  expect_equal(nrow(result), 2L)
  flagged <- result |> dplyr::filter(deobligation_flag)
  expect_equal(nrow(flagged), 1L)
  expect_equal(flagged$grant_number, "R01AI1")
  expect_equal(flagged$n_deobligations, 2L)
  expect_true(flagged$total_deobligated < 0)
})

test_that("detect_deobligations handles empty transactions", {
  result <- suppressMessages(detect_deobligations(
    dplyr::tibble(
      grant_number = character(0), transaction_date = as.Date(character(0)),
      obligation_amount = double(0), transaction_desc = character(0),
      action_type = character(0), modification_number = character(0)
    )
  ))
  expect_equal(nrow(result), 0L)
})

test_that("detect_deobligations ignores small adjustments", {
  txns <- tibble::tibble(
    grant_number = "R01AI1",
    transaction_date = as.Date("2025-01-15"),
    obligation_amount = -500,  # below default threshold of 1000
    transaction_desc = "test",
    action_type = "B",
    modification_number = "1"
  )
  result <- suppressMessages(detect_deobligations(txns))
  expect_equal(nrow(result), 0L)
})

test_that("detect_deobligation_spikes aggregates by agency-month", {
  txns <- tibble::tibble(
    grant_number = c("R01AI1", "R01AI2", "R01AI3", "R01AI4"),
    transaction_date = as.Date(c("2025-01-15", "2025-01-20", "2025-01-25", "2025-02-15")),
    obligation_amount = c(-5000, -3000, -4000, -1000),
    transaction_desc = rep("test", 4),
    action_type = rep("B", 4),
    modification_number = rep("1", 4)
  )
  discrepancies <- tibble::tibble(
    grant_number = c("R01AI1", "R01AI2", "R01AI3", "R01AI4"),
    agency_name = rep("Department of Health and Human Services", 4)
  )
  result <- suppressMessages(detect_deobligation_spikes(txns, discrepancies))
  expect_true(nrow(result) > 0L)
  expect_true("year_month" %in% names(result))
  expect_true("spike_flag" %in% names(result))
})

# ===========================================================================
# Subaward analysis (transform.R)
# ===========================================================================

test_that("analyze_subaward_flow detects frozen grants with subawards", {
  subs <- tibble::tibble(
    subaward_id = c("SUB1", "SUB2"),
    subawardee_name = c("SMALL COLLEGE", "RESEARCH INST"),
    subaward_date = as.Date(c("2025-02-01", "2025-03-01")),
    subaward_amount = c(50000, 75000),
    prime_award_id = c("R01AI1", "R01AI1"),
    prime_recipient = c("BIG UNIVERSITY", "BIG UNIVERSITY"),
    agency_name = rep("HHS", 2),
    sub_agency = rep("NIH", 2)
  )
  disc <- tibble::tibble(
    grant_number = c("R01AI1", "R01AI2"),
    discrepancy_type = c("possible_freeze", "normal"),
    outlay_ratio = c(0.03, 0.85),
    freeze_confidence = c("high", NA),
    award_amount = c(1000000, 500000)
  )
  result <- suppressMessages(analyze_subaward_flow(subs, disc))
  expect_equal(result$n_subawards, 2L)
  expect_equal(nrow(result$frozen_with_subawards), 1L)
  expect_equal(result$frozen_with_subawards$prime_award_id, "R01AI1")
  expect_equal(result$frozen_with_subawards$total_subaward_amount, 125000)
  expect_equal(nrow(result$downstream_institutions), 2L)
})

test_that("analyze_subaward_flow handles empty subawards", {
  result <- suppressMessages(analyze_subaward_flow(
    dplyr::tibble(
      subaward_id = character(0), subawardee_name = character(0),
      subaward_date = as.Date(character(0)), subaward_amount = double(0),
      prime_award_id = character(0), prime_recipient = character(0),
      agency_name = character(0), sub_agency = character(0)
    ),
    dplyr::tibble(grant_number = "X", discrepancy_type = "normal",
                  outlay_ratio = 0.5, freeze_confidence = NA, award_amount = 100)
  ))
  expect_equal(result$n_subawards, 0L)
})


# ===========================================================================
# fetch_usaspending_budget.R — CFDA, award flow, agency obligations
# ===========================================================================
test_that(".empty_cfda_tibble has correct schema", {
  tbl <- .empty_cfda_tibble()
  expect_s3_class(tbl, "tbl_df")
  expect_equal(nrow(tbl), 0L)
  expect_type(tbl$agency_label,      "character")
  expect_type(tbl$cfda_code,         "character")
  expect_type(tbl$cfda_name,         "character")
  expect_type(tbl$obligation_amount, "double")
})

test_that("SPENDING_BY_CATEGORY_BASE points to correct endpoint", {
  expect_true(grepl("spending_by_category", SPENDING_BY_CATEGORY_BASE))
  expect_true(grepl("api.usaspending.gov", SPENDING_BY_CATEGORY_BASE))
})

# ===========================================================================
# fetch_award_obligations_flow() helpers
# (fetch_usaspending_budget.R — spending_over_time new grant flow)
# ===========================================================================

test_that(".empty_award_flow_tibble has correct schema", {
  tbl <- .empty_award_flow_tibble()
  expect_s3_class(tbl, "tbl_df")
  expect_equal(nrow(tbl), 0L)
  expect_type(tbl$agency,                    "character")
  expect_type(tbl$fiscal_year,               "integer")
  expect_type(tbl$fiscal_period,             "integer")
  expect_type(tbl$monthly_grant_obligations, "double")
})

test_that(".parse_spending_over_time returns empty tibble for empty results", {
  raw <- list(results = list(), group = "month")
  result <- .parse_spending_over_time(raw, "National Science Foundation")
  expect_s3_class(result, "tbl_df")
  expect_equal(nrow(result), 0L)
})

test_that(".parse_spending_over_time correctly maps fiscal year and period", {
  # month=1 means fiscal P1 (October), fiscal_year="2026" means FY2026
  raw <- list(
    results = list(
      list(
        time_period = list(fiscal_year = "2026", month = "1"),
        Grant_Obligations = 0.0,
        aggregated_amount = 0.0
      ),
      list(
        time_period = list(fiscal_year = "2026", month = "2"),
        Grant_Obligations = 668550.0,
        aggregated_amount = 668550.0
      )
    )
  )
  result <- .parse_spending_over_time(raw, "National Science Foundation")
  expect_equal(nrow(result), 2L)
  expect_equal(result$fiscal_year,   c(2026L, 2026L))
  expect_equal(result$fiscal_period, c(1L,    2L))       # fiscal months, not calendar
  expect_equal(result$monthly_grant_obligations, c(0.0, 668550.0))
  expect_equal(result$agency, rep("National Science Foundation", 2L))
})

test_that(".parse_spending_over_time handles NULL Grant_Obligations as NA", {
  raw <- list(
    results = list(
      list(
        time_period = list(fiscal_year = "2026", month = "3"),
        Grant_Obligations = NULL,
        aggregated_amount = NULL
      )
    )
  )
  result <- .parse_spending_over_time(raw, "NSF")
  expect_equal(nrow(result), 1L)
  expect_true(is.na(result$monthly_grant_obligations))
})

test_that("SPENDING_OVER_TIME_URL points to correct endpoint", {
  expect_true(grepl("spending_over_time", SPENDING_OVER_TIME_URL))
  expect_true(grepl("api.usaspending.gov", SPENDING_OVER_TIME_URL))
})

test_that("GRANT_AWARD_TYPE_CODES includes grants and cooperative agreements", {
  expect_true("02" %in% GRANT_AWARD_TYPE_CODES)  # block grants
  expect_true("03" %in% GRANT_AWARD_TYPE_CODES)  # formula grants
  expect_true("04" %in% GRANT_AWARD_TYPE_CODES)  # project grants
  expect_true("05" %in% GRANT_AWARD_TYPE_CODES)  # cooperative agreements
})

# ===========================================================================
# fetch_recipient_compression() — institution-level targeting detection
# (fetch_usaspending_budget.R)
# ===========================================================================

test_that(".empty_compression_tibble has correct schema", {
  tbl <- .empty_compression_tibble()
  expect_equal(nrow(tbl), 0L)
  expect_true(is.character(tbl$recipient_name))
  expect_true(is.character(tbl$recipient_id))
  expect_true(is.double(tbl$baseline_M))
  expect_true(is.double(tbl$current_M))
  expect_true(is.double(tbl$yoy_pct))
  expect_true(is.double(tbl$drop_M))
  expect_true(is.logical(tbl$below_cutoff))
  expect_true(is.double(tbl$cutoff_floor_M))
  expect_true(is.character(tbl$join_method))
})

test_that(".empty_recipient_top_n has correct schema", {
  tbl <- .empty_recipient_top_n()
  expect_equal(nrow(tbl), 0L)
  expect_true(is.character(tbl$recipient_id))
  expect_true(is.character(tbl$recipient_name))
  expect_true(is.double(tbl$amount_M))
})

test_that("recipient_id join succeeds: matched row has join_method=recipient_id, not below_cutoff", {
  # Exercise the join path using the same logic as fetch_recipient_compression()
  baseline <- dplyr::tibble(
    recipient_id   = c("uuid-A", "uuid-B"),
    recipient_name = c("ALPHA UNIV", "BETA HOSPITAL"),
    amount_M       = c(80.0, 40.0)
  )
  current <- dplyr::tibble(
    recipient_id   = "uuid-A",
    recipient_name = "ALPHA UNIV",
    amount_M       = 50.0
  )

  id_matched <- dplyr::inner_join(
    baseline |> dplyr::rename(baseline_M = amount_M),
    current  |> dplyr::select(recipient_id, current_M = amount_M),
    by = "recipient_id"
  ) |> dplyr::mutate(join_method = "recipient_id")

  expect_equal(nrow(id_matched), 1L)
  expect_equal(id_matched$join_method, "recipient_id")
  expect_equal(id_matched$current_M, 50.0)

  # uuid-B is unmatched → should become below_cutoff
  unmatched <- baseline[!baseline$recipient_id %in% id_matched$recipient_id, ]
  expect_equal(nrow(unmatched), 1L)
  expect_equal(unmatched$recipient_name, "BETA HOSPITAL")
})

test_that("recipient compression yoy_pct computed correctly", {
  # Simulate the join output: one matched institution
  baseline <- dplyr::tibble(
    recipient_id   = "uuid-A",
    recipient_name = "UNIVERSITY OF EXAMPLE",
    amount_M       = 100.0
  )
  current <- dplyr::tibble(
    recipient_id   = "uuid-A",
    recipient_name = "UNIVERSITY OF EXAMPLE",
    amount_M       = 60.0
  )
  cutoff_floor <- min(current$amount_M, na.rm = TRUE)

  joined <- dplyr::inner_join(
    baseline |> dplyr::rename(baseline_M = amount_M),
    current  |> dplyr::select(recipient_id, current_M = amount_M),
    by = "recipient_id"
  ) |>
    dplyr::mutate(
      below_cutoff   = FALSE,
      yoy_pct        = round((current_M - baseline_M) / baseline_M * 100, 1),
      drop_M         = round(baseline_M - current_M, 2),
      cutoff_floor_M = cutoff_floor,
      join_method    = "recipient_id"
    )

  expect_equal(joined$yoy_pct, -40.0)
  expect_equal(joined$drop_M, 40.0)
  expect_false(joined$below_cutoff)
})

test_that("below_cutoff flagged when institution absent from current top-N", {
  # An institution in baseline but not current should get below_cutoff = TRUE
  baseline <- dplyr::tibble(
    recipient_id   = "uuid-B",
    recipient_name = "MISSING HOSPITAL",
    amount_M       = 30.0
  )
  current <- dplyr::tibble(  # does not contain uuid-B
    recipient_id   = "uuid-C",
    recipient_name = "OTHER INSTITUTION",
    amount_M       = 15.0
  )
  cutoff_floor_M <- min(current$amount_M, na.rm = TRUE)

  # uuid-B is in baseline but not current → should be flagged
  unmatched <- baseline[!baseline$recipient_id %in% current$recipient_id, ]
  expect_equal(nrow(unmatched), 1L)
  expect_equal(unmatched$recipient_name, "MISSING HOSPITAL")
  # cutoff floor = 15, meaning its current spending is somewhere 0–$15M
  expect_equal(cutoff_floor_M, 15.0)
})

test_that("cutoff_floor_M equals minimum of current top-N", {
  current <- dplyr::tibble(
    recipient_id   = c("a", "b", "c"),
    recipient_name = c("Inst A", "Inst B", "Inst C"),
    amount_M       = c(50.0, 30.0, 12.5)
  )
  expect_equal(min(current$amount_M, na.rm = TRUE), 12.5)
})

test_that("dedup_non_na preserves all NA recipient_ids and drops only non-NA dups", {
  # dplyr::distinct(recipient_id, .keep_all=TRUE) collapses all NAs to one row,
  # silently losing institutions with no UEI/DUNS registration.
  # dedup_non_na must keep ALL NA rows while deduplicating non-NA ids.
  dedup_non_na <- function(df) df[!duplicated(df$recipient_id) | is.na(df$recipient_id), ]
  df <- dplyr::tibble(
    recipient_id   = c("uuid-A", "uuid-A", NA_character_, NA_character_),
    recipient_name = c("Alpha Univ", "Alpha Univ Dup", "No UEI Inst 1", "No UEI Inst 2"),
    amount_M       = c(100.0, 5.0, 20.0, 15.0)
  )
  result <- dedup_non_na(df)
  expect_equal(nrow(result), 3L)                                         # first uuid-A + both NAs
  expect_equal(sum(is.na(result$recipient_id)), 2L)                      # both NA rows kept
  expect_equal(sum(result$recipient_id == "uuid-A", na.rm = TRUE), 1L)  # only first uuid-A kept
  expect_equal(result$recipient_name[!is.na(result$recipient_id)], "Alpha Univ")
})

test_that("SPENDING_BY_CATEGORY_BASE points to correct endpoint", {
  expect_true(grepl("spending_by_category", SPENDING_BY_CATEGORY_BASE))
  expect_true(grepl("api.usaspending.gov", SPENDING_BY_CATEGORY_BASE))
})

# ===========================================================================
# extract_termination_actions() + detect_reinstatement_pattern()
# (fetch_usaspending.R — USAspending transaction intelligence)
# ===========================================================================

test_that("extract_termination_actions returns empty tibble for empty input", {
  empty_txns <- dplyr::tibble(
    grant_number = character(0), transaction_date = as.Date(character(0)),
    obligation_amount = double(0), transaction_desc = character(0),
    action_type = character(0), modification_number = character(0)
  )
  result <- suppressMessages(extract_termination_actions(empty_txns))
  expect_s3_class(result, "tbl_df")
  expect_equal(nrow(result), 0L)
  expect_true("termination_action_date" %in% names(result))
  expect_true("termination_action_type" %in% names(result))
})

test_that("extract_termination_actions filters to E and F action types only", {
  txns <- dplyr::tibble(
    grant_number      = c("R01A", "R01A", "R01B", "R01C"),
    transaction_date  = as.Date(c("2025-01-15", "2025-02-01", "2025-01-20", "2025-03-01")),
    obligation_amount = c(-5000, 1000, -3000, 2000),
    transaction_desc  = rep("test", 4),
    action_type       = c("E", "B", "F", "A"),  # E, F = termination; B, A = continuation
    modification_number = c("2", "3", "1", "1")
  )
  result <- suppressMessages(extract_termination_actions(txns))
  # Only R01A (E) and R01B (F) should appear; R01C (A) is not a termination
  expect_equal(nrow(result), 2L)
  expect_true(all(result$termination_action_type %in% c("E", "F")))
  expect_false("R01C" %in% result$grant_number)
})

test_that("extract_termination_actions returns most recent termination per grant", {
  txns <- dplyr::tibble(
    grant_number      = c("R01A", "R01A"),
    transaction_date  = as.Date(c("2025-01-15", "2025-03-10")),
    obligation_amount = c(-5000, -2000),
    transaction_desc  = rep("test", 2),
    action_type       = c("E", "E"),
    modification_number = c("2", "3")
  )
  result <- suppressMessages(extract_termination_actions(txns))
  expect_equal(nrow(result), 1L)
  expect_equal(result$termination_action_date, as.Date("2025-03-10"))
  expect_equal(result$termination_mod_number, "3")
})

test_that("TERMINATION_ACTION_TYPES includes E and F", {
  expect_true("E" %in% TERMINATION_ACTION_TYPES)
  expect_true("F" %in% TERMINATION_ACTION_TYPES)
  expect_equal(length(TERMINATION_ACTION_TYPES), 2L)
})

test_that("detect_reinstatement_pattern returns empty tibble for empty input", {
  empty_txns <- dplyr::tibble(
    grant_number = character(0), transaction_date = as.Date(character(0)),
    obligation_amount = double(0), transaction_desc = character(0),
    action_type = character(0), modification_number = character(0)
  )
  result <- suppressMessages(detect_reinstatement_pattern(empty_txns))
  expect_s3_class(result, "tbl_df")
  expect_equal(nrow(result), 0L)
  expected_cols <- c("grant_number", "termination_action_date",
                     "reinstatement_action_date", "reinstatement_action_type")
  expect_true(all(expected_cols %in% names(result)))
})

test_that("detect_reinstatement_pattern detects E followed by A", {
  txns <- dplyr::tibble(
    grant_number      = c("R01A", "R01A", "R01B"),
    transaction_date  = as.Date(c("2025-01-15", "2025-04-01", "2025-02-01")),
    obligation_amount = c(-5000, 3000, -4000),
    transaction_desc  = rep("test", 3),
    action_type       = c("E", "A", "F"),  # R01A: terminated then reinstated; R01B: terminated only
    modification_number = c("2", "3", "1")
  )
  result <- suppressMessages(detect_reinstatement_pattern(txns))
  expect_equal(nrow(result), 1L)
  expect_equal(result$grant_number, "R01A")
  expect_equal(result$termination_action_date, as.Date("2025-01-15"))
  expect_equal(result$reinstatement_action_date, as.Date("2025-04-01"))
  expect_equal(result$reinstatement_action_type, "A")
})

test_that("detect_reinstatement_pattern does not flag grants with no post-termination activity", {
  txns <- dplyr::tibble(
    grant_number      = c("R01A", "R01B"),
    transaction_date  = as.Date(c("2025-01-15", "2025-02-01")),
    obligation_amount = c(-5000, -4000),
    transaction_desc  = rep("test", 2),
    action_type       = c("E", "F"),
    modification_number = c("2", "1")
  )
  result <- suppressMessages(detect_reinstatement_pattern(txns))
  expect_equal(nrow(result), 0L)
})

# ===========================================================================
# confirm_post_termination_activity() (transform.R — Option A)
# ===========================================================================

test_that("confirm_post_termination_activity returns empty for empty file_c_data", {
  result <- suppressMessages(confirm_post_termination_activity(
    file_c_data   = .empty_file_c_tibble(),
    discrepancies = dplyr::tibble(grant_number = "R01A", notice_date = as.Date("2025-01-01"))
  ))
  expect_s3_class(result, "tbl_df")
  expect_equal(nrow(result), 0L)
})

test_that("confirm_post_termination_activity returns empty for empty discrepancies", {
  file_c <- dplyr::tibble(
    grant_number    = "R01A",
    reporting_date  = as.Date("2025-07-01"),
    reporting_year  = 2025L, reporting_month = 7L,
    outlay_amount   = 5000, obligated_amount = 0
  )
  result <- suppressMessages(confirm_post_termination_activity(
    file_c_data   = file_c,
    discrepancies = dplyr::tibble(grant_number = character(0), notice_date = as.Date(character(0)))
  ))
  expect_equal(nrow(result), 0L)
})

test_that("confirm_post_termination_activity flags outlays beyond 120-day window", {
  # Grant terminated 2025-01-01. Closeout deadline = 2025-05-01.
  # File C shows outlay on 2025-07-01 (61 days AFTER closeout) => should flag.
  file_c <- dplyr::tibble(
    grant_number    = c("R01A", "R01A"),
    reporting_date  = as.Date(c("2025-03-01", "2025-07-01")),  # within / beyond closeout
    reporting_year  = c(2025L, 2025L),
    reporting_month = c(3L, 7L),
    outlay_amount   = c(500, 5000),
    obligated_amount = c(0, 0)
  )
  disc <- dplyr::tibble(
    grant_number = "R01A",
    notice_date  = as.Date("2025-01-01")
  )
  result <- suppressMessages(confirm_post_termination_activity(file_c, disc))
  expect_equal(nrow(result), 1L)
  expect_true(result$flag_confirmed_post_termination_outlays)
  expect_equal(result$n_post_termination_periods, 1L)  # Only July counts; March is within window
  expect_equal(result$post_termination_total_outlays, 5000)
})

test_that("confirm_post_termination_activity does NOT flag outlays within 120-day window", {
  # Grant terminated 2025-01-01. Closeout deadline = 2025-05-01.
  # File C shows outlay on 2025-03-01 (within window) => should NOT flag.
  file_c <- dplyr::tibble(
    grant_number    = "R01A",
    reporting_date  = as.Date("2025-03-01"),
    reporting_year  = 2025L, reporting_month = 3L,
    outlay_amount   = 500, obligated_amount = 0
  )
  disc <- dplyr::tibble(
    grant_number = "R01A",
    notice_date  = as.Date("2025-01-01")
  )
  result <- suppressMessages(confirm_post_termination_activity(file_c, disc))
  expect_equal(nrow(result), 1L)
  expect_false(result$flag_confirmed_post_termination_outlays)
  expect_equal(result$n_post_termination_periods, 0L)
})

test_that("confirm_post_termination_activity output has required columns", {
  result <- suppressMessages(confirm_post_termination_activity(
    file_c_data   = .empty_file_c_tibble(),
    discrepancies = dplyr::tibble(grant_number = character(0),
                                  notice_date  = as.Date(character(0)))
  ))
  expected_cols <- c(
    "grant_number", "flag_confirmed_post_termination_outlays",
    "n_post_termination_periods", "post_termination_total_outlays",
    "post_termination_first_date", "post_termination_last_date"
  )
  expect_true(all(expected_cols %in% names(result)))
})

# ===========================================================================
# fetch_subaward_impact() — spending_by_subaward_grouped
# (fetch_usaspending.R)
# ===========================================================================

test_that(".empty_subaward_impact_tibble has correct schema", {
  tbl <- .empty_subaward_impact_tibble()
  expect_s3_class(tbl, "tbl_df")
  expect_equal(nrow(tbl), 0L)
  expect_type(tbl$award_id,                    "character")
  expect_type(tbl$subaward_count,              "integer")
  expect_type(tbl$subaward_obligation,         "double")
  expect_type(tbl$award_generated_internal_id, "character")
})

test_that(".parse_subaward_impact_records: well-formed records produce correct values", {
  records <- list(
    list(
      award_id                    = "R01AI123456",
      subaward_count              = 3L,
      subaward_obligation         = 150000.0,
      award_generated_internal_id = "ASST_NON_R01AI123456_075"
    ),
    list(
      award_id                    = "2301234",
      subaward_count              = 1L,
      subaward_obligation         = 45000.0,
      award_generated_internal_id = "ASST_NON_2301234_049"
    )
  )
  result <- .parse_subaward_impact_records(records)
  expect_equal(nrow(result), 2L)
  expect_equal(result$award_id[1], "R01AI123456")
  expect_equal(result$subaward_count[1], 3L)
  expect_equal(result$subaward_obligation[1], 150000.0)
  expect_equal(result$award_generated_internal_id[1], "ASST_NON_R01AI123456_075")
})

test_that(".parse_subaward_impact_records: empty input returns empty tibble", {
  result <- .parse_subaward_impact_records(list())
  expect_s3_class(result, "tbl_df")
  expect_equal(nrow(result), 0L)
  expect_true("award_id" %in% names(result))
  expect_true("subaward_count" %in% names(result))
})

test_that(".parse_subaward_impact_records: missing fields become NA", {
  records <- list(
    list(
      award_id = "R01TEST"
      # subaward_count, subaward_obligation, award_generated_internal_id all missing
    )
  )
  result <- .parse_subaward_impact_records(records)
  expect_equal(nrow(result), 1L)
  expect_true(is.na(result$subaward_count[1]))
  expect_true(is.na(result$subaward_obligation[1]))
  expect_true(is.na(result$award_generated_internal_id[1]))
})

test_that("fetch_subaward_impact with empty award_ids returns empty tibble", {
  result <- suppressMessages(fetch_subaward_impact(character(0)))
  expect_s3_class(result, "tbl_df")
  expect_equal(nrow(result), 0L)
  expect_true("subaward_count" %in% names(result))
})

test_that("fetch_subaward_impact drops NA award IDs silently", {
  # NA-only input should return empty tibble, not error
  result <- suppressMessages(fetch_subaward_impact(c(NA_character_, NA_character_)))
  expect_equal(nrow(result), 0L)
})

test_that("SUBAWARD_GROUPED_URL points to correct endpoint", {
  expect_true(grepl("subaward", SUBAWARD_GROUPED_URL))
  expect_true(grepl("api.usaspending.gov", SUBAWARD_GROUPED_URL))
})

# ===========================================================================
# enrich_with_emergency_flags() — def_codes political targeting signal
# (transform.R)
# ===========================================================================

test_that("enrich_with_emergency_flags adds flag_emergency_exempt column", {
  disc <- dplyr::tibble(
    grant_number     = c("R01A", "R01B"),
    discrepancy_type = c("possible_freeze", "normal"),
    def_codes        = c("A,B", NA_character_)
  )
  result <- suppressMessages(enrich_with_emergency_flags(disc))
  expect_true("flag_emergency_exempt" %in% names(result))
  expect_equal(nrow(result), 2L)
})

test_that("enrich_with_emergency_flags flags frozen grant with def_codes", {
  disc <- dplyr::tibble(
    grant_number     = "R01FROZEN",
    discrepancy_type = "possible_freeze",
    def_codes        = "L,M"    # ARP emergency codes
  )
  result <- suppressMessages(enrich_with_emergency_flags(disc))
  expect_true(result$flag_emergency_exempt[1])
})

test_that("enrich_with_emergency_flags does NOT flag normal grants with def_codes", {
  disc <- dplyr::tibble(
    grant_number     = "R01NORMAL",
    discrepancy_type = "normal",
    def_codes        = "A,B"
  )
  result <- suppressMessages(enrich_with_emergency_flags(disc))
  expect_false(result$flag_emergency_exempt[1])
})

test_that("enrich_with_emergency_flags does NOT flag freeze grants without def_codes", {
  disc <- dplyr::tibble(
    grant_number     = c("R01A", "R01B"),
    discrepancy_type = c("possible_freeze", "active_despite_terminated"),
    def_codes        = c(NA_character_, NA_character_)
  )
  result <- suppressMessages(enrich_with_emergency_flags(disc))
  expect_false(result$flag_emergency_exempt[1])
  expect_false(result$flag_emergency_exempt[2])
})

test_that("enrich_with_emergency_flags uses usaspending_awards as def_codes source", {
  disc <- dplyr::tibble(
    grant_number     = c("R01A", "R01B"),
    discrepancy_type = c("possible_freeze", "normal")
    # no def_codes column
  )
  awards <- dplyr::tibble(
    grant_number = c("R01A", "R01B"),
    def_codes    = c("Z", NA_character_)   # Z = Families First COVID code
  )
  result <- suppressMessages(enrich_with_emergency_flags(disc, usaspending_awards = awards))
  expect_true("flag_emergency_exempt" %in% names(result))
  expect_true(result$flag_emergency_exempt[1])   # R01A: frozen + COVID def_code
  expect_false(result$flag_emergency_exempt[2])  # R01B: normal
})

test_that("enrich_with_emergency_flags awards source overrides embedded def_codes", {
  # discrepancies has def_codes column but awards has updated info — awards wins
  disc <- dplyr::tibble(
    grant_number     = "R01A",
    discrepancy_type = "possible_freeze",
    def_codes        = NA_character_   # stale: no codes
  )
  awards <- dplyr::tibble(
    grant_number = "R01A",
    def_codes    = "N"                 # fresh: ARP code
  )
  result <- suppressMessages(enrich_with_emergency_flags(disc, usaspending_awards = awards))
  expect_true(result$flag_emergency_exempt[1])
})

test_that("enrich_with_emergency_flags does NOT flag IIJA-only (Q) freeze grants", {
  # Q (IIJA) appears on ~82% of awards — too ubiquitous to be a targeting signal
  disc <- dplyr::tibble(
    grant_number     = "R01X",
    discrepancy_type = "possible_freeze",
    def_codes        = "Q"
  )
  result <- suppressMessages(enrich_with_emergency_flags(disc))
  expect_false(result$flag_emergency_exempt[1])
})

test_that("enrich_with_emergency_flags handles empty input gracefully", {
  empty_disc <- dplyr::tibble(
    grant_number     = character(0),
    discrepancy_type = character(0),
    def_codes        = character(0)
  )
  result <- suppressMessages(enrich_with_emergency_flags(empty_disc))
  expect_equal(nrow(result), 0L)
  expect_true("flag_emergency_exempt" %in% names(result))
})
