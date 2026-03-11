#' @title NIH Reporter API Scraper
#' @description Queries the NIH Reporter API v2 for terminated grant projects
#'   and returns a tibble conforming to the Grant Witness canonical notice schema.
#'
#' The NIH Reporter API uses offset-based pagination with a maximum page size of
#' 500 and a hard offset cap of 14,999. Results are sorted by `project_end_date`
#' descending so the most recently closed grants appear first. No authentication
#' is required; the recommended server-side rate limit is 1 request/second.
#'
#' Note: `include_active_projects = FALSE` returns ALL inactive projects
#' (completed, expired, terminated). The default date window is narrowed to
#' recent months to keep the result set manageable.
#'
#' @seealso \url{https://api.reporter.nih.gov/}

NIH_API_URL <- "https://api.reporter.nih.gov/v2/projects/search"
NIH_PAGE_SIZE <- 500L
NIH_MAX_OFFSET <- 14999L  # API hard limit — returns 400 above this

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

#' Scrape terminated NIH grant projects from the Reporter API
#'
#' Paginates through inactive projects in the date window. Returns a tibble
#' with columns: agency_name, institute, notice_date, date_added, source_url,
#' raw_text_snippet, grant_number, org_name, org_state, award_amount, is_active.
#'
#' @param from_date,to_date ISO 8601 date strings for the project_end_date window.
#' @param max_records Safety cap on total records to fetch.
#' @export
scrape_nih <- function(from_date = "2025-01-01", to_date = NULL, max_records = 10000L) {
  to_date <- to_date %||% as.character(Sys.Date())

  log_event(sprintf("NIH scrape starting: %s to %s (max %d records)", from_date, to_date, max_records))

  # Fetch first page to discover total result count
  first_page <- fetch_nih_page(from_date, to_date, offset = 0L)
  if (is.null(first_page)) {
    log_event("NIH scrape aborted: first page fetch failed.", level = "ERROR")
    return(tibble::tibble())
  }

  total   <- first_page$meta$total %||% 0L
  # Respect both the safety cap and the API's hard offset limit
  usable  <- min(total, max_records, NIH_MAX_OFFSET + NIH_PAGE_SIZE)
  n_pages <- ceiling(usable / NIH_PAGE_SIZE)
  log_event(sprintf("NIH: %d total records, fetching %d across %d pages", total, usable, n_pages))

  if (total == 0L) return(tibble::tibble())

  # Collect parsed results; page 1 is already in hand
  results <- vector("list", n_pages)
  results[[1]] <- parse_nih_page(first_page, page = 1L, n_pages = n_pages)

  if (n_pages > 1L) {
    offsets <- seq(NIH_PAGE_SIZE, (n_pages - 1L) * NIH_PAGE_SIZE, by = NIH_PAGE_SIZE)
    for (i in seq_along(offsets)) {
      if (offsets[[i]] > NIH_MAX_OFFSET) {
        log_event(
          sprintf("NIH: stopping at offset %d (API limit %d)", offsets[[i]], NIH_MAX_OFFSET),
          level = "WARN"
        )
        break
      }
      page_num  <- i + 1L
      page_data <- fetch_nih_page(from_date, to_date, offset = offsets[[i]])
      if (is.null(page_data)) {
        log_event(
          sprintf("NIH: skipping page %d/%d after fetch failure", page_num, n_pages),
          level = "WARN"
        )
        next
      }
      results[[page_num]] <- parse_nih_page(page_data, page = page_num, n_pages = n_pages)
    }
  }

  out <- dplyr::bind_rows(purrr::compact(results))
  if (nrow(out) > max_records) out <- dplyr::slice_head(out, n = max_records)
  out
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

#' Fetch and decode one page from the NIH Reporter API
#'
#' Returns the parsed list on success, or \code{NULL} on any error so the
#' caller can skip the page without aborting the entire scrape.
#' @keywords internal
fetch_nih_page <- function(from_date, to_date, offset) {
  body <- list(
    criteria = list(
      include_active_projects = FALSE,
      exclude_subprojects = TRUE,
      project_end_date = list(from_date = from_date, to_date = to_date)
    ),
    offset     = offset,
    limit      = NIH_PAGE_SIZE,
    sort_field = "project_end_date",
    sort_order = "desc"
  )

  req <- build_request(NIH_API_URL) |>
    httr2::req_method("POST") |>
    httr2::req_body_json(body)

  tryCatch(
    {
      resp <- httr2::req_perform(req)
      httr2::resp_body_json(resp, simplifyVector = FALSE)
    },
    error = function(e) {
      log_event(
        sprintf("NIH fetch failed at offset %d: %s", offset, conditionMessage(e)),
        level = "ERROR"
      )
      NULL
    }
  )
}

# Parse one NIH API response page into the canonical tibble schema.
#' @keywords internal
parse_nih_page <- function(page_data, page, n_pages) {
  results <- page_data$results
  n       <- length(results)

  log_event(sprintf("NIH: fetched page %d/%d, %d records", page, n_pages, n))

  if (n == 0L) return(tibble::tibble())

  # Single-pass extraction: iterate the list once, pull all fields per record.
  institute   <- character(n)
  end_dates   <- character(n)
  added_dates <- character(n)
  appl_ids    <- character(n)
  titles      <- character(n)
  proj_nums   <- character(n)
  org_names   <- character(n)
  org_states  <- character(n)
  amounts     <- double(n)
  active      <- logical(n)

  for (i in seq_len(n)) {
    r <- results[[i]]
    institute[i]   <- extract_ic_abbrev(r)
    end_dates[i]   <- r$project_end_date %||% NA_character_
    added_dates[i] <- r$date_added       %||% NA_character_
    appl_ids[i]    <- as.character(r$appl_id %||% "")
    titles[i]      <- r$project_title    %||% NA_character_
    proj_nums[i]   <- r$project_num      %||% NA_character_
    org_names[i]   <- r$organization$org_name  %||% NA_character_
    org_states[i]  <- r$organization$org_state %||% NA_character_
    amounts[i]     <- r$award_amount     %||% NA_real_
    active[i]      <- r$is_active        %||% NA
  }

  tibble::tibble(
    agency_name      = "NIH",
    institute        = institute,
    notice_date      = parse_date_flexible(end_dates),
    date_added       = parse_date_flexible(added_dates),
    source_url       = sprintf("https://reporter.nih.gov/project-details/%s", appl_ids),
    raw_text_snippet = titles,
    grant_number     = proj_nums,
    org_name         = org_names,
    org_state        = org_states,
    award_amount     = amounts,
    is_active        = active
  )
}

# Extract IC abbreviation from agency_ic_fundings; falls back to ic_name.
extract_ic_abbrev <- function(r) {
  fundings <- r$agency_ic_fundings
  if (length(fundings) > 0L) {
    abbrev <- fundings[[1L]]$abbreviation
    if (!is.null(abbrev) && nchar(abbrev) > 0L) return(as.character(abbrev))
  }
  # Fallback: some records expose ic_name at the top level
  as.character(r$ic_name %||% NA_character_)
}

# %||% is defined in utils.R (canonical location)
