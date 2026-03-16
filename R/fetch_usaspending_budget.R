#' @title USAspending Agency Budget Execution Fetcher
#' @description Queries the USAspending.gov agency budgetary resources endpoint
#'   for period-by-period obligation data. Data is sourced from GTAS
#'   (Governmentwide Treasury Account Symbol Adjusted Trial Balance System),
#'   which is the same Treasury-certified data used for the Daily Treasury
#'   Statement — independent confirmation of the obligation drought signal.
#'
#' @section API reference:
#'   GET https://api.usaspending.gov/api/v2/agency/{toptier_code}/budgetary_resources/
#'   No authentication required. Returns ALL fiscal years in one call.
#'
#' @section IMPORTANT: Use toptier_code (3-digit: 075, 049, 068), NOT agency_id
#'   (806, 655, 700). Using agency_id returns 404.
#'   Period data is in `agency_obligation_by_period` (NOT `obligations_by_period`).
#'   Fiscal period 1=Oct, 2=Nov, ..., 12=Sep.

BUDGET_API_BASE <- "https://api.usaspending.gov/api/v2/agency"

# Maps human-readable agency names to USAspending toptier_code (3-digit).
# HHS=075 covers NIH and all HHS sub-agencies.
AGENCY_TOPTIER_CODES <- c(
  "Department of Health and Human Services" = "075",
  "National Science Foundation"             = "049",
  "Environmental Protection Agency"         = "068"
)

#' Fetch agency-level budget execution data from USAspending
#'
#' Calls the `/api/v2/agency/{toptier_code}/budgetary_resources/` endpoint for
#' each agency and unnests the period-by-period obligation data into a flat
#' tibble covering the requested fiscal years.
#'
#' @param agency_toptier_codes Named character vector of toptier codes.
#'   Default uses `AGENCY_TOPTIER_CODES`. Names are used as agency labels.
#' @param fiscal_years Integer vector of fiscal years to include. Default
#'   c(2023L, 2024L, 2025L, 2026L).
#' @return Tibble with columns: agency, fiscal_year, fiscal_period,
#'   obligations_cumulative, budgetary_resources, total_obligated_yr,
#'   total_outlayed_yr, obligation_rate.
#' @export
fetch_agency_obligations <- function(
  agency_toptier_codes = AGENCY_TOPTIER_CODES,
  fiscal_years         = c(2023L, 2024L, 2025L, 2026L)
) {
  log_event(sprintf(
    "USAspending budget fetch: %d agencies, FY %s",
    length(agency_toptier_codes),
    paste(fiscal_years, collapse = "/")
  ))

  results <- list()

  for (agency_name in names(agency_toptier_codes)) {
    code <- agency_toptier_codes[[agency_name]]
    url  <- sprintf("%s/%s/budgetary_resources/", BUDGET_API_BASE, code)

    log_event(sprintf("  Fetching obligations: %s (code %s)", agency_name, code))

    raw <- .usaspending_get(url, label = sprintf("budget %s", agency_name))
    if (is.null(raw)) next

    parsed <- .parse_agency_obligations_response(raw, agency_name)
    if (nrow(parsed) == 0L) {
      log_event(sprintf("  No data for %s", agency_name), "WARN")
      next
    }

    results[[agency_name]] <- parsed
  }

  if (length(results) == 0L) {
    log_event("USAspending budget fetch: no data returned", "WARN")
    return(.empty_obligations_tibble())
  }

  combined <- dplyr::bind_rows(results) |>
    dplyr::filter(fiscal_year %in% as.integer(fiscal_years))

  log_event(sprintf(
    "USAspending budget fetch complete: %d rows across %d agencies",
    nrow(combined), length(unique(combined$agency))
  ))

  combined
}

# --------------------------------------------------------------------------- #
# Internal: GET helper for USAspending (not POST)
# --------------------------------------------------------------------------- #

