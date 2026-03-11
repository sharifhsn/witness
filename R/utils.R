#' @title Shared Utility Functions
#' @description Common helpers used across scraping and transformation modules.

#' Create a robust HTTP request with rate limiting and retry logic
#'
#' @param url Character. The target URL to request.
#' @param max_retries Integer. Maximum number of retry attempts. Default 3.
#' @param max_seconds Numeric. Maximum backoff wait in seconds. Default 60.
#' @param user_agent Character. User-Agent string for polite scraping.
#' @return An httr2 request object configured with retry and rate limiting.
#' @export
build_request <- function(url,
                          max_retries = 3L,
                          max_seconds = 60,
                          user_agent = "GrantWitness-PoC/0.1 (research)") {
  httr2::request(url) |>
    httr2::req_user_agent(user_agent) |>
    httr2::req_retry(
      max_tries = max_retries,
      max_seconds = max_seconds
    ) |>
    httr2::req_throttle(rate = 1 / 2)
}

#' Safely parse a date string with multiple format fallbacks
#'
#' @param x Character vector of date strings.
#' @param formats Character vector of date format strings to attempt.
#' @return A Date vector. Unparseable values become NA.
#' @export
parse_date_flexible <- function(x, formats = c("%B %d, %Y", "%m/%d/%Y", "%Y-%m-%d")) {
  parsed <- rep(as.Date(NA), length(x))
  for (fmt in formats) {
    missing <- is.na(parsed)
    if (!any(missing)) break
    parsed[missing] <- as.Date(x[missing], format = fmt)
  }
  parsed
}

#' Log a scraping event to the console with a timestamp
#'
#' @param msg Character. Log message.
#' @param level Character. Log level: "INFO", "WARN", "ERROR".
#' @return Invisible NULL. Called for side effect.
#' @export
log_event <- function(msg, level = "INFO") {
  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  message(sprintf("[%s] %s: %s", timestamp, level, msg))
  invisible(NULL)
}

#' Null-coalescing operator (canonical definition for all modules)
#' @export
`%||%` <- function(a, b) if (!is.null(a)) a else b
