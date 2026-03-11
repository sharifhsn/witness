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

# Fields requested from the API — only fields we actually parse into the tibble
USASPENDING_FIELDS <- c(
  "Award ID",
  "Recipient Name",
  "Awarding Agency",
  "Awarding Sub Agency",
  "Award Amount",
  "Total Outlays",
  "Start Date",
  "End Date",
  "Description",
  "CFDA Number"
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
  url <- "https://api.usaspending.gov/api/v2/search/spending_by_award/"

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
          "USAspending page %d HTTP %d: %s", body$page,
          httr2::resp_status(raw_resp), substr(err_body, 1, 300)
        ), "ERROR")
        NULL
      } else {
        raw_resp
      }
    },
    error = function(e) {
      log_event(sprintf("USAspending page %d failed: %s", body$page, conditionMessage(e)), "ERROR")
      NULL
    }
  )

  if (is.null(resp)) {
    return(list(results = dplyr::tibble(), has_next = FALSE))
  }

  parsed <- tryCatch(
    httr2::resp_body_json(resp, simplifyVector = FALSE),
    error = function(e) {
      log_event(sprintf("JSON parse failed on page %d: %s", body$page, conditionMessage(e)), "ERROR")
      NULL
    }
  )

  if (is.null(parsed)) {
    return(list(results = dplyr::tibble(), has_next = FALSE))
  }

  has_next <- isTRUE(parsed$page_metadata$hasNext)

  if (length(parsed$results) == 0L) {
    return(list(results = dplyr::tibble(), has_next = FALSE))
  }

  # Single-pass extraction: iterate once, build vectors, then one tibble call.
  n <- length(parsed$results)
  grant_ids  <- character(n)
  recip      <- character(n)
  agencies   <- character(n)
  sub_ag     <- character(n)
  amounts    <- double(n)
  outlays    <- double(n)
  start_raw  <- character(n)
  end_raw    <- character(n)
  descs      <- character(n)
  cfdas      <- character(n)

  for (i in seq_len(n)) {
    r <- parsed$results[[i]]
    grant_ids[i] <- r[["Award ID"]]             %||% NA_character_
    recip[i]     <- r[["Recipient Name"]]        %||% NA_character_
    agencies[i]  <- r[["Awarding Agency"]]       %||% NA_character_
    sub_ag[i]    <- r[["Awarding Sub Agency"]]   %||% NA_character_
    amounts[i]   <- as.numeric(r[["Award Amount"]]  %||% NA_real_)
    outlays[i]   <- as.numeric(r[["Total Outlays"]] %||% NA_real_)
    start_raw[i] <- as.character(r[["Start Date"]]  %||% NA_character_)
    end_raw[i]   <- as.character(r[["End Date"]]    %||% NA_character_)
    descs[i]     <- r[["Description"]]           %||% NA_character_
    cfdas[i]     <- r[["CFDA Number"]]           %||% NA_character_
  }

  # Clean description artifacts from USAspending ETL
  descs <- sub("^DESCRIPTION:\\s*", "", descs)        # field label prefix (29% of records)
  descs <- gsub("<!\\[CDATA\\[|\\]\\]>", "", descs)   # XML CDATA wrappers
  descs <- gsub("<[^>]+>", "", descs)                  # strip HTML tags

  rows <- dplyr::tibble(
    grant_number   = grant_ids,
    recipient_name = recip,
    agency_name    = agencies,
    sub_agency     = sub_ag,
    award_amount   = amounts,
    total_outlays  = outlays,
    action_date    = parse_date_flexible(start_raw),
    end_date       = parse_date_flexible(end_raw),
    description    = descs,
    cfda_number    = cfdas
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

# %||% is defined in utils.R (canonical location)
