#' @title Grant Discrepancy Detection
#' @description Joins forensic termination notices against USAspending official
#'   award records to surface grants where government reporting contradicts
#'   observed termination activity. Designed for the Phase 4 targets pipeline.
#'
#' @note Requires `fuzzyjoin` in addition to the base tidyverse packages.
#'   Add it to the `packages` vector in `_targets.R`.

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #

# Grants with an outlay ratio below this on an active award are flagged as
# potentially frozen — chosen to allow for legitimate slow-spending grants
# while catching near-zero disbursement.
FREEZE_RATIO_THRESHOLD <- 0.10

# Maximum string-distance (Jaro-Winkler) allowed when fuzzy-matching org names.
# Lower = stricter; 0.15 tolerates common abbreviation differences.
FUZZY_ORG_DISTANCE <- 0.15

# Date proximity window for the fuzzy fallback join. Two records are considered
# temporally compatible when their action dates fall within this many days.
FUZZY_DATE_WINDOW_DAYS <- 90L

# --------------------------------------------------------------------------- #
# Public API
# --------------------------------------------------------------------------- #

#' Join notices with awards and flag discrepancies
#'
#' Exact join on grant_number, then fuzzy fallback on org_name + date proximity.
#' Adds: match_method, outlay_ratio, flag_active_despite_terminated,
#' flag_no_recent_activity, flag_not_in_gw, discrepancy_type.
#'
#' @param notices Validated notices tibble. @param awards Validated awards tibble.
#' @return Combined tibble sorted by discrepancy_type, then award_amount desc.
#' @export
join_and_flag <- function(notices, awards) {
  log_event(sprintf(
    "join_and_flag: %d notices, %d awards", nrow(notices), nrow(awards)
  ))

  notices_clean <- .normalise_notices(notices)
  awards_clean  <- .normalise_awards(awards)

  # --- Exact join on grant_number where both sides carry the field ----------
  exact_result  <- .exact_join(notices_clean, awards_clean)
  matched_ids   <- exact_result$award_row_id

  unmatched_notices <- notices_clean |>
    dplyr::filter(!notice_row_id %in% exact_result$notice_row_id)
  unmatched_awards  <- awards_clean |>
    dplyr::filter(!award_row_id %in% matched_ids)

  log_event(sprintf(
    "Exact join: %d matched, %d notices unmatched, %d awards unmatched",
    nrow(exact_result), nrow(unmatched_notices), nrow(unmatched_awards)
  ))

  # --- Fuzzy fallback on org_name + date proximity -------------------------
  fuzzy_result <- .fuzzy_join(unmatched_notices, unmatched_awards)
  fuzzy_ids    <- fuzzy_result$award_row_id

  still_unmatched_awards <- unmatched_awards |>
    dplyr::filter(!award_row_id %in% fuzzy_ids)

  log_event(sprintf(
    "Fuzzy join: %d matched, %d awards remain unmatched",
    nrow(fuzzy_result), nrow(still_unmatched_awards)
  ))

  # --- Unmatched awards: tracked-agency grants absent from forensic data ---
  orphan_awards <- still_unmatched_awards |>
    dplyr::mutate(match_method = "unmatched_award")

  # --- Combine all strata and compute flags --------------------------------
  combined <- dplyr::bind_rows(exact_result, fuzzy_result, orphan_awards) |>
    dplyr::mutate(
      outlay_ratio = .safe_ratio(total_outlays, award_amount),

      flag_active_despite_terminated = .flag_active_despite_terminated(
        terminated = !is.na(notice_date),
        total_outlays  = total_outlays,
        end_date       = end_date
      ),

      flag_no_recent_activity = .flag_no_recent_activity(
        end_date      = end_date,
        outlay_ratio  = outlay_ratio,
        total_outlays = total_outlays
      ),

      flag_not_in_gw = (match_method == "unmatched_award"),

      discrepancy_type = classify_discrepancy(
        flag_active_despite_terminated, flag_no_recent_activity, flag_not_in_gw
      )
    ) |>
    dplyr::select(
      -dplyr::any_of(c("notice_row_id", "award_row_id"))
    ) |>
    dplyr::arrange(discrepancy_type, dplyr::desc(award_amount))

  log_event(sprintf(
    "join_and_flag complete: %d rows, discrepancy breakdown: %s",
    nrow(combined),
    paste(
      names(table(combined$discrepancy_type)),
      table(combined$discrepancy_type),
      sep = "=", collapse = ", "
    )
  ))

  combined
}


