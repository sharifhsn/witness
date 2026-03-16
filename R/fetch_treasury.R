#' @title Treasury Fiscal Data MTS Table 5 Fetcher
#' @description Queries the Treasury Fiscal Data API for Monthly Treasury Statement
#'   Table 5 (bureau-level outlays). Provides ~30-day-lag macro spending data as an
#'   early warning signal — detects agency spending drops 1-2 months before
#'   USAspending grant-level data reflects them.
#'
#' @section API reference:
#'   GET https://api.fiscaldata.treasury.gov/services/api/fiscal_service/v1/accounting/mts/mts_table_5
#'   No authentication required. No documented rate limits.

# Treasury API base URL
TREASURY_MTS_URL <- "https://api.fiscaldata.treasury.gov/services/api/fiscal_service/v1/accounting/mts/mts_table_5"

# Page size (API default is 100, max is 10000)
TREASURY_PAGE_SIZE <- 1000L

# Maps Treasury classification_desc text to our pipeline's agency/bureau structure.
# Treasury uses hierarchical text names, not codes.
#
# IMPORTANT: MTS Table 5 has hierarchical data. HHS sub-agencies (NIH, CDC, etc.)
# appear as record_type_cd="B" with direct outlays. But independent agencies (NSF,
# EPA) appear as headers with null outlays — their actual totals are in rows named
# "Total--{Agency Name}" at record_type_cd="C", sequence_level_nbr="2".
# We match the "Total--" variants for NSF and EPA.
TREASURY_AGENCY_MAP <- list(
  "Department of Health and Human Services" = c(
    "National Institutes of Health",
    "Health Resources and Services Administration",
    "Centers for Disease Control and Prevention",
    "Substance Abuse and Mental Health Services Administration"
  ),
  "National Science Foundation" = c(
    "Research and Related Activities",      # NSF grants sub-line
    "Education and Human Resources",        # NSF education sub-line
    "Total--National Science Foundation"
  ),
  "Environmental Protection Agency" = c(
    "State and Tribal Assistance Grants",   # EPA grants-specific line
    "Total--Environmental Protection Agency"
  )
)

#' Fetch MTS Table 5 outlay data from Treasury Fiscal Data API
#'
#' Paginates through the API and filters to grant-relevant agencies/bureaus
#' using text matching on `classification_desc`.
#'
#' @param fiscal_years Integer vector of fiscal years to fetch. Default c(2024, 2025, 2026).
#' @param agency_map Named list mapping department names to bureau name vectors.
#'   Default uses `TREASURY_AGENCY_MAP`.
#' @return Tibble with columns: record_date, agency, bureau, month_outlays,
#'   fytd_outlays, prior_fytd_outlays, fiscal_year, fiscal_quarter, fiscal_month.
#' @export
fetch_mts_outlays <- function(
  fiscal_years = c(2024L, 2025L, 2026L),
  agency_map   = TREASURY_AGENCY_MAP
) {
  log_event(sprintf(
    "Treasury MTS fetch: fiscal years %s",
    paste(fiscal_years, collapse = ", ")
  ))

  # Build filter: fiscal years. Treasury API uses :in:() for OR on same field;
  # comma-separated :eq: clauses are AND (which would return 0 for multiple years).
  fy_filter <- sprintf(
    "record_fiscal_year:in:(%s)",
    paste(fiscal_years, collapse = ",")
  )

  all_pages <- list()
  page <- 1L
  total_fetched <- 0L

  repeat {
    url <- sprintf(
      "%s?filter=%s&page[number]=%d&page[size]=%d",
      TREASURY_MTS_URL, fy_filter, page, TREASURY_PAGE_SIZE
    )

    log_event(sprintf("  Treasury MTS page %d (fetched %d so far)", page, total_fetched))

    parsed <- .treasury_get(url)
    if (is.null(parsed)) break

    records <- parsed$data
    if (length(records) == 0L) break

    rows <- .parse_mts_records(records)
    if (nrow(rows) > 0L) {
      all_pages[[length(all_pages) + 1L]] <- rows
      total_fetched <- total_fetched + nrow(rows)
    }

    # Check pagination
    total_pages <- as.integer(parsed$meta$`total-pages` %||% 1L)
    if (page >= total_pages) break
    page <- page + 1L
  }

  if (length(all_pages) == 0L) {
    log_event("Treasury MTS fetch: no data returned", "WARN")
    return(.empty_mts_tibble())
  }

  combined <- dplyr::bind_rows(all_pages)

  # Filter to tracked bureaus
  all_bureaus <- unlist(agency_map, use.names = FALSE)
  filtered <- combined |>
    dplyr::filter(classification_desc %in% all_bureaus)

  # Map bureau -> parent agency
  bureau_to_agency <- stats::setNames(
    rep(names(agency_map), lengths(agency_map)),
    unlist(agency_map, use.names = FALSE)
  )

  result <- filtered |>
    dplyr::mutate(
      agency = bureau_to_agency[classification_desc],
      # Strip "Total--" prefix so bureau names are clean for display/join
      bureau = sub("^Total--", "", classification_desc)
    ) |>
    dplyr::select(
      record_date, agency, bureau,
      month_outlays = current_month_gross_outly_amt,
      fytd_outlays  = current_fytd_gross_outly_amt,
      prior_fytd_outlays = prior_fytd_gross_outly_amt,
      fiscal_year   = record_fiscal_year,
      fiscal_quarter = record_fiscal_quarter,
      fiscal_month  = record_fiscal_month
    ) |>
    # Drop rows where outlays are all NA (header rows with string "null")
    dplyr::filter(!is.na(month_outlays))

  log_event(sprintf(
    "Treasury MTS fetch complete: %d rows for %d bureaus across FY %s",
    nrow(result), length(unique(result$bureau)),
    paste(fiscal_years, collapse = "/")
  ))

  log_quality_summary(result, "treasury_mts")
  result
}

