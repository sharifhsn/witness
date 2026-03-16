#' @title USAspending.gov Federal Grant Award Fetcher
#' @description Queries the USAspending.gov Awards Search API to retrieve federal
#'   grant and cooperative agreement data. Intended for cross-referencing against
#'   Grant Witness termination records to surface discrepancies between announced
#'   funding actions and official obligation data.
#'
#' @section API reference:
#'   POST https://api.usaspending.gov/api/v2/search/spending_by_award/
#'   No authentication required. Rate limit: ~1 req/2 sec (enforced by build_request()).

# API constraints (documented at https://api.usaspending.gov/)
USASPENDING_MAX_PAGE_SIZE <- 100L

# Award type codes that constitute grants and cooperative agreements
GRANT_AWARD_CODES <- c("02", "03", "04", "05")

# Fields requested from the API — only fields we actually parse into the tibble.
# Contracts reference:
#   https://github.com/fedspendingtransparency/usaspending-api/blob/master/
#   usaspending_api/api_contracts/contracts/v2/search/spending_by_award.md
USASPENDING_FIELDS <- c(
  "Award ID",
  "Recipient Name",
  "Recipient UEI",          # preferred stable identifier (replaces deprecated DUNS)
  "Awarding Agency",
  "Awarding Sub Agency",
  "Award Amount",
  "Total Outlays",
  "Start Date",
  "End Date",
  "Last Modified Date",     # detects recent admin changes without full transaction scan
  "Description",
  "CFDA Number",
  "def_codes",              # array: COVID/IIJA emergency fund codes on this award
  "generated_internal_id"  # used directly for File C lookup (ASST_NON_{id}_{cgac})
)

#' Build the JSON body for one USAspending page query.
#' @export
build_usaspending_body <- function(agency_name, start_date, end_date, page, limit = 100L) {
  limit <- min(limit, USASPENDING_MAX_PAGE_SIZE)
  list(
    filters = list(
      award_type_codes = GRANT_AWARD_CODES,
      agencies = list(
        list(type = "awarding", tier = "toptier", name = agency_name)
      ),
      time_period = list(
        list(start_date = start_date, end_date = end_date)
      )
    ),
    fields = USASPENDING_FIELDS,
    page    = page,
    limit   = limit,
    sort    = "Award Amount",
    order   = "desc"
  )
}

#' Fetch one page from USAspending. Returns list(results = tibble, has_next = logical).
#' @export
fetch_usaspending_page <- function(body) {
  raw <- .usaspending_post(
    "https://api.usaspending.gov/api/v2/search/spending_by_award/",
    body, "USAspending"
  )

  if (length(raw$results) == 0L) {
    return(list(results = dplyr::tibble(), has_next = raw$has_next))
  }

  has_next <- raw$has_next

  # Single-pass extraction: iterate once, build vectors, then one tibble call.
  n <- length(raw$results)
  grant_ids    <- character(n)
  recip        <- character(n)
  ueis         <- character(n)
  agencies     <- character(n)
  sub_ag       <- character(n)
  amounts      <- double(n)
  outlays      <- double(n)
  start_raw    <- character(n)
  end_raw      <- character(n)
  last_mod_raw <- character(n)
  descs        <- character(n)
  cfdas        <- character(n)
  def_codes_v  <- character(n)   # collapsed comma-separated string; array in API
  gen_ids      <- character(n)

  for (i in seq_len(n)) {
    r <- raw$results[[i]]
    grant_ids[i]    <- r[["Award ID"]]             %||% NA_character_
    recip[i]        <- r[["Recipient Name"]]        %||% NA_character_
    ueis[i]         <- r[["Recipient UEI"]]         %||% NA_character_
    agencies[i]     <- r[["Awarding Agency"]]       %||% NA_character_
    sub_ag[i]       <- r[["Awarding Sub Agency"]]   %||% NA_character_
    amounts[i]      <- as.numeric(r[["Award Amount"]]     %||% NA_real_)
    outlays[i]      <- as.numeric(r[["Total Outlays"]]    %||% NA_real_)
    start_raw[i]    <- as.character(r[["Start Date"]]     %||% NA_character_)
    end_raw[i]      <- as.character(r[["End Date"]]       %||% NA_character_)
    last_mod_raw[i] <- as.character(r[["Last Modified Date"]] %||% NA_character_)
    descs[i]        <- r[["Description"]]           %||% NA_character_
    cfdas[i]        <- r[["CFDA Number"]]           %||% NA_character_
    gen_ids[i]      <- r[["generated_internal_id"]] %||% NA_character_
    # def_codes is an array of strings; collapse to comma-separated for storage
    dc              <- r[["def_codes"]]
    def_codes_v[i]  <- if (is.null(dc) || length(dc) == 0L) NA_character_
                       else paste(unlist(dc), collapse = ",")
  }

  # Clean description artifacts from USAspending ETL
  descs <- sub("^DESCRIPTION:\\s*", "", descs)        # field label prefix (29% of records)
  descs <- gsub("<!\\[CDATA\\[|\\]\\]>", "", descs)   # XML CDATA wrappers
  descs <- gsub("<[^>]+>", "", descs)                  # strip HTML tags

  rows <- dplyr::tibble(
    grant_number          = grant_ids,
    recipient_name        = recip,
    recipient_uei         = ueis,
    agency_name           = agencies,
    sub_agency            = sub_ag,
    award_amount          = amounts,
    total_outlays         = outlays,
    action_date           = parse_date_flexible(start_raw),
    end_date              = parse_date_flexible(end_raw),
    last_modified_date    = parse_date_flexible(last_mod_raw),
    description           = descs,
    cfda_number           = cfdas,
    def_codes             = def_codes_v,
    generated_internal_id = gen_ids
  )

  list(results = rows, has_next = has_next)
}

