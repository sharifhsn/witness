#' @title USAspending File C (Federal Account Funding) Fetcher
#' @description Fetches period-by-period outlay data from the USAspending
#'   awards/funding endpoint (File C). This provides monthly gross outlay
#'   amounts per award — the same data source Grant Witness uses for freeze
#'   detection. Enables temporal reconstruction: checking whether outlays were
#'   $0 during each month of an institutional freeze, not just the aggregate
#'   total at current time.
#'
#' @section API reference:
#'   POST https://api.usaspending.gov/api/v2/awards/funding/
#'   Requires `generated_internal_id` (not plain Award ID).
#'   Format: ASST_NON_{award_id}_{agency_code}
#'   Agency codes: HHS=075, NSF=049, EPA=068.
#'   No authentication required. Rate limit: ~1 req/2 sec (enforced by build_request()).

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #

FILE_C_URL <- "https://api.usaspending.gov/api/v2/awards/funding/"

# USAspending uses CGAC agency codes in generated_internal_id.
# Map from toptier agency name (as used in our pipeline) to the 3-digit code.
AGENCY_CGAC_CODES <- c(
  "Department of Health and Human Services" = "075",
  "National Science Foundation"             = "049",
  "Environmental Protection Agency"         = "068"
)

# Max records per page (same as other USAspending endpoints)
FILE_C_MAX_PAGE_SIZE <- 100L

# --------------------------------------------------------------------------- #
# API probe
# --------------------------------------------------------------------------- #

#' Probe the File C funding endpoint with a sample award
#'
#' Tests the endpoint with a known award ID to verify availability and response
#' format. Returns a list indicating success and a sample response.
#'
#' @param sample_award_id Character. A grant_number from our pipeline.
#' @param agency_name Character. Toptier agency name for CGAC code lookup.
#' @return List with `success` (logical), `endpoint_url` (character),
#'   `n_records` (integer), `sample_fields` (character vector).
#' @export
probe_file_c_endpoint <- function(sample_award_id,
                                  agency_name = "Department of Health and Human Services") {
  log_event(sprintf("Probing File C endpoint with award_id=%s", sample_award_id))

  internal_id <- .build_generated_internal_id(sample_award_id, agency_name)

  if (is.na(internal_id)) {
    log_event("probe_file_c_endpoint: could not construct internal ID", "WARN")
    return(list(success = FALSE, endpoint_url = FILE_C_URL,
                n_records = 0L, sample_fields = character(0)))
  }

  body <- build_file_c_body(internal_id, page = 1L, limit = 5L)

  result <- tryCatch(
    {
      raw <- .usaspending_post(FILE_C_URL, body, "File C probe")

      if (length(raw$results) > 0L) {
        list(
          success       = TRUE,
          endpoint_url  = FILE_C_URL,
          n_records     = length(raw$results),
          sample_fields = names(raw$results[[1]])
        )
      } else {
        log_event("File C probe: endpoint returned 0 records", "WARN")
        list(success = FALSE, endpoint_url = FILE_C_URL,
             n_records = 0L, sample_fields = character(0))
      }
    },
    error = function(e) {
      log_event(sprintf("File C probe failed: %s", conditionMessage(e)), "ERROR")
      list(success = FALSE, endpoint_url = FILE_C_URL,
           n_records = 0L, sample_fields = character(0))
    }
  )

  log_event(sprintf(
    "File C probe result: success=%s, n_records=%d",
    result$success, result$n_records
  ))

  result
}

# --------------------------------------------------------------------------- #
# Request body builder
# --------------------------------------------------------------------------- #

#' Build the JSON body for one File C funding page query
#'
#' @param generated_internal_id Character. The USAspending internal award ID
#'   (format: ASST_NON_{award_id}_{agency_code}).
#' @param page Integer. Page number.
#' @param limit Integer. Records per page (max 100).
#' @return List suitable for `req_body_json()`.
#' @export
build_file_c_body <- function(generated_internal_id, page = 1L, limit = 100L) {
  limit <- min(limit, FILE_C_MAX_PAGE_SIZE)
  list(
    award_id = generated_internal_id,
    page     = page,
    limit    = limit
  )
}

# --------------------------------------------------------------------------- #
# Response parser
# --------------------------------------------------------------------------- #