# --------------------------------------------------------------------------- #
# Internal: GET helper
# --------------------------------------------------------------------------- #

#' @keywords internal
.treasury_get <- function(url) {
  resp <- tryCatch(
    {
      req <- build_request(url) |>
        httr2::req_error(is_error = function(resp) FALSE)
      raw_resp <- httr2::req_perform(req)
      if (httr2::resp_status(raw_resp) >= 400L) {
        err_body <- tryCatch(httr2::resp_body_string(raw_resp), error = function(e) "(no body)")
        log_event(sprintf(
          "Treasury MTS HTTP %d: %s",
          httr2::resp_status(raw_resp), substr(err_body, 1, 300)
        ), "ERROR")
        return(NULL)
      }
      raw_resp
    },
    error = function(e) {
      log_event(sprintf("Treasury MTS request failed: %s", conditionMessage(e)), "ERROR")
      NULL
    }
  )

  if (is.null(resp)) return(NULL)

  tryCatch(
    httr2::resp_body_json(resp, simplifyVector = FALSE),
    error = function(e) {
      log_event(sprintf("Treasury MTS JSON parse failed: %s", conditionMessage(e)), "ERROR")
      NULL
    }
  )
}

# --------------------------------------------------------------------------- #
# Internal: Parse MTS records list into tibble
# --------------------------------------------------------------------------- #

#' @keywords internal
.parse_mts_records <- function(records) {
  n <- length(records)
  if (n == 0L) return(.empty_mts_tibble())

  record_dates      <- character(n)
  class_descs       <- character(n)
  month_outlays     <- double(n)
  fytd_outlays      <- double(n)
  prior_fytd        <- double(n)
  fiscal_years      <- integer(n)
  fiscal_quarters   <- integer(n)
  fiscal_months     <- integer(n)

  for (i in seq_len(n)) {
    r <- records[[i]]
    record_dates[i]    <- r[["record_date"]]                    %||% NA_character_
    class_descs[i]     <- r[["classification_desc"]]            %||% NA_character_
    # Treasury API returns the string "null" (not JSON null) for missing amounts.
    # .safe_as_numeric handles this without warnings.
    month_outlays[i]   <- .safe_as_numeric(r[["current_month_gross_outly_amt"]])
    fytd_outlays[i]    <- .safe_as_numeric(r[["current_fytd_gross_outly_amt"]])
    prior_fytd[i]      <- .safe_as_numeric(r[["prior_fytd_gross_outly_amt"]])
    fiscal_years[i]    <- as.integer(r[["record_fiscal_year"]]    %||% NA_integer_)
    fiscal_quarters[i] <- as.integer(r[["record_fiscal_quarter"]] %||% NA_integer_)
    # NOTE: API field is record_calendar_month (1=Jan, 12=Dec), NOT fiscal
    # month (1=Oct). Stored as record_fiscal_month for downstream join
    # compatibility — YoY compares same calendar month across FYs, which works.
    fiscal_months[i]   <- as.integer(r[["record_calendar_month"]] %||% NA_integer_)
  }

  dplyr::tibble(
    record_date                    = as.Date(record_dates),
    classification_desc            = class_descs,
    current_month_gross_outly_amt  = month_outlays,
    current_fytd_gross_outly_amt   = fytd_outlays,
    prior_fytd_gross_outly_amt     = prior_fytd,
    record_fiscal_year             = fiscal_years,
    record_fiscal_quarter          = fiscal_quarters,
    record_fiscal_month            = fiscal_months
  )
}

#' Safely convert to numeric, treating NULL and the string "null" as NA.
#' Treasury API returns "null" (string) instead of JSON null for missing values.
#' @keywords internal
.safe_as_numeric <- function(x) {
  if (is.null(x) || identical(x, "null")) return(NA_real_)
  as.numeric(x)
}

#' @keywords internal
.empty_mts_tibble <- function() {
  dplyr::tibble(
    record_date                    = as.Date(character(0)),
    classification_desc            = character(0),
    current_month_gross_outly_amt  = double(0),
    current_fytd_gross_outly_amt   = double(0),
    prior_fytd_gross_outly_amt     = double(0),
    record_fiscal_year             = integer(0),
    record_fiscal_quarter          = integer(0),
    record_fiscal_month            = integer(0)
  )
}