#' Simple GET helper for USAspending endpoints that don't use POST.
#' Follows the same error-handling pattern as `.treasury_get()`.
#' @keywords internal
.usaspending_get <- function(url, label = "USAspending GET") {
  resp <- tryCatch(
    {
      req <- build_request(url) |>
        httr2::req_error(is_error = function(resp) FALSE)
      raw_resp <- httr2::req_perform(req)
      if (httr2::resp_status(raw_resp) >= 400L) {
        err_body <- tryCatch(httr2::resp_body_string(raw_resp), error = function(e) "(no body)")
        log_event(sprintf(
          "%s HTTP %d: %s",
          label, httr2::resp_status(raw_resp), substr(err_body, 1L, 300L)
        ), "ERROR")
        return(NULL)
      }
      raw_resp
    },
    error = function(e) {
      log_event(sprintf("%s request failed: %s", label, conditionMessage(e)), "ERROR")
      NULL
    }
  )

  if (is.null(resp)) return(NULL)

  tryCatch(
    httr2::resp_body_json(resp, simplifyVector = FALSE),
    error = function(e) {
      log_event(sprintf("%s JSON parse failed: %s", label, conditionMessage(e)), "ERROR")
      NULL
    }
  )
}

# --------------------------------------------------------------------------- #
# Internal: Parse agency budgetary resources response
# --------------------------------------------------------------------------- #

#' Parse the nested JSON from the budgetary_resources endpoint into a flat tibble.
#'
#' The response has structure:
#'   `agency_data_by_year` (list of year objects)
#'     -> `agency_obligation_by_period` (list of period objects)
#'
#' @param raw Parsed JSON list from `.usaspending_get()`.
#' @param agency_name Character scalar used as the `agency` column value.
#' @keywords internal
.parse_agency_obligations_response <- function(raw, agency_name) {
  year_list <- raw[["agency_data_by_year"]]
  if (is.null(year_list) || length(year_list) == 0L) {
    return(.empty_obligations_tibble())
  }

  rows_list <- list()

  for (yr_obj in year_list) {
    fy              <- as.integer(yr_obj[["fiscal_year"]]          %||% NA_integer_)
    total_oblig_yr  <- .safe_as_numeric(yr_obj[["agency_total_obligated"]])
    total_outlay_yr <- .safe_as_numeric(yr_obj[["agency_total_outlayed"]])
    budg_resources  <- .safe_as_numeric(yr_obj[["agency_budgetary_resources"]])

    periods <- yr_obj[["agency_obligation_by_period"]]
    if (is.null(periods) || length(periods) == 0L) next

    for (p_obj in periods) {
      period_num     <- as.integer(p_obj[["period"]]             %||% NA_integer_)
      oblig_cumul    <- .safe_as_numeric(p_obj[["obligated"]])

      obligation_rate <- if (
        !is.na(budg_resources) && !is.na(oblig_cumul) && budg_resources > 0
      ) {
        oblig_cumul / budg_resources
      } else {
        NA_real_
      }

      rows_list[[length(rows_list) + 1L]] <- list(
        agency                = agency_name,
        fiscal_year           = fy,
        fiscal_period         = period_num,
        obligations_cumulative = oblig_cumul,
        budgetary_resources   = budg_resources,
        total_obligated_yr    = total_oblig_yr,
        total_outlayed_yr     = total_outlay_yr,
        obligation_rate       = obligation_rate
      )
    }
  }

  if (length(rows_list) == 0L) return(.empty_obligations_tibble())

  dplyr::bind_rows(lapply(rows_list, dplyr::as_tibble))
}

#' @keywords internal
.empty_obligations_tibble <- function() {
  dplyr::tibble(
    agency                 = character(0),
    fiscal_year            = integer(0),
    fiscal_period          = integer(0),
    obligations_cumulative = double(0),
    budgetary_resources    = double(0),
    total_obligated_yr     = double(0),
    total_outlayed_yr      = double(0),
    obligation_rate        = double(0)
  )
}

# --------------------------------------------------------------------------- #
# Award obligation flow — spending_over_time (new grants per fiscal month)
# --------------------------------------------------------------------------- #
#
# This is the "flow" signal: how many new grants were obligated each month.
# Complements GTAS (cumulative budget execution stock) and DTS (daily cash).
# Month field in the response = fiscal month (1=Oct, 2=Nov, ..., 12=Sep).