#' Parse File C funding response records into a tibble
#'
#' Extracts monthly outlay and obligation data from the raw API response.
#' Each record represents one reporting period for one federal account.
#'
#' @param records List of response records from the API.
#' @param grant_number Character. The original grant_number for this award.
#' @return Tibble with columns: grant_number, reporting_date, reporting_year,
#'   reporting_month, outlay_amount, obligated_amount, federal_account,
#'   account_title.
#' @keywords internal
.parse_file_c_records <- function(records, grant_number) {
  if (length(records) == 0L) {
    return(.empty_file_c_tibble())
  }

  n <- length(records)
  r_years    <- integer(n)
  r_months   <- integer(n)
  outlays    <- double(n)
  obligated  <- double(n)
  fed_accts  <- character(n)
  acct_title <- character(n)

  for (i in seq_len(n)) {
    r <- records[[i]]
    r_years[i]    <- as.integer(r[["reporting_fiscal_year"]]  %||% NA_integer_)
    r_months[i]   <- as.integer(r[["reporting_fiscal_month"]] %||% NA_integer_)
    outlays[i]    <- as.numeric(r[["gross_outlay_amount"]]    %||% NA_real_)
    obligated[i]  <- as.numeric(r[["transaction_obligated_amount"]] %||% NA_real_)
    fed_accts[i]  <- r[["federal_account"]]                   %||% NA_character_
    acct_title[i] <- r[["account_title"]]                     %||% NA_character_
  }

  # Convert fiscal year + fiscal month to a calendar date.
  # USAspending reporting_fiscal_month is the FISCAL month (1=Oct, 12=Sep),
  # NOT the calendar month. Fiscal month 1 = October, 2 = November, ...,
  # 4 = January, ..., 12 = September.
  # Formula: calendar_month = ((fiscal_month + 8) %% 12) + 1
  calendar_month <- ((r_months + 8L) %% 12L) + 1L
  # Fiscal months 1-3 (Oct-Dec) fall in the prior calendar year.
  calendar_year <- dplyr::if_else(r_months <= 3L, r_years - 1L, r_years)
  reporting_dates <- as.Date(
    sprintf("%04d-%02d-01", calendar_year, calendar_month),
    format = "%Y-%m-%d"
  )

  dplyr::tibble(
    grant_number    = rep(grant_number, n),
    reporting_date  = reporting_dates,
    reporting_year  = r_years,
    reporting_month = r_months,
    outlay_amount   = outlays,
    obligated_amount = obligated,
    federal_account = fed_accts,
    account_title   = acct_title
  )
}

# --------------------------------------------------------------------------- #
# Main fetcher
# --------------------------------------------------------------------------- #

