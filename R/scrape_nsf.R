#' @title NSF Terminated Awards Scraper
#' @description Downloads and parses the NSF Terminated Awards CSV published at
#'   \url{https://nsf-gov-resources.nsf.gov/files/NSF-Terminated-Awards.csv}.
#'   Returns a tibble conforming to the canonical grant-notice schema used
#'   across this pipeline.
#'
#' @details The source CSV has two quirks:
#'   \enumerate{
#'     \item A trailing comma in every row that generates a phantom empty column.
#'     \item The header row encodes a "Date of export" metadata value in what
#'           would otherwise be the 7th column position—it is not a data column.
#'   }
#'   Both are handled transparently by \code{scrape_nsf()}.

# ---------------------------------------------------------------------------
# Dependencies (declared here for readability; loaded by targets pipeline)
# ---------------------------------------------------------------------------
# httr2, readr, dplyr, stringr

NSF_CSV_URL <- "https://nsf-gov-resources.nsf.gov/files/NSF-Terminated-Awards.csv"

# Canonical column names emitted by readr after we supply col_names manually.
# The raw header is:
#   Award ID,Directorate,Recipient,Title,Obligated,,Date of export
# Column 6 is the phantom trailing-comma column; column 7 is export metadata.
.NSF_RAW_COLS <- c(
  "award_id",
  "directorate",
  "recipient",
  "title",
  "obligated",
  ".phantom",   # trailing-comma artefact — dropped after parse
  ".meta"       # "Date of export: MM/DD/YYYY" value lives here — extracted then dropped
)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

#' Parse NSF "Obligated" currency strings to numeric
#'
#' Strips dollar signs, commas, surrounding quotes, and whitespace before
#' coercing to \code{double}.  Returns \code{NA_real_} for values that
#' cannot be converted (e.g. blank cells, non-numeric text).
#'
#' @param x Character vector of raw obligated-amount strings.
#' @return Numeric vector of the same length as \code{x}.
#' @export
#' @examples
#' parse_nsf_obligated(c('$44,434,393 ', '"$1,200"', '', 'N/A'))
#' #> [1] 44434393  1200     NA    NA
parse_nsf_obligated <- function(x) {
  cleaned <- x |>
    stringr::str_remove_all('[\\$,"]') |>
    stringr::str_trim()

  result <- suppressWarnings(as.numeric(cleaned))

  # Warn about values that looked non-empty but failed conversion.
  bad <- !is.na(x) & nchar(stringr::str_trim(x)) > 0 & is.na(result)
  if (any(bad)) {
    log_event(
      sprintf(
        "parse_nsf_obligated: %d value(s) could not be coerced to numeric: %s",
        sum(bad),
        paste(unique(x[bad]), collapse = ", ")
      ),
      level = "WARN"
    )
  }

  result
}