SPENDING_OVER_TIME_URL <- "https://api.usaspending.gov/api/v2/search/spending_over_time/"

# USAspending award type codes for grants and cooperative agreements.
GRANT_AWARD_TYPE_CODES <- c("02", "03", "04", "05")

#' Fetch month-by-month new grant obligation flow from USAspending
#'
#' Queries `/api/v2/search/spending_over_time/` with `group = "month"` to
#' get transaction-level new grant obligations per fiscal month. This is the
#' "flow" signal (new grants issued) vs. the GTAS "stock" signal (cumulative
#' budget execution rate). A near-zero flow while stock is also low confirms
#' the obligation drought is structural, not just reporting lag.
#'
#' @note Month field in the API response = fiscal month (1=October,
#'   2=November, ..., 12=September). This is the same convention as File C.
#'
#' @param agency_names Character vector of USAspending awarding agency names.
#'   Defaults to names of `AGENCY_TOPTIER_CODES`.
#' @param fiscal_years Integer vector of fiscal years to fetch.
#' @return Tibble with columns: agency, fiscal_year (int), fiscal_period (int),
#'   monthly_grant_obligations (dbl, in dollars).
#' @export
fetch_award_obligations_flow <- function(
  agency_names = names(AGENCY_TOPTIER_CODES),
  fiscal_years = c(2024L, 2025L, 2026L)
) {
  log_event(sprintf(
    "spending_over_time fetch: %d agencies, FY %s",
    length(agency_names),
    paste(fiscal_years, collapse = "/")
  ))

  results <- list()

  for (agency_name in agency_names) {
    for (fy in as.integer(fiscal_years)) {
      # Fiscal year: Oct 1 of prior calendar year through Sep 30 of named year
      start_cal <- sprintf("%d-10-01", fy - 1L)
      end_cal   <- format(min(as.Date(sprintf("%d-09-30", fy)), Sys.Date()), "%Y-%m-%d")

      body <- list(
        group   = "month",
        filters = list(
          award_type_codes = as.list(GRANT_AWARD_TYPE_CODES),
          agencies         = list(list(
            type = "awarding",
            tier = "toptier",
            name = agency_name
          )),
          time_period = list(list(
            start_date = start_cal,
            end_date   = end_cal
          ))
        ),
        subawards = FALSE
      )

      raw <- .spending_over_time_post(
        body,
        label = sprintf("spending_over_time %s FY%d", agency_name, fy)
      )
      if (is.null(raw)) next

      parsed <- .parse_spending_over_time(raw, agency_name)
      if (nrow(parsed) == 0L) next

      results[[paste(agency_name, fy)]] <- parsed
    }
  }

  if (length(results) == 0L) {
    log_event("fetch_award_obligations_flow: no data returned", "WARN")
    return(.empty_award_flow_tibble())
  }

  out <- dplyr::bind_rows(results)
  log_event(sprintf(
    "spending_over_time fetch complete: %d rows across %d agencies",
    nrow(out), length(unique(out$agency))
  ))
  out
}

# --------------------------------------------------------------------------- #
# Internal helpers for award obligations flow
# --------------------------------------------------------------------------- #

#' Direct POST helper (non-paginated).
#' Returns raw parsed JSON list, or NULL on error.
#' @keywords internal
.spending_over_time_post <- function(body, label = "spending_over_time",
                                     url = SPENDING_OVER_TIME_URL) {
  tryCatch(
    {
      req <- build_request(url) |>
        httr2::req_method("POST") |>
        httr2::req_body_json(body) |>
        httr2::req_error(is_error = function(resp) FALSE)

      raw_resp <- httr2::req_perform(req)

      if (httr2::resp_status(raw_resp) >= 400L) {
        err_body <- tryCatch(httr2::resp_body_string(raw_resp), error = function(e) "(no body)")
        log_event(sprintf(
          "%s HTTP %d: %s",
          label, httr2::resp_status(raw_resp), substr(err_body, 1L, 300L)
        ), "ERROR")
        return(NULL)
      }

      httr2::resp_body_json(raw_resp, simplifyVector = FALSE)
    },
    error = function(e) {
      log_event(sprintf("%s failed: %s", label, conditionMessage(e)), "ERROR")
      NULL
    }
  )
}

