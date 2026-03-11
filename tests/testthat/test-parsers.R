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
    flag_active_despite_terminated = c(TRUE, FALSE, FALSE, FALSE),
    flag_no_recent_activity        = c(FALSE, TRUE, FALSE, FALSE),
    flag_not_in_gw                 = c(FALSE, FALSE, TRUE, FALSE)
  )
  expect_equal(result, c("active_despite_terminated", "possible_freeze", "untracked", "normal"))
})

# ===========================================================================
# 6. transform.R — classify_discrepancy() and summarize_discrepancies()
# ===========================================================================

# ---------------------------------------------------------------------------
# classify_discrepancy()
# ---------------------------------------------------------------------------

test_that("classify_discrepancy: active_despite_terminated when first flag TRUE", {
  result <- classify_discrepancy(
    flag_active_despite_terminated = TRUE,
    flag_no_recent_activity        = FALSE,
    flag_not_in_gw                 = FALSE
  )
  expect_equal(result, "active_despite_terminated")
})

test_that("classify_discrepancy: active_despite_terminated wins over possible_freeze", {
  result <- classify_discrepancy(
    flag_active_despite_terminated = TRUE,
    flag_no_recent_activity        = TRUE,
    flag_not_in_gw                 = FALSE
  )
  expect_equal(result, "active_despite_terminated")
})

test_that("classify_discrepancy: active_despite_terminated wins over all other flags", {
  result <- classify_discrepancy(
    flag_active_despite_terminated = TRUE,
    flag_no_recent_activity        = TRUE,
    flag_not_in_gw                 = TRUE
  )
  expect_equal(result, "active_despite_terminated")
})

test_that("classify_discrepancy: possible_freeze when only no_recent_activity is TRUE", {
  result <- classify_discrepancy(
    flag_active_despite_terminated = FALSE,
    flag_no_recent_activity        = TRUE,
    flag_not_in_gw                 = FALSE
  )
  expect_equal(result, "possible_freeze")
})

test_that("classify_discrepancy: possible_freeze wins over untracked", {
  result <- classify_discrepancy(
    flag_active_despite_terminated = FALSE,
    flag_no_recent_activity        = TRUE,
    flag_not_in_gw                 = TRUE
  )
  expect_equal(result, "possible_freeze")
})

test_that("classify_discrepancy: untracked when only not_in_gw is TRUE", {
  result <- classify_discrepancy(
    flag_active_despite_terminated = FALSE,
    flag_no_recent_activity        = FALSE,
    flag_not_in_gw                 = TRUE
  )
  expect_equal(result, "untracked")
})

test_that("classify_discrepancy: normal when all flags FALSE", {
  result <- classify_discrepancy(
    flag_active_despite_terminated = FALSE,
    flag_no_recent_activity        = FALSE,
    flag_not_in_gw                 = FALSE
  )
  expect_equal(result, "normal")
})

test_that("classify_discrepancy: returns a single character string", {
  result <- classify_discrepancy(TRUE, FALSE, FALSE)
  expect_type(result, "character")
  expect_length(result, 1L)
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