#' Fetch federal grant awards from USAspending.gov
#'
#' Iterates over agencies, paginates each, and returns a combined tibble with
#' columns: grant_number, recipient_name, agency_name, sub_agency, award_amount,
#' total_outlays, action_date, end_date, description, cfda_number.
#'
#' @param agencies Character vector of toptier agency names.
#' @param start_date,end_date ISO date strings for the performance period window.
#' @param max_records Safety cap per agency. @param limit Records per page.
#' @export
fetch_usaspending <- function(
  agencies   = c(
    "Department of Health and Human Services",
    "National Science Foundation",
    "Environmental Protection Agency"
  ),
  start_date  = "2024-10-01",
  end_date    = NULL,
  max_records = 5000L,
  limit       = 100L
) {
  end_date <- end_date %||% format(Sys.Date(), "%Y-%m-%d")
  limit    <- min(limit, USASPENDING_MAX_PAGE_SIZE)

  log_event(
    sprintf(
      "USAspending fetch: %d agenc%s | window %s to %s | max %d records/agency",
      length(agencies),
      ifelse(length(agencies) == 1L, "y", "ies"),
      start_date, end_date, max_records
    ),
    "INFO"
  )

  agency_results <- purrr::map(agencies, function(agency) {
    log_event(sprintf("Fetching agency: %s", agency), "INFO")
    max_pages  <- ceiling(max_records / limit)
    pages      <- vector("list", max_pages)
    page       <- 1L
    total_seen <- 0L
    page_idx   <- 0L

    repeat {
      log_event(sprintf("  %s — page %d (collected %d so far)", agency, page, total_seen), "INFO")

      body       <- build_usaspending_body(agency, start_date, end_date, page, limit)
      page_data  <- fetch_usaspending_page(body)

      n_rows <- nrow(page_data$results)

      if (n_rows > 0L) {
        page_idx          <- page_idx + 1L
        pages[[page_idx]] <- page_data$results
        total_seen        <- total_seen + n_rows
      }

      # Stop conditions: no more pages, empty response, or safety cap reached
      if (!page_data$has_next || n_rows == 0L || total_seen >= max_records) {
        break
      }

      page <- page + 1L
    }

    log_event(
      sprintf("  %s — done. %d records fetched.", agency, total_seen),
      "INFO"
    )

    if (page_idx == 0L) {
      return(dplyr::tibble())
    }

    dplyr::bind_rows(pages[seq_len(page_idx)]) |>
      # Enforce max_records after binding in case final page pushed over
      dplyr::slice_head(n = max_records)
  })

  combined <- dplyr::bind_rows(agency_results)

  log_event(
    sprintf("USAspending fetch complete: %d total records across %d agenc%s.",
            nrow(combined), length(agencies),
            ifelse(length(agencies) == 1L, "y", "ies")),
    "INFO"
  )

  combined
}