#' Parse spending_over_time JSON response into a flat tibble.
#'
#' Month in the response is fiscal month (1=Oct, 2=Nov, ..., 12=Sep).
#' @keywords internal
.parse_spending_over_time <- function(raw, agency_name) {
  result_list <- raw[["results"]]
  if (is.null(result_list) || length(result_list) == 0L) {
    return(.empty_award_flow_tibble())
  }

  n <- length(result_list)
  fiscal_year_vec   <- integer(n)
  fiscal_period_vec <- integer(n)
  obligations_vec   <- double(n)

  for (i in seq_len(n)) {
    r  <- result_list[[i]]
    tp <- r[["time_period"]]
    fiscal_year_vec[i]   <- as.integer(tp[["fiscal_year"]] %||% NA_integer_)
    fiscal_period_vec[i] <- as.integer(tp[["month"]]       %||% NA_integer_)
    obligations_vec[i]   <- .safe_as_numeric(r[["Grant_Obligations"]])
  }

  dplyr::tibble(
    agency                    = agency_name,
    fiscal_year               = fiscal_year_vec,
    fiscal_period             = fiscal_period_vec,
    monthly_grant_obligations = obligations_vec
  )
}

#' @keywords internal
.empty_award_flow_tibble <- function() {
  dplyr::tibble(
    agency                    = character(0),
    fiscal_year               = integer(0),
    fiscal_period             = integer(0),
    monthly_grant_obligations = double(0)
  )
}

# --------------------------------------------------------------------------- #
# CFDA program breakdown — spending_by_category (program-level targeting)
# --------------------------------------------------------------------------- #
#
# CRITICAL: The category goes in the URL PATH, not the request body.
# Correct: POST /api/v2/search/spending_by_category/cfda/
# Wrong:   POST /api/v2/search/spending_by_category/ with {"category": "cfda"}
#
# This reveals which specific NSF/NIH programs have collapsed — e.g.,
# NSF Social/Behavioral/Economic Sciences: -98% YoY (Oct-Mar FY2025→FY2026).
# GW tracks institution-level freezes; this adds program-level targeting detection.

SPENDING_BY_CATEGORY_BASE <- "https://api.usaspending.gov/api/v2/search/spending_by_category"