#' Classify records into discrepancy categories (vectorized)
#'
#' Precedence: active_despite_terminated > possible_freeze > untracked > normal.
#'
#' @param flag_active_despite_terminated Logical vector.
#' @param flag_no_recent_activity Logical vector.
#' @param flag_not_in_gw Logical vector.
#' @return Character vector of discrepancy types.
#' @export
classify_discrepancy <- function(flag_active_despite_terminated,
                                 flag_no_recent_activity,
                                 flag_not_in_gw) {
  dplyr::case_when(
    flag_active_despite_terminated ~ "active_despite_terminated",
    flag_no_recent_activity        ~ "possible_freeze",
    flag_not_in_gw                 ~ "untracked",
    TRUE                           ~ "normal"
  )
}


#' Agency-level discrepancy rollup (excludes "normal" rows)
#'
#' @param joined_df Tibble from [join_and_flag()].
#' @return Tibble: agency_name, discrepancy_type, n_grants, total_award_amount, total_outlays.
#' @export
summarize_discrepancies <- function(joined_df) {
  joined_df |>
    dplyr::filter(discrepancy_type != "normal") |>
    dplyr::group_by(agency_name, discrepancy_type) |>
    dplyr::summarise(
      n_grants          = dplyr::n(),
      total_award_amount = sum(award_amount, na.rm = TRUE),
      total_outlays      = sum(total_outlays, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::arrange(agency_name, dplyr::desc(total_award_amount))
}

# --------------------------------------------------------------------------- #
# Internal helpers
# --------------------------------------------------------------------------- #

# Add a stable integer row key so join strata can track which rows got matched.
.add_row_id <- function(df, col_name) {
  df |> dplyr::mutate(!!col_name := dplyr::row_number())
}

# Normalise notices: coerce optional columns to the expected types and add key.
.normalise_notices <- function(notices) {
  notices |>
    .add_row_id("notice_row_id") |>
    dplyr::mutate(
      grant_number = if ("grant_number" %in% names(notices))
        .normalise_text(grant_number)
      else
        NA_character_,
      org_name = if ("org_name" %in% names(notices))
        .normalise_text(org_name)
      else
        NA_character_
    )
}

# Normalise awards: coerce optional columns and ensure financial fields exist.
.normalise_awards <- function(awards) {
  awards |>
    .add_row_id("award_row_id") |>
    dplyr::mutate(
      grant_number = if ("grant_number" %in% names(awards))
        .normalise_text(grant_number)
      else
        NA_character_,
      org_name = if ("org_name" %in% names(awards))
        .normalise_text(org_name)
      else if ("recipient_name" %in% names(awards))
        .normalise_text(recipient_name)
      else
        NA_character_,
      total_outlays = if ("total_outlays" %in% names(awards))
        as.numeric(total_outlays)
      else
        NA_real_,
      end_date = if ("end_date" %in% names(awards))
        as.Date(end_date)
      else
        as.Date(NA)
    )
}

# Upper-case and collapse whitespace for case-insensitive matching.
# Used for both grant numbers ("r01 ai123" → "R01 AI123") and org names.
.normalise_text <- function(x) {
  stringr::str_to_upper(stringr::str_squish(x))
}

# Exact join on grant_number. Note: NIH project_num (e.g., "5R01AI012345-10")
# and USAspending Award ID (e.g., "75N92024D00001") use incompatible formats,
# so exact matches are primarily expected for NSF awards. The fuzzy join on
# org_name handles cross-referencing for NIH and other agencies.
.exact_join <- function(notices, awards) {
  # Only attempt the join when both sides have non-NA grant_numbers to match on.
  notices_with_id <- notices |> dplyr::filter(!is.na(grant_number))
  awards_with_id  <- awards  |> dplyr::filter(!is.na(grant_number))

  if (nrow(notices_with_id) == 0 || nrow(awards_with_id) == 0) {
    return(.empty_joined_tibble())
  }

  # Rename shared non-key columns in notices to avoid suffix ambiguity.
  # Award-side values remain canonical (official government data).
  notices_prepped <- .rename_shared_cols(notices_with_id, awards_with_id, "grant_number")

  dplyr::inner_join(
    notices_prepped, awards_with_id,
    by = "grant_number"
  ) |>
    dplyr::mutate(match_method = "exact")
}

# Fuzzy join: Jaro-Winkler distance on org_name, then filter by date proximity.
# fuzzyjoin::stringdist_inner_join is used rather than full_join to avoid
# the O(n^2) blowup — we only want rows where a plausible match exists.
.fuzzy_join <- function(notices, awards) {
  if (nrow(notices) == 0 || nrow(awards) == 0) {
    return(.empty_joined_tibble())
  }

  notices_with_org <- notices |> dplyr::filter(!is.na(org_name))
  awards_with_org  <- awards  |> dplyr::filter(!is.na(org_name))

  if (nrow(notices_with_org) == 0 || nrow(awards_with_org) == 0) {
    return(.empty_joined_tibble())
  }

  # Rename shared non-key columns in notices before fuzzy join.
  notices_prepped <- .rename_shared_cols(notices_with_org, awards_with_org, "org_name")

  fuzzyjoin::stringdist_inner_join(
    notices_prepped, awards_with_org,
    by         = "org_name",
    method     = "jw",            # Jaro-Winkler handles abbreviations well
    max_dist   = FUZZY_ORG_DISTANCE,
    distance_col = "org_name_dist"
  ) |>
    # fuzzyjoin creates org_name.x (notice) and org_name.y (award) for the join key.
    # Canonicalize to award-side org_name.
    dplyr::rename(org_name_notice = org_name.x, org_name = org_name.y) |>
    # Secondary filter: action_date on the award must be within the window of
    # the notice_date, ensuring we're comparing contemporaneous records.
    dplyr::filter(
      !is.na(notice_date),
      !is.na(action_date),
      abs(as.integer(action_date - notice_date)) <= FUZZY_DATE_WINDOW_DAYS
    ) |>
    # When a notice fuzzy-matches multiple awards, keep the closest org name.
    dplyr::group_by(notice_row_id, award_row_id) |>
    dplyr::slice_min(org_name_dist, n = 1L, with_ties = FALSE) |>
    dplyr::ungroup() |>
    dplyr::select(-org_name_dist) |>
    dplyr::mutate(match_method = "fuzzy")
}

# Rename columns in `left` that also exist in `right` (excluding the join key)
# by appending "_notice". This prevents suffix ambiguity in the join result,
# so that award-side columns (official government data) keep their canonical names.
.rename_shared_cols <- function(left, right, join_key) {
  shared <- setdiff(intersect(names(left), names(right)), join_key)
  if (length(shared) == 0L) return(left)
  rename_vec <- stats::setNames(shared, paste0(shared, "_notice"))
  dplyr::rename(left, !!!rename_vec)
}

# Zero-row tibble preserving the row-id columns that join_and_flag accesses
# via `$award_row_id` / `$notice_row_id`. bind_rows downstream fills all
# other columns with NA — safe because zero rows contribute no data.
.empty_joined_tibble <- function() {
  dplyr::tibble(
    match_method   = character(0),
    notice_row_id  = integer(0),
    award_row_id   = integer(0)
  )
}

# Vectorised ratio with protection against division by zero and NA inputs.
.safe_ratio <- function(numerator, denominator) {
  dplyr::if_else(
    !is.na(denominator) & denominator > 0,
    as.numeric(numerator) / denominator,
    NA_real_
  )
}

# TRUE when the grant has a live notice AND USAspending still shows money flowing.
.flag_active_despite_terminated <- function(terminated, total_outlays, end_date) {
  today <- Sys.Date()
  terminated &
    !is.na(total_outlays) & total_outlays > 0 &
    !is.na(end_date)      & end_date > today
}

# TRUE when the award period is open but outlays are absent or far below the
# expected burn rate (below FREEZE_RATIO_THRESHOLD of the total award amount).
.flag_no_recent_activity <- function(end_date, outlay_ratio, total_outlays) {
  today <- Sys.Date()
  award_is_active <- !is.na(end_date) & end_date > today
  no_outlays      <- is.na(total_outlays) | total_outlays == 0
  low_outlays     <- !is.na(outlay_ratio) & outlay_ratio < FREEZE_RATIO_THRESHOLD

  award_is_active & (no_outlays | low_outlays)
}