# --------------------------------------------------------------------------- #
# Cross-agency institution grant query (recipient_search_text)
# --------------------------------------------------------------------------- #
#
# The `recipient_search_text` filter queries by institution name/UEI/DUNS
# across ALL agencies in a single call. This is fundamentally better than
# our current approach (separate agency queries + fuzzy join) for
# institution-level freeze analysis:
#
# Current approach: fetch all HHS awards → join → fuzzy-match institution names
#   (13.6% false positive rate; misses cross-agency grants)
#
# New approach: query "HARVARD" once → get back all UEIs matching that pattern
#   across all agencies, with precise UEI identifiers for downstream use.
#
# GW tracks institutions separately per agency. This gives unified cross-agency
# institution totals — a capability gap in GW's current methodology.

#' Fetch all federal grants at a named institution across all agencies
#'
#' Uses the `recipient_search_text` filter in AdvancedFilterObject to search
#' by institution name across all awarding agencies simultaneously. Returns
#' the same tibble schema as `fetch_usaspending()` but filtered to a specific
#' recipient, with `recipient_uei` populated for precise downstream matching.
#'
#' This is superior to per-agency queries + fuzzy join for institution analysis:
#' one call, exact UEI identifiers, cross-agency totals, no false positives.
#'
#' @param institution_name Character scalar. Partial name for search
#'   (e.g., "HARVARD", "COLUMBIA UNIVERSITY"). Case-insensitive.
#' @param start_date,end_date ISO date strings. Default FY2020–present.
#' @param award_type_codes Award type codes. Default grants + cooperative
#'   agreements. Pass `c("A","B","C","D")` to include research contracts.
#' @param max_records Integer safety cap. Default 500L.
#' @return Tibble with same schema as `fetch_usaspending()`, filtered to the
#'   institution. Includes `recipient_uei` for downstream exact matching.
#' @export
fetch_institution_grants <- function(
  institution_name,
  start_date       = "2020-10-01",
  end_date         = format(Sys.Date(), "%Y-%m-%d"),
  award_type_codes = GRANT_AWARD_CODES,
  max_records      = 500L
) {
  log_event(sprintf(
    "fetch_institution_grants: '%s' %s–%s",
    institution_name, start_date, end_date
  ))

  all_rows <- list()
  page     <- 1L
  limit    <- USASPENDING_MAX_PAGE_SIZE

  repeat {
    if (length(all_rows) >= max_records) break

    body <- list(
      filters = list(
        award_type_codes     = as.list(award_type_codes),
        recipient_search_text = list(institution_name),
        time_period          = list(list(start_date = start_date, end_date = end_date))
      ),
      fields  = as.list(USASPENDING_FIELDS),
      page    = page,
      limit   = limit,
      sort    = "Award Amount",
      order   = "desc"
    )

    raw_page <- fetch_usaspending_page(body)
    if (nrow(raw_page$results) == 0L) break

    all_rows[[page]] <- raw_page$results
    if (!raw_page$has_next) break
    page <- page + 1L
  }

  if (length(all_rows) == 0L) {
    log_event(sprintf("fetch_institution_grants: no results for '%s'", institution_name), "WARN")
    return(dplyr::tibble())
  }

  result <- dplyr::bind_rows(all_rows) |>
    utils::head(max_records)

  log_event(sprintf(
    "fetch_institution_grants: %d awards at '%s' across %d agencies",
    nrow(result),
    institution_name,
    length(unique(result$agency_name))
  ))

  result
}

# --------------------------------------------------------------------------- #
# Shared POST helper
# --------------------------------------------------------------------------- #