#' Fetch CFDA program-level grant obligations breakdown
#'
#' Queries `/api/v2/search/spending_by_category/{category}/` (category in path)
#' to break down new grant obligations by CFDA program number. Comparing FY2025
#' vs FY2026 reveals which programs are specifically targeted vs. continuing.
#'
#' Key findings (Oct–Mar comparison):
#' - NSF Social/Behavioral/Economic (47.075): -98% YoY
#' - NSF Biological Sciences (47.074): -82%
#' - NIH Allergy & Infectious Diseases (93.855, NIAID): -0.5% (essentially flat)
#' - NIH Cardiovascular (93.837): -56%
#'
#' @param agency_spec List with USAspending agency filter fields. Required:
#'   `type` ("awarding"|"funding"), `tier` ("toptier"|"subtier"), `name`.
#'   Optionally `toptier_name` when `tier = "subtier"`.
#'   Example: `list(type="awarding", tier="toptier", name="National Science Foundation")`
#' @param start_date Character YYYY-MM-DD start of period.
#' @param end_date Character YYYY-MM-DD end of period. Default today.
#' @param category Character. Category type. Default "cfda". Other options:
#'   "awarding_subagency", "state_territory", "federal_account",
#'   "program_activity", "object_class", "defc".
#' @param award_type_codes Character vector of award type codes.
#'   Default `GRANT_AWARD_TYPE_CODES` (02/03/04/05 = grants & coop agreements).
#' @param limit Integer. Results per page. Default 20L.
#' @return Tibble with columns: agency_label (chr), start_date (chr), end_date (chr),
#'   category (chr), cfda_code (chr), cfda_name (chr), obligation_amount (dbl).
#' @export
fetch_cfda_breakdown <- function(
  agency_spec,
  start_date,
  end_date       = format(Sys.Date(), "%Y-%m-%d"),
  category       = "cfda",
  award_type_codes = GRANT_AWARD_TYPE_CODES,
  limit          = 20L
) {
  url <- sprintf("%s/%s/", SPENDING_BY_CATEGORY_BASE, category)

  agency_label <- agency_spec[["name"]] %||% "Unknown"
  log_event(sprintf(
    "fetch_cfda_breakdown: %s %s %s–%s",
    agency_label, category, start_date, end_date
  ))

  body <- list(
    filters = list(
      award_type_codes = as.list(award_type_codes),
      agencies         = list(agency_spec),
      time_period      = list(list(start_date = start_date, end_date = end_date))
    ),
    limit   = as.integer(limit),
    page    = 1L
  )

  all_results <- list()
  has_next    <- TRUE

  while (has_next) {
    raw <- .spending_over_time_post(body, url = url, label = sprintf(
      "spending_by_category/%s %s p%d", category, agency_label, body$page
    ))
    if (is.null(raw)) break

    result_list <- raw[["results"]] %||% list()
    if (length(result_list) == 0L) break

    all_results <- c(all_results, result_list)
    has_next <- isTRUE(raw[["page_metadata"]][["hasNext"]])
    body$page <- body$page + 1L
  }

  if (length(all_results) == 0L) {
    return(.empty_cfda_tibble())
  }

  n <- length(all_results)
  codes_vec  <- character(n)
  names_vec  <- character(n)
  amount_vec <- double(n)

  for (i in seq_len(n)) {
    r             <- all_results[[i]]
    codes_vec[i]  <- as.character(r[["code"]]   %||% NA_character_)
    names_vec[i]  <- as.character(r[["name"]]   %||% NA_character_)
    amount_vec[i] <- .safe_as_numeric(r[["amount"]])
  }

  dplyr::tibble(
    agency_label      = agency_label,
    start_date        = start_date,
    end_date          = end_date,
    category          = category,
    cfda_code         = codes_vec,
    cfda_name         = names_vec,
    obligation_amount = amount_vec
  )
}

#' @keywords internal
.empty_cfda_tibble <- function() {
  dplyr::tibble(
    agency_label      = character(0),
    start_date        = character(0),
    end_date          = character(0),
    category          = character(0),
    cfda_code         = character(0),
    cfda_name         = character(0),
    obligation_amount = double(0)
  )
}

# --------------------------------------------------------------------------- #
# Geographic grant flow breakdown — state-level targeting detection
# --------------------------------------------------------------------------- #
#
# GW's CDC tracker is explicitly state-level (CA, MN, CO, IL). The
# spending_by_category/state_territory/ endpoint gives state-by-state grant
# flow in one call. Comparing FY2025 vs FY2026 reveals geographic targeting
# patterns independent of institution-level analysis.

#' Fetch state-level grant obligation breakdown (YoY)
#'
#' Convenience wrapper around `fetch_cfda_breakdown()` with
#' `category = "state_territory"`. Returns obligations per US state, enabling
#' geographic freeze detection: are certain states' grants disproportionately
#' targeted regardless of institution?
#'
#' @param agency_spec List with USAspending agency filter fields (same as
#'   `fetch_cfda_breakdown()`).
#' @param start_date,end_date ISO date strings.
#' @param limit Integer results per page. Default 60L (covers all 50 states + DC + territories).
#' @return Tibble with columns from `fetch_cfda_breakdown()`:
#'   agency_label, start_date, end_date, category="state_territory",
#'   cfda_code (state abbreviation), cfda_name (state name), obligation_amount.
#' @export
fetch_geographic_breakdown <- function(
  agency_spec,
  start_date,
  end_date = format(Sys.Date(), "%Y-%m-%d"),
  limit    = 60L
) {
  fetch_cfda_breakdown(
    agency_spec = agency_spec,
    start_date  = start_date,
    end_date    = end_date,
    category    = "state_territory",
    limit       = limit
  )
}