#' Fetch File C (period-by-period outlay) data for a set of award IDs
#'
#' For each award ID, constructs the USAspending generated_internal_id,
#' queries the awards/funding endpoint, and paginates to collect all
#' monthly outlay records.
#'
#' @param award_ids Character vector of grant_number values from our pipeline.
#' @param agency_names Character vector parallel to `award_ids` giving the
#'   toptier agency name for each grant. When provided, each grant uses its
#'   own agency's CGAC code. When NULL, all grants use `agency_name`.
#' @param agency_name Character. Fallback toptier agency name when
#'   `agency_names` is NULL. Default: "Department of Health and Human Services".
#' @param max_pages_per_award Integer. Maximum pages to fetch per award. Default 5.
#' @param max_awards Integer or NULL. Cap on total awards to fetch. Default NULL (no cap).
#' @return Tibble with columns: grant_number, reporting_date, reporting_year,
#'   reporting_month, outlay_amount, obligated_amount.
#' @export
fetch_file_c <- function(award_ids,
                         agency_names = NULL,
                         agency_name = "Department of Health and Human Services",
                         max_pages_per_award = 5L,
                         max_awards = NULL) {
  # Deduplicate: keep first occurrence (preserves agency_names alignment)
  if (!is.null(agency_names)) {
    keep <- !is.na(award_ids) & !duplicated(award_ids)
    award_ids <- award_ids[keep]
    agency_names <- agency_names[keep]
  } else {
    award_ids <- unique(award_ids[!is.na(award_ids)])
  }

  if (length(award_ids) == 0L) {
    log_event("fetch_file_c: no award IDs provided", "WARN")
    return(.empty_file_c_tibble())
  }

  if (!is.null(max_awards) && length(award_ids) > max_awards) {
    log_event(sprintf(
      "fetch_file_c: capping from %d to %d awards",
      length(award_ids), max_awards
    ))
    award_ids <- award_ids[seq_len(max_awards)]
    if (!is.null(agency_names)) {
      agency_names <- agency_names[seq_len(max_awards)]
    }
  }

  log_event(sprintf(
    "fetch_file_c: %d unique award IDs, max_pages=%d",
    length(award_ids), max_pages_per_award
  ))

  all_results <- vector("list", length(award_ids))

  for (a in seq_along(award_ids)) {
    aid <- award_ids[a]
    aid_agency <- if (!is.null(agency_names)) agency_names[a] else agency_name
    internal_id <- .build_generated_internal_id(aid, aid_agency)

    if (is.na(internal_id)) {
      log_event(sprintf("  [%d/%d] %s — skipped (unknown agency code)",
                        a, length(award_ids), aid), "WARN")
      next
    }

    if (a %% 50L == 0L || a == 1L) {
      log_event(sprintf("  [%d/%d] Fetching File C for %s",
                        a, length(award_ids), aid))
    }

    award_pages <- vector("list", max_pages_per_award)
    page_idx <- 0L
    page <- 1L

    repeat {
      body <- build_file_c_body(internal_id, page, FILE_C_MAX_PAGE_SIZE)
      raw <- .usaspending_post(FILE_C_URL, body, "File C")

      if (length(raw$results) > 0L) {
        page_idx <- page_idx + 1L
        award_pages[[page_idx]] <- .parse_file_c_records(raw$results, aid)
      }

      if (!raw$has_next || length(raw$results) == 0L || page >= max_pages_per_award) {
        break
      }
      page <- page + 1L
    }

    if (page_idx > 0L) {
      all_results[[a]] <- dplyr::bind_rows(award_pages[seq_len(page_idx)])
    }
  }

  combined <- dplyr::bind_rows(all_results)

  if (nrow(combined) == 0L) {
    log_event("fetch_file_c complete: 0 records (no awards returned data)")
    return(.empty_file_c_tibble())
  }

  # Aggregate: if multiple federal accounts fund the same grant in the same
  # period, sum the outlays/obligations to get the total per-grant-per-month.
  combined <- combined |>
    dplyr::group_by(grant_number, reporting_date, reporting_year, reporting_month) |>
    dplyr::summarise(
      outlay_amount    = sum(outlay_amount, na.rm = TRUE),
      obligated_amount = sum(obligated_amount, na.rm = TRUE),
      n_accounts       = dplyr::n(),
      .groups = "drop"
    )

  log_event(sprintf(
    "fetch_file_c complete: %d period records across %d grants",
    nrow(combined), dplyr::n_distinct(combined$grant_number)
  ))

  combined
}

# --------------------------------------------------------------------------- #
# Internal helpers
# --------------------------------------------------------------------------- #

#' Construct USAspending generated_internal_id from award_id and agency
#'
#' Format: ASST_NON_{award_id}_{3-digit CGAC code}
#'
#' @param award_id Character. The grant_number / Award ID.
#' @param agency_name Character. Toptier agency name.
#' @return Character. The generated_internal_id, or NA if agency unknown.
#' @keywords internal
.build_generated_internal_id <- function(award_id, agency_name) {
  code <- AGENCY_CGAC_CODES[agency_name]
  if (is.na(code) || is.na(award_id) || nchar(award_id) == 0L) {
    return(NA_character_)
  }
  sprintf("ASST_NON_%s_%s", award_id, code)
}

#' Empty File C tibble sentinel
#'
#' Matches the schema returned by `fetch_file_c()` after aggregation.
#' @keywords internal
.empty_file_c_tibble <- function() {
  dplyr::tibble(
    grant_number     = character(0),
    reporting_date   = as.Date(character(0)),
    reporting_year   = integer(0),
    reporting_month  = integer(0),
    outlay_amount    = double(0),
    obligated_amount = double(0),
    n_accounts       = integer(0)
  )
}