# POST a JSON body to a USAspending endpoint, return parsed results list or NULL.
# Handles HTTP errors, retries (via build_request), and JSON parse failures.
# Returns list(results = <list>, has_next = <logical>) or the empty sentinel.
.usaspending_post <- function(url, body, label = "USAspending") {
  empty <- list(results = list(), has_next = FALSE)

  resp <- tryCatch(
    {
      req <- build_request(url) |>
        httr2::req_method("POST") |>
        httr2::req_body_json(body) |>
        httr2::req_error(is_error = function(resp) FALSE)
      raw_resp <- httr2::req_perform(req)
      if (httr2::resp_status(raw_resp) >= 400) {
        err_body <- tryCatch(httr2::resp_body_string(raw_resp), error = function(e) "(no body)")
        log_event(sprintf(
          "%s page %d HTTP %d: %s", label, body$page,
          httr2::resp_status(raw_resp), substr(err_body, 1, 300)
        ), "ERROR")
        return(empty)
      }
      raw_resp
    },
    error = function(e) {
      log_event(sprintf("%s page %d failed: %s", label, body$page, conditionMessage(e)), "ERROR")
      NULL
    }
  )

  if (is.null(resp)) return(empty)

  parsed <- tryCatch(
    httr2::resp_body_json(resp, simplifyVector = FALSE),
    error = function(e) {
      log_event(sprintf("%s JSON parse failed on page %d: %s", label, body$page, conditionMessage(e)), "ERROR")
      NULL
    }
  )

  if (is.null(parsed)) return(empty)

  list(
    results  = parsed$results %||% list(),
    has_next = isTRUE(parsed$page_metadata$hasNext)
  )
}

# --------------------------------------------------------------------------- #
# Transaction-level fetcher
# --------------------------------------------------------------------------- #

# Fields for transaction-level queries
TRANSACTION_FIELDS <- c(
  "Award ID",
  "Action Date",
  "Transaction Amount",
  "Transaction Description",
  "Action Type",
  "Mod"
)

#' Build the JSON body for one transaction search page.
#' @param award_ids Character vector of Award IDs to filter on.
#' @param page Integer page number.
#' @param limit Records per page (max 100).
#' @return List suitable for `req_body_json()`.
#' @keywords internal
build_transaction_body <- function(award_ids, page, limit = 100L) {
  limit <- min(limit, USASPENDING_MAX_PAGE_SIZE)
  list(
    filters = list(
      award_type_codes = GRANT_AWARD_CODES,
      award_ids = as.list(award_ids)
    ),
    fields = TRANSACTION_FIELDS,
    page   = page,
    limit  = limit,
    sort   = "Action Date",
    order  = "desc"
  )
}

#' Fetch one page of transaction search results.
#' @param body Request body list from `build_transaction_body()`.
#' @return List with `results` (tibble) and `has_next` (logical).
#' @keywords internal
fetch_transaction_page <- function(body) {
  raw <- .usaspending_post(
    "https://api.usaspending.gov/api/v2/search/spending_by_transaction/",
    body, "Transaction"
  )

  if (length(raw$results) == 0L) {
    return(list(results = dplyr::tibble(), has_next = raw$has_next))
  }

  n <- length(raw$results)
  award_ids  <- character(n)
  dates_raw  <- character(n)
  amounts    <- double(n)
  descs      <- character(n)
  act_types  <- character(n)
  mods       <- character(n)

  for (i in seq_len(n)) {
    r <- raw$results[[i]]
    award_ids[i]  <- r[["Award ID"]]                %||% NA_character_
    dates_raw[i]  <- as.character(r[["Action Date"]] %||% NA_character_)
    amounts[i]    <- as.numeric(r[["Transaction Amount"]] %||% NA_real_)
    descs[i]      <- r[["Transaction Description"]]  %||% NA_character_
    act_types[i]  <- r[["Action Type"]]              %||% NA_character_
    mods[i]       <- r[["Mod"]]                      %||% NA_character_
  }

  rows <- dplyr::tibble(
    grant_number         = award_ids,
    transaction_date     = parse_date_flexible(dates_raw),
    obligation_amount    = amounts,
    transaction_desc     = descs,
    action_type          = act_types,
    modification_number  = mods
  )

  list(results = rows, has_next = raw$has_next)
}

