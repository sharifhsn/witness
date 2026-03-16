#' @title Daily Treasury Statement Fetcher
#' @description Queries the Treasury Fiscal Data API for Daily Treasury Statement
#'   (DTS) withdrawal data. Provides a real-time (1-business-day lag) signal of
#'   federal agency cash withdrawals — faster than MTS Table 5 (~30-day lag).
#'
#' @section API reference:
#'   GET https://api.fiscaldata.treasury.gov/services/api/fiscal_service/v1/accounting/dts/deposits_withdrawals_operating_cash
#'   No authentication required. Amounts in millions of dollars.
#'
#' @section IMPORTANT: Do NOT use :in:() filter on transaction_catg — commas in
#'   category names conflict with the API filter separator. Always fetch all
#'   Withdrawals and post-filter in R.

DTS_URL <- "https://api.fiscaldata.treasury.gov/services/api/fiscal_service/v1/accounting/dts/deposits_withdrawals_operating_cash"

DTS_PAGE_SIZE <- 1000L

# Maps DTS transaction_catg values to clean agency names used throughout pipeline.
# Keys = exact transaction_catg strings in the API; values = our pipeline names.
DTS_AGENCY_CATS <- c(
  "HHS - National Institutes of Health"     = "National Institutes of Health",
  "National Science Foundation (NSF)"        = "National Science Foundation",
  "Environmental Protection Agency (EPA)"    = "Environmental Protection Agency",
  "HHS - Centers for Disease Control (CDC)"  = "Centers for Disease Control and Prevention"
)

#' Fetch DTS withdrawal data from Treasury Fiscal Data API
#'
#' Paginates through the DTS endpoint, filtering to Withdrawal transactions,
#' then post-filters to grant-relevant agencies.
#'
#' @param start_date Character or Date. Earliest record_date to fetch.
#' @param agency_cats Named character vector mapping DTS category strings to
#'   clean agency names. Default uses `DTS_AGENCY_CATS`.
#' @return Tibble with columns: record_date, agency, dts_category,
#'   today_withdrawals, mtd_withdrawals, fytd_withdrawals, record_fiscal_year,
#'   record_calendar_month, record_calendar_year.
#' @export
fetch_dts_withdrawals <- function(
  start_date,
  agency_cats = DTS_AGENCY_CATS
) {
  start_date <- as.Date(start_date)

  log_event(sprintf(
    "DTS fetch: withdrawals from %s for %d agencies",
    start_date, length(agency_cats)
  ))

  # Fetch all Withdrawals from start_date onward.
  # DO NOT filter transaction_catg here — commas in category names break the
  # :in:() filter syntax. Post-filter after fetching.
  date_filter <- sprintf(
    "record_date:gte:%s,transaction_type:eq:Withdrawals",
    format(start_date, "%Y-%m-%d")
  )

  all_pages <- list()
  page      <- 1L
  total_fetched <- 0L

  repeat {
    url <- sprintf(
      "%s?filter=%s&page[number]=%d&page[size]=%d",
      DTS_URL, date_filter, page, DTS_PAGE_SIZE
    )

    log_event(sprintf("  DTS page %d (fetched %d so far)", page, total_fetched))

    parsed <- .treasury_get(url)
    if (is.null(parsed)) break

    records <- parsed$data
    if (length(records) == 0L) break

    rows <- .parse_dts_records(records)
    if (nrow(rows) > 0L) {
      all_pages[[length(all_pages) + 1L]] <- rows
      total_fetched <- total_fetched + nrow(rows)
    }

    total_pages <- as.integer(parsed$meta$`total-pages` %||% 1L)
    if (page >= total_pages) break
    page <- page + 1L
  }

  if (length(all_pages) == 0L) {
    log_event("DTS fetch: no data returned", "WARN")
    return(.empty_dts_tibble())
  }

  combined <- dplyr::bind_rows(all_pages)

  # Post-filter to tracked agencies
  if (length(agency_cats) == 0L) {
    return(.empty_dts_tibble())
  }

  filtered <- combined |>
    dplyr::filter(dts_category %in% names(agency_cats)) |>
    dplyr::mutate(agency = agency_cats[dts_category]) |>
    dplyr::select(
      record_date, agency, dts_category,
      today_withdrawals, mtd_withdrawals, fytd_withdrawals,
      record_fiscal_year, record_calendar_month, record_calendar_year
    )

  log_event(sprintf(
    "DTS fetch complete: %d rows for %d agencies",
    nrow(filtered), length(unique(filtered$agency))
  ))

  filtered
}

# --------------------------------------------------------------------------- #
# Internal: Parse DTS records list into tibble
# --------------------------------------------------------------------------- #

#' @keywords internal
.parse_dts_records <- function(records) {
  n <- length(records)
  if (n == 0L) return(.empty_dts_tibble())

  record_dates     <- character(n)
  dts_categories   <- character(n)
  today_wds        <- double(n)
  mtd_wds          <- double(n)
  fytd_wds         <- double(n)
  fiscal_years     <- integer(n)
  cal_months       <- integer(n)
  cal_years        <- integer(n)

  for (i in seq_len(n)) {
    r <- records[[i]]
    record_dates[i]   <- r[["record_date"]]           %||% NA_character_
    dts_categories[i] <- r[["transaction_catg"]]      %||% NA_character_
    # Amounts are in millions of dollars. Treasury returns string "null" for NA.
    today_wds[i]  <- .safe_as_numeric(r[["transaction_today_amt"]])
    mtd_wds[i]    <- .safe_as_numeric(r[["transaction_mtd_amt"]])
    fytd_wds[i]   <- .safe_as_numeric(r[["transaction_fytd_amt"]])
    fiscal_years[i] <- as.integer(r[["record_fiscal_year"]]    %||% NA_integer_)
    cal_months[i]   <- as.integer(r[["record_calendar_month"]] %||% NA_integer_)
    cal_years[i]    <- as.integer(r[["record_calendar_year"]]  %||% NA_integer_)
  }

  dplyr::tibble(
    record_date          = as.Date(record_dates),
    dts_category         = dts_categories,
    today_withdrawals    = today_wds,
    mtd_withdrawals      = mtd_wds,
    fytd_withdrawals     = fytd_wds,
    record_fiscal_year   = fiscal_years,
    record_calendar_month = cal_months,
    record_calendar_year  = cal_years
  )
}

#' @keywords internal
.empty_dts_tibble <- function() {
  dplyr::tibble(
    record_date           = as.Date(character(0)),
    agency                = character(0),
    dts_category          = character(0),
    today_withdrawals     = double(0),
    mtd_withdrawals       = double(0),
    fytd_withdrawals      = double(0),
    record_fiscal_year    = integer(0),
    record_calendar_month = integer(0),
    record_calendar_year  = integer(0)
  )
}