#' Scrape NSF Terminated Awards
#'
#' Downloads the NSF Terminated Awards CSV, handles its non-standard header,
#' cleans currency values, and returns a tibble conforming to the canonical
#' grant-notice schema.
#'
#' An attribute \code{"export_date"} is attached to the returned tibble
#' containing the "Date of export" value parsed from the CSV header row.
#'
#' @return A tibble with columns:
#'   \describe{
#'     \item{agency_name}{Always \code{"NSF"}.}
#'     \item{directorate}{Funding directorate, trimmed.}
#'     \item{notice_date}{\code{as.Date(NA)} — the CSV does not include
#'       individual termination dates.}
#'     \item{source_url}{NSF Award Search permalink for the award.}
#'     \item{raw_text_snippet}{Award title.}
#'     \item{grant_number}{NSF award ID.}
#'     \item{org_name}{Recipient organisation name.}
#'     \item{award_amount}{Obligated amount as \code{double}; \code{NA} when
#'       malformed or absent.}
#'   }
#' @export
scrape_nsf <- function() {
  # ------------------------------------------------------------------
  # 1. Download
  # ------------------------------------------------------------------
  log_event(sprintf("Downloading NSF Terminated Awards CSV: %s", NSF_CSV_URL))

  resp <- tryCatch(
    build_request(NSF_CSV_URL) |> httr2::req_perform(),
    error = function(e) {
      log_event(
        sprintf("NSF CSV download failed: %s", conditionMessage(e)),
        level = "ERROR"
      )
      return(NULL)
    }
  )

  if (is.null(resp)) {
    log_event("NSF scrape aborted: download failed.", level = "ERROR")
    return(tibble::tibble(
      agency_name = character(), directorate = character(),
      notice_date = as.Date(character()), source_url = character(),
      raw_text_snippet = character(), grant_number = character(),
      org_name = character(), award_amount = numeric()
    ))
  }

  raw_bytes <- httr2::resp_body_raw(resp)
  # Ensure valid UTF-8 (the CSV sometimes contains Latin-1 characters)
  raw_bytes <- charToRaw(iconv(rawToChar(raw_bytes), from = "latin1", to = "UTF-8", sub = ""))
  log_event(sprintf("Downloaded %.1f KB", length(raw_bytes) / 1024))

  # ------------------------------------------------------------------
  # 2. Parse — skip the real header row; supply canonical names instead
  # ------------------------------------------------------------------
  # We skip row 1 (the original header) and assign our own col_names so
  # that the "Date of export" metadata value in column 7 of that header
  # row is never mistaken for a column name.
  raw <- readr::read_csv(
    I(raw_bytes),           # treat byte vector as the file content
    col_names  = .NSF_RAW_COLS,
    skip       = 1L,        # discard the original header row
    col_types  = readr::cols(.default = readr::col_character()),
    na         = c("", "NA"),
    trim_ws    = FALSE,     # we trim manually for visibility
    show_col_types = FALSE
  )

  log_event(sprintf("Parsed %d raw rows", nrow(raw)))

  # ------------------------------------------------------------------
  # 3. Extract export-date metadata from the .meta column
  # ------------------------------------------------------------------
  # The original header row (now skipped) contained something like:
  #   ...,,"Date of export: 03/07/2025"
  # readr places the *data* rows' .meta values here (all NA for data rows).
  # The metadata itself was in the header row we skipped, so we recover it
  # from the raw bytes via a targeted regex on the first line.
  # Only decode the first line (avoid rawToChar on the entire CSV)
  first_newline <- which(raw_bytes == charToRaw("\n"))[1L]
  first_line <- rawToChar(raw_bytes[seq_len(first_newline %||% min(500L, length(raw_bytes)))])
  export_date_raw <- stringr::str_extract(
    first_line,
    "Date of export[:\\s]+([0-9/]+)",
    group = 1
  )
  export_date <- tryCatch(
    as.Date(export_date_raw, format = "%m/%d/%Y"),
    error = function(e) as.Date(NA)
  )

  if (!is.na(export_date)) {
    log_event(sprintf("CSV export date: %s", export_date))
  } else {
    log_event("Could not parse export date from CSV header", level = "WARN")
  }

  # ------------------------------------------------------------------
  # 4. Clean and reshape to canonical schema
  # ------------------------------------------------------------------
  result <- raw |>
    dplyr::select(-".phantom", -".meta") |>
    dplyr::filter(!dplyr::if_all(dplyr::everything(), is.na)) |>
    dplyr::transmute(
      agency_name      = "NSF",
      directorate      = stringr::str_trim(directorate),
      notice_date      = as.Date(NA),
      source_url       = paste0(
        "https://www.nsf.gov/awardsearch/showAward?AWD_ID=",
        stringr::str_trim(award_id)
      ),
      raw_text_snippet = stringr::str_trim(title),
      grant_number     = stringr::str_trim(award_id),
      org_name         = stringr::str_trim(recipient),
      award_amount     = parse_nsf_obligated(obligated)
    )

  log_event(sprintf(
    "scrape_nsf() complete: %d records, %d with award_amount",
    nrow(result),
    sum(!is.na(result$award_amount))
  ))

  attr(result, "export_date") <- export_date
  result
}