#' Fetch transaction-level data for a set of award IDs
#'
#' Queries USAspending transaction search in batches (to keep filter lists
#' manageable) and paginates each batch. Used to determine the actual last
#' disbursement date for possible-freeze grants.
#'
#' @param award_ids Character vector of Award IDs (grant_number values).
#' @param batch_size Number of award IDs per API query. Default 25.
#' @param max_pages Maximum pages to fetch per batch. Default 10.
#' @return Tibble with columns: grant_number, transaction_date,
#'   obligation_amount, transaction_desc, action_type, modification_number.
#' @export
fetch_transactions <- function(award_ids, batch_size = 25L, max_pages = 10L) {
  award_ids <- unique(award_ids[!is.na(award_ids)])

  if (length(award_ids) == 0L) {
    log_event("fetch_transactions: no award IDs provided", "WARN")
    return(dplyr::tibble(
      grant_number = character(0), transaction_date = as.Date(character(0)),
      obligation_amount = double(0), transaction_desc = character(0),
      action_type = character(0), modification_number = character(0)
    ))
  }

  log_event(sprintf(
    "fetch_transactions: %d unique award IDs, batch_size=%d",
    length(award_ids), batch_size
  ))

  batches <- split(award_ids, ceiling(seq_along(award_ids) / batch_size))
  all_results <- vector("list", length(batches))

  for (b in seq_along(batches)) {
    batch_ids <- batches[[b]]
    log_event(sprintf("  Batch %d/%d (%d IDs)", b, length(batches), length(batch_ids)))

    batch_pages <- vector("list", max_pages)
    page_idx <- 0L
    page <- 1L

    repeat {
      body <- build_transaction_body(batch_ids, page)
      page_data <- fetch_transaction_page(body)

      if (nrow(page_data$results) > 0L) {
        page_idx <- page_idx + 1L
        batch_pages[[page_idx]] <- page_data$results
      }

      if (!page_data$has_next || nrow(page_data$results) == 0L || page >= max_pages) {
        break
      }
      page <- page + 1L
    }

    if (page_idx > 0L) {
      all_results[[b]] <- dplyr::bind_rows(batch_pages[seq_len(page_idx)])
    }
  }

  combined <- dplyr::bind_rows(all_results)
  log_event(sprintf("fetch_transactions complete: %d transactions", nrow(combined)))
  combined
}

# --------------------------------------------------------------------------- #
# Transaction intelligence — termination + reinstatement detection
# --------------------------------------------------------------------------- #

# USAspending action type codes that represent formal grant termination.
# E = Termination for Convenience, F = Termination for Default.
# These are already fetched in `action_type` column of transaction data
# but were previously unused analytically.
TERMINATION_ACTION_TYPES <- c("E", "F")

#' Extract termination actions from transaction data
#'
#' Filters transaction-level data for termination action types (E = Termination
#' for Convenience, F = Termination for Default) and returns the most recent
#' termination action per grant.
#'
#' This provides a second, independent confirmation that a grant was formally
#' terminated, with a USAspending-recorded date that may differ from the forensic
#' notice date. This date is more reliable for computing the 120-day closeout
#' window in [confirm_post_termination_activity()].
#'
#' @param transaction_data Tibble from [fetch_transactions()].
#' @return Tibble: grant_number, termination_action_date, termination_action_type,
#'   termination_mod_number.
#' @export
extract_termination_actions <- function(transaction_data) {
  if (nrow(transaction_data) == 0L) {
    return(dplyr::tibble(
      grant_number            = character(0),
      termination_action_date = as.Date(character(0)),
      termination_action_type = character(0),
      termination_mod_number  = character(0)
    ))
  }

  result <- transaction_data |>
    dplyr::filter(action_type %in% TERMINATION_ACTION_TYPES,
                  !is.na(transaction_date)) |>
    dplyr::arrange(grant_number, dplyr::desc(transaction_date)) |>
    dplyr::distinct(grant_number, .keep_all = TRUE) |>
    dplyr::select(
      grant_number,
      termination_action_date = transaction_date,
      termination_action_type = action_type,
      termination_mod_number  = modification_number
    )

  log_event(sprintf(
    "extract_termination_actions: %d grants with USAspending-recorded termination",
    nrow(result)
  ))

  result
}

#' Detect reinstatement pattern from transaction data
#'
#' Identifies grants that received a termination action (E or F) followed by a
#' new continuation action (A, B, C, or G). These are candidates for GW's
#' "Possibly Reinstated" category — grants formally terminated but subsequently
#' re-activated through a new modification.
#'
#' This detects the transaction-level pattern only. Confirming "Reinstated"
#' (vs. "Possibly Reinstated") additionally requires post-reinstatement outlays
#' in File C data.
#'
#' @param transaction_data Tibble from [fetch_transactions()].
#' @return Tibble: grant_number, termination_action_date, reinstatement_action_date,
#'   reinstatement_action_type.
#' @export
detect_reinstatement_pattern <- function(transaction_data) {
  empty <- dplyr::tibble(
    grant_number              = character(0),
    termination_action_date   = as.Date(character(0)),
    reinstatement_action_date = as.Date(character(0)),
    reinstatement_action_type = character(0)
  )

  if (nrow(transaction_data) == 0L) return(empty)

  # Most recent termination action per grant
  terminations <- transaction_data |>
    dplyr::filter(action_type %in% TERMINATION_ACTION_TYPES,
                  !is.na(transaction_date)) |>
    dplyr::arrange(grant_number, dplyr::desc(transaction_date)) |>
    dplyr::distinct(grant_number, .keep_all = TRUE) |>
    dplyr::select(grant_number, termination_action_date = transaction_date)

  if (nrow(terminations) == 0L) return(empty)

  # Earliest new-activity action (A/B/C/G) AFTER the termination date
  reinstatements <- transaction_data |>
    dplyr::filter(action_type %in% c("A", "B", "C", "G"),
                  !is.na(transaction_date)) |>
    dplyr::inner_join(terminations, by = "grant_number") |>
    dplyr::filter(transaction_date > termination_action_date) |>
    dplyr::arrange(grant_number, transaction_date) |>
    dplyr::distinct(grant_number, .keep_all = TRUE) |>
    dplyr::select(
      grant_number,
      termination_action_date,
      reinstatement_action_date = transaction_date,
      reinstatement_action_type = action_type
    )

  if (nrow(reinstatements) > 0L) {
    log_event(sprintf(
      "detect_reinstatement_pattern: %d grants show termination followed by new activity",
      nrow(reinstatements)
    ), "WARN")
  } else {
    log_event("detect_reinstatement_pattern: no reinstatement patterns detected")
  }

  reinstatements
}

# --------------------------------------------------------------------------- #
# Subaward fetcher
# --------------------------------------------------------------------------- #

# Fields for subaward queries (different schema from prime awards)
SUBAWARD_FIELDS <- c(
  "Sub-Award ID",
  "Sub-Awardee Name",
  "Sub-Award Date",
  "Sub-Award Amount",
  "Prime Award ID",
  "Prime Recipient Name",
  "Awarding Agency",
  "Awarding Sub Agency"
)

#' Build the JSON body for a subaward search page.
#' @param agency_name Character. Toptier agency name.
#' @param start_date,end_date ISO date strings.
#' @param page Integer page number.
#' @param limit Records per page (max 100).
#' @return List suitable for `req_body_json()`.
#' @keywords internal
build_subaward_body <- function(agency_name, start_date, end_date, page, limit = 100L) {
  limit <- min(limit, USASPENDING_MAX_PAGE_SIZE)
  list(
    filters = list(
      award_type_codes = GRANT_AWARD_CODES,
      agencies = list(
        list(type = "awarding", tier = "toptier", name = agency_name)
      ),
      time_period = list(
        list(start_date = start_date, end_date = end_date)
      )
    ),
    fields = SUBAWARD_FIELDS,
    page    = page,
    limit   = limit,
    sort    = "Sub-Award Amount",
    order   = "desc",
    subawards = TRUE
  )
}

#' Fetch one page of subaward search results.
#' @param body Request body list from `build_subaward_body()`.
#' @return List with `results` (tibble) and `has_next` (logical).
#' @keywords internal
fetch_subaward_page <- function(body) {
  raw <- .usaspending_post(
    "https://api.usaspending.gov/api/v2/search/spending_by_award/",
    body, "Subaward"
  )

  if (length(raw$results) == 0L) {
    return(list(results = dplyr::tibble(), has_next = raw$has_next))
  }

  n <- length(raw$results)
  sub_ids     <- character(n)
  sub_names   <- character(n)
  sub_dates   <- character(n)
  sub_amounts <- double(n)
  prime_ids   <- character(n)
  prime_names <- character(n)
  agencies    <- character(n)
  sub_ag      <- character(n)

  for (i in seq_len(n)) {
    r <- raw$results[[i]]
    sub_ids[i]     <- r[["Sub-Award ID"]]        %||% NA_character_
    sub_names[i]   <- r[["Sub-Awardee Name"]]    %||% NA_character_
    sub_dates[i]   <- as.character(r[["Sub-Award Date"]] %||% NA_character_)
    sub_amounts[i] <- as.numeric(r[["Sub-Award Amount"]] %||% NA_real_)
    prime_ids[i]   <- r[["Prime Award ID"]]      %||% NA_character_
    prime_names[i] <- r[["Prime Recipient Name"]] %||% NA_character_
    agencies[i]    <- r[["Awarding Agency"]]      %||% NA_character_
    sub_ag[i]      <- r[["Awarding Sub Agency"]]  %||% NA_character_
  }

  rows <- dplyr::tibble(
    subaward_id       = sub_ids,
    subawardee_name   = sub_names,
    subaward_date     = parse_date_flexible(sub_dates),
    subaward_amount   = sub_amounts,
    prime_award_id    = prime_ids,
    prime_recipient   = prime_names,
    agency_name       = agencies,
    sub_agency        = sub_ag
  )

  list(results = rows, has_next = raw$has_next)
}

#' Fetch subaward data for tracked agencies
#'
#' Queries USAspending subaward search to find money flowing from prime
#' recipients to sub-recipients. Useful for detecting downstream impact
#' of institutional freezes and workaround patterns.
#'
#' @param agencies Character vector of toptier agency names.
#' @param start_date,end_date ISO date strings.
#' @param max_records Safety cap per agency.
#' @return Tibble with subaward details.
#' @export
fetch_subawards <- function(
  agencies   = c(
    "Department of Health and Human Services",
    "National Science Foundation",
    "Environmental Protection Agency"
  ),
  start_date  = "2024-10-01",
  end_date    = NULL,
  max_records = 5000L
) {
  end_date <- end_date %||% format(Sys.Date(), "%Y-%m-%d")

  log_event(sprintf(
    "Subaward fetch: %d agencies | window %s to %s",
    length(agencies), start_date, end_date
  ))

  agency_results <- purrr::map(agencies, function(agency) {
    log_event(sprintf("Fetching subawards: %s", agency))
    max_pages <- ceiling(max_records / USASPENDING_MAX_PAGE_SIZE)
    pages     <- vector("list", max_pages)
    page      <- 1L
    total     <- 0L
    page_idx  <- 0L

    repeat {
      body <- build_subaward_body(agency, start_date, end_date, page)
      page_data <- fetch_subaward_page(body)
      n_rows <- nrow(page_data$results)

      if (n_rows > 0L) {
        page_idx <- page_idx + 1L
        pages[[page_idx]] <- page_data$results
        total <- total + n_rows
      }

      if (!page_data$has_next || n_rows == 0L || total >= max_records) break
      page <- page + 1L
    }

    log_event(sprintf("  %s — %d subawards fetched", agency, total))
    if (page_idx == 0L) return(dplyr::tibble())
    dplyr::bind_rows(pages[seq_len(page_idx)]) |>
      dplyr::slice_head(n = max_records)
  })

  combined <- dplyr::bind_rows(agency_results)
  log_event(sprintf("Subaward fetch complete: %d total subawards", nrow(combined)))
  combined
}

# --------------------------------------------------------------------------- #
# Subaward impact — prime-award-level grouped counts for impact quantification
# --------------------------------------------------------------------------- #

# URL for grouped subaward endpoint (no pagination needed: one row per prime award)
SUBAWARD_GROUPED_URL <- "https://api.usaspending.gov/api/v2/search/spending_by_subaward_grouped/"
SUBAWARD_GROUPED_BATCH_SIZE <- 100L

#' Fetch per-prime-award subaward impact metrics
#'
#' Queries the USAspending `spending_by_subaward_grouped` endpoint to get
#' per-prime-award subaward counts and obligations for a set of grant IDs.
#' More efficient than individual per-subaward record fetches for impact
#' quantification across hundreds of terminated/frozen grants.
#'
#' Used to answer: "When this grant was terminated, how many sub-recipients
#' (community colleges, small labs, NGOs) lost funding downstream?"
#'
#' @param award_ids Character vector of prime award IDs (e.g. "R01AI123456").
#'   NAs and duplicates are silently removed.
#' @return Tibble: `award_id` (chr), `subaward_count` (int),
#'   `subaward_obligation` (dbl), `award_generated_internal_id` (chr).
#'   Prime awards with no subawards are omitted by the API.
#' @export
fetch_subaward_impact <- function(award_ids) {
  award_ids <- unique(award_ids[!is.na(award_ids)])

  if (length(award_ids) == 0L) {
    log_event("fetch_subaward_impact: no award IDs provided", "WARN")
    return(.empty_subaward_impact_tibble())
  }

  log_event(sprintf("fetch_subaward_impact: %d unique prime awards", length(award_ids)))

  # Batch to respect body size limits; 100 IDs per call
  batches <- split(award_ids,
                   ceiling(seq_along(award_ids) / SUBAWARD_GROUPED_BATCH_SIZE))

  results <- purrr::map(batches, function(batch) {
    batch_pages <- list()
    page        <- 1L

    repeat {
      body <- list(
        filters = list(award_ids = as.list(batch)),
        limit   = USASPENDING_MAX_PAGE_SIZE,
        page    = page
      )
      raw <- .usaspending_post(SUBAWARD_GROUPED_URL, body, "Subaward Impact")
      if (length(raw$results) == 0L) break
      batch_pages[[page]] <- .parse_subaward_impact_records(raw$results)
      if (!raw$has_next) break
      page <- page + 1L
    }

    if (length(batch_pages) == 0L) return(.empty_subaward_impact_tibble())
    dplyr::bind_rows(batch_pages)
  })

  combined <- dplyr::bind_rows(results)
  log_event(sprintf(
    "fetch_subaward_impact complete: %d prime awards have subawards",
    nrow(combined)
  ))
  combined
}

#' @keywords internal
.parse_subaward_impact_records <- function(records) {
  n <- length(records)
  if (n == 0L) return(.empty_subaward_impact_tibble())

  award_ids       <- character(n)
  subaward_counts <- integer(n)
  obligations     <- double(n)
  gen_ids         <- character(n)

  for (i in seq_len(n)) {
    r <- records[[i]]
    award_ids[i]       <- r[["award_id"]]                       %||% NA_character_
    subaward_counts[i] <- as.integer(r[["subaward_count"]]      %||% NA_integer_)
    obligations[i]     <- as.numeric(r[["subaward_obligation"]] %||% NA_real_)
    gen_ids[i]         <- r[["award_generated_internal_id"]]    %||% NA_character_
  }

  dplyr::tibble(
    award_id                    = award_ids,
    subaward_count              = subaward_counts,
    subaward_obligation         = obligations,
    award_generated_internal_id = gen_ids
  )
}

#' @keywords internal
.empty_subaward_impact_tibble <- function() {
  dplyr::tibble(
    award_id                    = character(0),
    subaward_count              = integer(0),
    subaward_obligation         = double(0),
    award_generated_internal_id = character(0)
  )
}

# %||% is defined in utils.R (canonical location)
