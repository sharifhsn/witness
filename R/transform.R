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

# Discrepancy types that indicate an active disruption (freeze or unlawful continuation).
# Shared by File C analysis, subaward impact targeting, and emergency fund flagging.
FREEZE_RELATED_DISCREPANCY_TYPES <- c(
  "possible_freeze", "possible_freeze_no_data", "active_despite_terminated"
)

# DEFC codes that represent COVID-19 or American Rescue Plan emergency appropriations.
# These are congressionally mandated emergency funds — finding them on a frozen grant
# is a stronger political-targeting signal than routine infrastructure funding.
#
# Excluded intentionally:
#   Q (P.L. 117-58 IIJA) — present on ~82% of awards in our dataset; too ubiquitous
#                           to be a useful targeting signal.
#   V, U, AAB, AAK       — not yet confirmed as COVID/ARP codes; present on <1.5% each.
#
# Sources: USAspending DEFC reference table (api.usaspending.gov/api/v2/references/def_codes/)
EMERGENCY_DEFC_CODES <- c(
  # COVID-19 supplemental acts
  "Z",  # P.L. 116-127 — Families First Coronavirus Response Act
  "L",  # P.L. 116-136 — CARES Act
  "M",  # P.L. 116-260 — Consolidated Appropriations Act 2021 (COVID)
  "3",  # P.L. 116-123 — Coronavirus Preparedness and Response Supplemental
  "4",  # P.L. 116-136 — CARES Act (additional)
  "5",  # P.L. 116-139 — PPP and Health Care Enhancement Act
  "6",  # P.L. 116-260 — Consolidated Appropriations Act 2021 (additional)
  "7",  # P.L. 116-260 — emergency supplement
  # American Rescue Plan
  "N"   # P.L. 117-2  — American Rescue Plan Act
)

# Maximum string-distance (Jaro-Winkler) allowed when fuzzy-matching org names.
# Tightened from 0.15 to 0.08 after audit showed 71% false positive rate at 0.10-0.15
# (e.g. "UNIVERSITY OF CHICAGO" matching "UNIVERSITY OF UTAH"). At 0.08, matches like
# abbreviation differences and minor typos still pass, but shared-prefix false positives don't.
FUZZY_ORG_DISTANCE <- 0.08

# Date proximity window for the fuzzy fallback join. Two records are considered
# temporally compatible when their action dates fall within this many days.
FUZZY_DATE_WINDOW_DAYS <- 90L

# Maximum fuzzy matches per notice. Large research universities (UCLA, JHU)
# match hundreds of USAspending awards by org name alone. Capping prevents
# fan-out blowup while keeping the best matches per notice.
FUZZY_MAX_MATCHES_PER_NOTICE <- 5L

# Awards above this threshold are umbrella/entitlement contracts (e.g. Medicaid)
# that distort aggregate dollar statistics. Flagged, not filtered.
UMBRELLA_AWARD_THRESHOLD <- 1e9

# HHS sub-agencies whose awards are formula/entitlement grants rather than
# individual research awards. These spend down slowly for structural reasons
# (block grant drawdowns, quarterly reimbursements) unrelated to political freezes.
# Excluding them from possible_freeze prevents Medicaid/TANF/ACF grants from
# polluting the freeze signal — confirmed by calibration QA (DQ-20, 2026-03-15):
# 198/201 of our HHS possible_freeze grants were from these sub-agencies.
NON_RESEARCH_HHS_SUBAGENCIES <- c(
  "Administration for Children and Families",
  "Centers for Medicare and Medicaid Services",
  "Health Resources and Services Administration",
  "Substance Abuse and Mental Health Services Administration",
  "Administration for Community Living",
  "Administration for Strategic Preparedness and Response"
)

# 2 CFR §200.344: administrative closeout window after termination. Outlays
# within this window are expected routine activity; outlays beyond it are
# anomalous and warrant flagging as confirmed post-termination spending.
POST_TERMINATION_CLOSEOUT_DAYS <- 120L

# Minimum outlay ($) to count as evidence of post-termination spending.
# Filters out rounding artifacts and small accounting adjustments.
POST_TERMINATION_MIN_OUTLAY <- 100

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
  combined_raw <- dplyr::bind_rows(exact_result, fuzzy_result, orphan_awards)

  # Ensure award_amount_notice exists even when no exact/fuzzy matches occurred
  # (bind_rows only creates the column when at least one stratum has it)
  if (!"award_amount_notice" %in% names(combined_raw)) {
    combined_raw$award_amount_notice <- NA_real_
  }

  combined <- combined_raw |>
    dplyr::mutate(
      outlay_ratio = .safe_ratio(total_outlays, award_amount),

      # Fraction of award period elapsed as of today, clamped to [0, 1].
      # NA when dates are missing or inverted. Used to prioritise possible_freeze:
      # a grant at 0.90 elapsed with 5% outlay is far more alarming than one at 0.02.
      elapsed_ratio = dplyr::if_else(
        !is.na(action_date) & !is.na(end_date) & end_date > action_date,
        pmin(pmax(as.numeric(Sys.Date() - action_date) /
                    as.numeric(end_date - action_date), 0), 1),
        NA_real_
      ),

      # Amount discrepancy between forensic notice and official USAspending record.
      # Only meaningful for exact matches (same grant_number in both sources).
      # For fuzzy matches, amounts are expected to differ as they come from different grants.
      # A >25% gap in an exact match may indicate: different performance periods,
      # mid-project modifications, or data entry errors in one source.
      flag_amount_mismatch = match_method == "exact" &
        !is.na(award_amount_notice) & !is.na(award_amount) &
        award_amount > 0 &
        abs(award_amount_notice / award_amount - 1) > 0.25,

      # Umbrella/entitlement flag — Medicaid etc. that distort dollar aggregates
      flag_umbrella_award = !is.na(award_amount) & award_amount > UMBRELLA_AWARD_THRESHOLD,

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

      # Distinguish confirmed low outlays from missing outlay data
      flag_missing_outlay_data = flag_no_recent_activity & is.na(total_outlays),

      flag_not_in_gw = (match_method == "unmatched_award"),

      discrepancy_type = classify_discrepancy(
        flag_active_despite_terminated, flag_no_recent_activity,
        flag_missing_outlay_data, flag_not_in_gw,
        sub_agency = sub_agency
      )
    ) |>
    dplyr::select(
      -dplyr::any_of(c("notice_row_id", "award_row_id"))
    ) |>
    dplyr::arrange(discrepancy_type, dplyr::desc(award_amount))

  n_amount_mismatch <- sum(combined$flag_amount_mismatch, na.rm = TRUE)
  if (n_amount_mismatch > 0) {
    log_event(sprintf(
      "join_and_flag: %d matched grants have >25%% amount discrepancy between sources",
      n_amount_mismatch
    ), "WARN")
  }

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
#' Precedence: active_despite_terminated > possible_freeze > possible_freeze_no_data > untracked > normal.
#'
#' @param flag_active_despite_terminated Logical vector.
#' @param flag_no_recent_activity Logical vector.
#' @param flag_missing_outlay_data Logical vector. TRUE when freeze flag is based on NA outlays, not confirmed low outlays.
#' @param flag_not_in_gw Logical vector.
#' @param sub_agency Character vector. Sub-agency name from USAspending; used to
#'   exclude formula/entitlement HHS programmes (Medicaid, TANF, ACF block grants)
#'   from the freeze pool — see [NON_RESEARCH_HHS_SUBAGENCIES].
#' @return Character vector of discrepancy types.
#' @export
classify_discrepancy <- function(flag_active_despite_terminated,
                                 flag_no_recent_activity,
                                 flag_missing_outlay_data,
                                 flag_not_in_gw,
                                 sub_agency = NA_character_) {
  # Formula/entitlement HHS sub-agencies spend down slowly for structural reasons;
  # dispatch them to "normal" early so freeze arms need no negation guards.
  flag_non_research <- !is.na(sub_agency) & sub_agency %in% NON_RESEARCH_HHS_SUBAGENCIES

  dplyr::case_when(
    flag_active_despite_terminated   ~ "active_despite_terminated",
    flag_non_research                ~ "normal",
    flag_no_recent_activity & !flag_missing_outlay_data ~ "possible_freeze",
    flag_no_recent_activity & flag_missing_outlay_data  ~ "possible_freeze_no_data",
    flag_not_in_gw                   ~ "untracked",
    TRUE                             ~ "normal"
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
        .normalise_org(org_name)
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
        .normalise_org(org_name)
      else if ("recipient_name" %in% names(awards))
        .normalise_org(recipient_name)
      else
        NA_character_,
      total_outlays = if ("total_outlays" %in% names(awards))
        as.numeric(total_outlays)
      else
        NA_real_,
      end_date = if ("end_date" %in% names(awards))
        as.Date(end_date)
      else
        as.Date(NA),
      sub_agency = if ("sub_agency" %in% names(awards))
        as.character(sub_agency)
      else
        NA_character_
    )
}

# Upper-case and collapse whitespace for case-insensitive matching.
# Used for both grant numbers ("r01 ai123" → "R01 AI123") and org names.
.normalise_text <- function(x) {
  stringr::str_to_upper(stringr::str_squish(x))
}

# Aggressive org name normalizer for fuzzy join pre-processing.
# Strips suffixes, campuses, hyphens, and punctuation that cause
# identical institutions to mismatch (e.g. "CARNEGIE-MELLON UNIVERSITY"
# vs "CARNEGIE MELLON UNIVERSITY", "ARIZONA STATE UNIVERSITY-TEMPE CAMPUS"
# vs "ARIZONA STATE UNIVERSITY").
.normalise_org <- function(x) {
  x <- stringr::str_to_upper(stringr::str_squish(x))
  # Strip parenthetical campus/location qualifiers
  x <- gsub("\\s*\\([^)]*\\)", "", x)
  # Normalize hyphens to spaces (before suffix stripping)
  x <- gsub("-", " ", x)
  # Strip "AT <CITY>" suffix after org name
  x <- gsub("\\s+AT\\s+[A-Z].*$", "", x)
  # Strip campus/location suffixes (e.g. "TEMPE CAMPUS", "MAIN CAMPUS")
  x <- gsub("\\s+[A-Z]+\\s+CAMPUS$", "", x)
  # Strip trailing legal suffixes
  x <- gsub(",?\\s*(THE|INC\\.?|LLC\\.?|CORP\\.?|LTD\\.?|CO\\.?)\\s*$", "", x)
  # Strip leading "THE "
  x <- gsub("^THE\\s+", "", x)
  # Strip departmental qualifiers after main org name
  x <- gsub("\\s+(HEALTH SCIENCES|MEDICAL CAMPUS|MEDICAL CENTER|TEACHERS COLLEGE|SCHOOL OF MEDICINE)$", "", x)
  # Remove remaining punctuation (except spaces)
  x <- gsub("[.,;:'\"!]", "", x)
  stringr::str_squish(x)
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
    # Token overlap filter: require at least one shared distinctive word.
    # Prevents "UNIVERSITY OF X" matching "UNIVERSITY OF Y" when JW is fooled
    # by long shared prefixes.
    dplyr::filter(.share_distinctive_token(org_name_notice, org_name)) |>
    # Secondary filter: action_date on the award must be within the window of
    # the notice_date, ensuring we're comparing contemporaneous records.
    dplyr::filter(
      !is.na(notice_date),
      !is.na(action_date),
      abs(as.integer(action_date - notice_date)) <= FUZZY_DATE_WINDOW_DAYS
    ) |>
    # Deduplicate: one row per (notice, award) pair, keeping closest org name.
    dplyr::group_by(notice_row_id, award_row_id) |>
    dplyr::slice_min(org_name_dist, n = 1L, with_ties = FALSE) |>
    dplyr::ungroup() |>
    # Cap fan-out: per notice, keep only the N closest-matching awards.
    # Prevents large research universities from generating hundreds of matches.
    dplyr::group_by(notice_row_id) |>
    dplyr::slice_min(org_name_dist, n = FUZZY_MAX_MATCHES_PER_NOTICE, with_ties = FALSE) |>
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

# Stopwords that don't differentiate org names — shared by most universities,
# hospitals, and research institutions. Used by .share_distinctive_token().
.ORG_STOPWORDS <- c(
  "UNIVERSITY", "OF", "THE", "COLLEGE", "INSTITUTE", "SCHOOL", "CENTER",
  "MEDICAL", "RESEARCH", "HEALTH", "STATE", "NATIONAL", "DEPARTMENT",
  "FOUNDATION", "HOSPITAL", "SCIENCES", "SCIENCE", "COMMUNITY", "SYSTEM",
  "AND", "FOR", "AT", "IN"
)

# Vectorised check: do two org name vectors share at least one distinctive token?
# Returns TRUE when any word that appears in both names is NOT a stopword.
# This catches false positives like "UNIVERSITY OF CHICAGO" ~ "UNIVERSITY OF UTAH"
# where JW distance is low due to shared prefix but no distinctive word overlaps.
.share_distinctive_token <- function(a, b) {
  vapply(seq_along(a), function(i) {
    tokens_a <- setdiff(strsplit(a[i], "\\s+")[[1]], .ORG_STOPWORDS)
    tokens_b <- setdiff(strsplit(b[i], "\\s+")[[1]], .ORG_STOPWORDS)
    length(intersect(tokens_a, tokens_b)) > 0
  }, logical(1))
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


# --------------------------------------------------------------------------- #
# Transaction-level enrichment
# --------------------------------------------------------------------------- #

# Thresholds for freeze confidence based on days since last transaction
FREEZE_HIGH_DAYS   <- 180L
FREEZE_MEDIUM_DAYS <- 90L

#' Enrich discrepancies with transaction-level freeze confidence
#'
#' Joins transaction data onto discrepancies to compute the actual last
#' disbursement date for each grant, enabling a more precise freeze heuristic
#' than the aggregate outlay ratio alone.
#'
#' @param discrepancies Tibble from [join_and_flag()].
#' @param transactions Tibble from [fetch_transactions()].
#' @return Discrepancies tibble with added columns: last_transaction_date,
#'   days_since_last_transaction, freeze_confidence.
#' @export
enrich_with_transactions <- function(discrepancies, transactions) {
  if (nrow(transactions) == 0L) {
    log_event("enrich_with_transactions: no transactions to join", "WARN")
    return(discrepancies |>
      dplyr::mutate(
        last_transaction_date      = as.Date(NA),
        days_since_last_transaction = NA_integer_,
        freeze_confidence          = NA_character_
      ))
  }

  # Compute per-grant transaction summary
  txn_summary <- transactions |>
    dplyr::filter(!is.na(transaction_date)) |>
    dplyr::group_by(grant_number) |>
    dplyr::summarise(
      last_transaction_date = max(transaction_date, na.rm = TRUE),
      n_transactions        = dplyr::n(),
      total_obligated        = sum(obligation_amount, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      days_since_last_transaction = as.integer(Sys.Date() - last_transaction_date),
      freeze_confidence = dplyr::case_when(
        days_since_last_transaction > FREEZE_HIGH_DAYS   ~ "high",
        days_since_last_transaction > FREEZE_MEDIUM_DAYS ~ "medium",
        TRUE                                              ~ "low"
      )
    )

  log_event(sprintf(
    "Transaction summary: %d grants, freeze confidence: high=%d, medium=%d, low=%d",
    nrow(txn_summary),
    sum(txn_summary$freeze_confidence == "high", na.rm = TRUE),
    sum(txn_summary$freeze_confidence == "medium", na.rm = TRUE),
    sum(txn_summary$freeze_confidence == "low", na.rm = TRUE)
  ))

  result <- discrepancies |>
    dplyr::left_join(
      txn_summary |> dplyr::select(
        grant_number, last_transaction_date,
        days_since_last_transaction, freeze_confidence
      ),
      by = "grant_number"
    )

  log_event(sprintf(
    "enrich_with_transactions: %d/%d discrepancies matched to transactions",
    sum(!is.na(result$last_transaction_date)), nrow(result)
  ))

  result
}

# --------------------------------------------------------------------------- #
# De-obligation detection
# --------------------------------------------------------------------------- #

# Minimum absolute de-obligation amount to flag (ignore tiny accounting adjustments)
DEOBLIGATION_MIN_AMOUNT <- 1000

# Minimum number of de-obligation events per grant to flag as anomalous
DEOBLIGATION_MIN_EVENTS <- 2L

#' Detect de-obligation events from transaction data
#'
#' Identifies grants where money is being pulled back (negative obligations).
#' A spike in de-obligations is an early signal of programmatic rescission —
#' fund clawbacks happen before outlays drop to $0, so this fires earlier
#' than freeze detection.
#'
#' Grant Witness tracks outlays dropping to zero but does not surface
#' de-obligation patterns as a distinct signal.
#'
#' @param transactions Tibble from [fetch_transactions()].
#' @param min_amount Numeric. Minimum absolute de-obligation to flag.
#' @param min_events Integer. Minimum de-obligation events per grant to flag.
#' @return Tibble with per-grant de-obligation summary.
#' @export
detect_deobligations <- function(transactions,
                                  min_amount = DEOBLIGATION_MIN_AMOUNT,
                                  min_events = DEOBLIGATION_MIN_EVENTS) {
  if (nrow(transactions) == 0L) {
    log_event("detect_deobligations: no transactions", "WARN")
    return(dplyr::tibble(
      grant_number = character(0),
      n_deobligations = integer(0),
      total_deobligated = numeric(0),
      first_deobligation_date = as.Date(character(0)),
      last_deobligation_date = as.Date(character(0)),
      deobligation_flag = logical(0)
    ))
  }

  # De-obligations are negative obligation_amount values
  deobs <- transactions |>
    dplyr::filter(
      !is.na(obligation_amount),
      obligation_amount < -min_amount
    )

  if (nrow(deobs) == 0L) {
    log_event("detect_deobligations: no de-obligation events found")
    return(dplyr::tibble(
      grant_number = character(0),
      n_deobligations = integer(0),
      total_deobligated = numeric(0),
      first_deobligation_date = as.Date(character(0)),
      last_deobligation_date = as.Date(character(0)),
      deobligation_flag = logical(0)
    ))
  }

  summary <- deobs |>
    dplyr::group_by(grant_number) |>
    dplyr::summarise(
      n_deobligations         = dplyr::n(),
      total_deobligated       = sum(obligation_amount, na.rm = TRUE),  # negative
      first_deobligation_date = min(transaction_date, na.rm = TRUE),
      last_deobligation_date  = max(transaction_date, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      deobligation_flag = n_deobligations >= min_events
    ) |>
    dplyr::arrange(total_deobligated)  # most negative first

  n_flagged <- sum(summary$deobligation_flag)

  log_event(sprintf(
    "De-obligation detection: %d grants with de-obligations, %d flagged (>=%d events), $%.0f total clawed back",
    nrow(summary), n_flagged, min_events,
    abs(sum(summary$total_deobligated))
  ))

  summary
}

#' Detect agency-level de-obligation spikes
#'
#' Aggregates de-obligations by agency and month to identify programmatic
#' rescission patterns. A sudden spike in de-obligations across multiple
#' awards at one agency suggests a coordinated fund clawback.
#'
#' @param transactions Tibble from [fetch_transactions()].
#' @param discrepancies Tibble from [join_and_flag()] (for agency_name lookup).
#' @return Tibble with monthly de-obligation aggregates by agency.
#' @export
detect_deobligation_spikes <- function(transactions, discrepancies) {
  if (nrow(transactions) == 0L) {
    return(dplyr::tibble())
  }

  # Get agency_name for each grant
  agency_lookup <- discrepancies |>
    dplyr::select(grant_number, agency_name) |>
    dplyr::distinct()

  deobs <- transactions |>
    dplyr::filter(!is.na(obligation_amount), obligation_amount < 0) |>
    dplyr::left_join(agency_lookup, by = "grant_number") |>
    dplyr::filter(!is.na(agency_name), !is.na(transaction_date)) |>
    dplyr::mutate(
      year_month = format(transaction_date, "%Y-%m")
    )

  if (nrow(deobs) == 0L) return(dplyr::tibble())

  monthly <- deobs |>
    dplyr::group_by(agency_name, year_month) |>
    dplyr::summarise(
      n_deobligations    = dplyr::n(),
      n_grants_affected  = dplyr::n_distinct(grant_number),
      total_deobligated  = sum(obligation_amount, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::arrange(agency_name, year_month)

  # Flag months with anomalously high de-obligation activity
  # (>2x the agency's median monthly de-obligation count)
  monthly <- monthly |>
    dplyr::group_by(agency_name) |>
    dplyr::mutate(
      median_monthly = stats::median(n_deobligations),
      spike_flag = n_deobligations > 2 * median_monthly & n_grants_affected >= 3L
    ) |>
    dplyr::ungroup()

  n_spikes <- sum(monthly$spike_flag)
  if (n_spikes > 0L) {
    log_event(sprintf(
      "De-obligation spikes detected: %d agency-months with anomalous clawback activity",
      n_spikes
    ), "WARN")
  }

  monthly
}

# --------------------------------------------------------------------------- #
# Subaward analysis
# --------------------------------------------------------------------------- #

#' Analyze subaward flow relative to frozen/terminated grants
#'
#' Joins subaward data against discrepancies to identify:
#' 1. Grants flagged as frozen where subaward money is still flowing (workaround)
#' 2. Subawardees receiving money from terminated prime awards
#' 3. Institutions hit by downstream freeze effects
#'
#' @param subawards Tibble from [fetch_subawards()].
#' @param discrepancies Tibble from [join_and_flag()] or [enrich_with_transactions()].
#' @return List with analysis results.
#' @export
analyze_subaward_flow <- function(subawards, discrepancies) {
  if (nrow(subawards) == 0L) {
    log_event("analyze_subaward_flow: no subaward data", "WARN")
    return(list(
      n_subawards = 0L,
      frozen_with_subawards = dplyr::tibble(),
      terminated_with_subawards = dplyr::tibble(),
      downstream_institutions = dplyr::tibble()
    ))
  }

  # Join subawards to discrepancies on prime_award_id = grant_number
  joined <- subawards |>
    dplyr::inner_join(
      discrepancies |> dplyr::select(grant_number, discrepancy_type, outlay_ratio,
                                      freeze_confidence, award_amount),
      by = c("prime_award_id" = "grant_number")
    )

  log_event(sprintf(
    "Subaward analysis: %d subawards matched to %d discrepancy grants",
    nrow(joined), dplyr::n_distinct(joined$prime_award_id)
  ))

  # Frozen grants still flowing money to subawardees
  frozen_with_subs <- joined |>
    dplyr::filter(discrepancy_type %in% c("possible_freeze", "possible_freeze_no_data")) |>
    dplyr::group_by(prime_award_id, prime_recipient) |>
    dplyr::summarise(
      n_subawards           = dplyr::n(),
      total_subaward_amount = sum(subaward_amount, na.rm = TRUE),
      subawardees           = paste(unique(subawardee_name), collapse = "; "),
      latest_subaward_date  = if (all(is.na(subaward_date))) as.Date(NA) else max(subaward_date, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::arrange(dplyr::desc(total_subaward_amount))

  # Terminated grants with active subawards
  terminated_with_subs <- joined |>
    dplyr::filter(discrepancy_type == "active_despite_terminated") |>
    dplyr::group_by(prime_award_id, prime_recipient) |>
    dplyr::summarise(
      n_subawards           = dplyr::n(),
      total_subaward_amount = sum(subaward_amount, na.rm = TRUE),
      subawardees           = paste(unique(subawardee_name), collapse = "; "),
      latest_subaward_date  = if (all(is.na(subaward_date))) as.Date(NA) else max(subaward_date, na.rm = TRUE),
      .groups = "drop"
    )

  # Downstream institutions affected — subawardees receiving money from
  # problematic prime awards
  downstream <- joined |>
    dplyr::filter(discrepancy_type != "normal") |>
    dplyr::group_by(subawardee_name) |>
    dplyr::summarise(
      n_prime_awards         = dplyr::n_distinct(prime_award_id),
      total_subaward_amount  = sum(subaward_amount, na.rm = TRUE),
      discrepancy_types      = paste(unique(discrepancy_type), collapse = ", "),
      prime_institutions     = paste(unique(prime_recipient), collapse = "; "),
      .groups = "drop"
    ) |>
    dplyr::arrange(dplyr::desc(n_prime_awards))

  if (nrow(frozen_with_subs) > 0L) {
    log_event(sprintf(
      "Subaward anomaly: %d frozen grants still have %d subawards worth $%.0f",
      nrow(frozen_with_subs),
      sum(frozen_with_subs$n_subawards),
      sum(frozen_with_subs$total_subaward_amount)
    ), "WARN")
  }

  if (nrow(terminated_with_subs) > 0L) {
    log_event(sprintf(
      "Subaward anomaly: %d terminated grants have %d subawards",
      nrow(terminated_with_subs),
      sum(terminated_with_subs$n_subawards)
    ), "WARN")
  }

  log_event(sprintf(
    "Downstream impact: %d institutions receive subawards from problematic grants",
    nrow(downstream)
  ))

  list(
    n_subawards               = nrow(subawards),
    n_matched                 = nrow(joined),
    frozen_with_subawards     = frozen_with_subs,
    terminated_with_subawards = terminated_with_subs,
    downstream_institutions   = downstream
  )
}

# --------------------------------------------------------------------------- #
# File C temporal reconstruction
# --------------------------------------------------------------------------- #

# Thresholds for freeze_evidence classification
FILE_C_CONFIRMED_ZERO_MONTHS <- 3L
FILE_C_CONFIRMED_GAP_DAYS    <- 180L
FILE_C_LIKELY_ZERO_MONTHS    <- 1L
FILE_C_LIKELY_GAP_DAYS       <- 90L

#' Build institution targeting date lookup from GW ground truth
#'
#' Aggregates GW per-grant targeting dates to institution level, producing
#' the start/end of targeting per organization. Used by
#' `compute_file_c_features()` for temporal reconstruction.
#'
#' @param gw_nih_data Tibble from [fetch_gw_nih()].
#' @return Tibble with columns: org_name, targeting_start, targeting_end, n_grants.
#' @export
build_targeting_lookup <- function(gw_nih_data) {
  if (nrow(gw_nih_data) == 0L || !"targeted_start_date" %in% names(gw_nih_data)) {
    log_event("build_targeting_lookup: empty or missing targeting data", "WARN")
    return(dplyr::tibble(
      org_name = character(0), targeting_start = as.Date(character(0)),
      targeting_end = as.Date(character(0)), n_grants = integer(0)
    ))
  }

  result <- gw_nih_data |>
    dplyr::filter(!is.na(targeted_start_date), !is.na(org_name)) |>
    dplyr::group_by(org_name) |>
    dplyr::summarise(
      targeting_start = min(targeted_start_date, na.rm = TRUE),
      targeting_end   = max(dplyr::coalesce(targeted_end_date, Sys.Date()), na.rm = TRUE),
      n_grants        = dplyr::n(),
      .groups = "drop"
    )

  log_event(sprintf(
    "Targeting lookup: %d institutions, date range %s to %s",
    nrow(result),
    if (nrow(result) > 0L) min(result$targeting_start) else "N/A",
    if (nrow(result) > 0L) max(result$targeting_end) else "N/A"
  ))

  result
}

#' Compute per-grant features from File C outlay data
#'
#' Summarizes monthly outlay records per grant: last outlay date, consecutive
#' zero-month streaks, and activity rate. If `targeting_dates` is provided,
#' also does temporal reconstruction — computing outlays before/during
#' targeting, and the outlay ratio at the time of freeze onset.
#'
#' @param file_c_data Tibble from [fetch_file_c()].
#' @param targeting_dates Tibble from [build_targeting_lookup()] or NULL.
#' @param discrepancies Tibble with grant_number and recipient_name columns
#'   for institution matching. If NULL, targeting lookup is skipped.
#' @return Tibble with one row per grant: grant_number, file_c_last_outlay_date,
#'   file_c_months_zero, file_c_total_periods, file_c_periods_with_outlays,
#'   and (if targeting_dates provided) outlays_before_targeting,
#'   outlays_during_targeting, pct_outlaid_at_targeting, months_zero_during_freeze.
#' @export
compute_file_c_features <- function(file_c_data, targeting_dates = NULL,
                                    discrepancies = NULL) {
  if (nrow(file_c_data) == 0L) {
    log_event("compute_file_c_features: no File C data", "WARN")
    return(.empty_file_c_features())
  }

  # Basic per-grant summary
  features <- file_c_data |>
    dplyr::arrange(grant_number, reporting_date) |>
    dplyr::group_by(grant_number) |>
    dplyr::summarise(
      file_c_last_outlay_date = {
        nonzero <- reporting_date[!is.na(outlay_amount) & outlay_amount > 0]
        if (length(nonzero) == 0L) as.Date(NA) else max(nonzero)
      },
      file_c_months_zero = .trailing_zero_months(outlay_amount),
      file_c_total_periods = dplyr::n(),
      file_c_periods_with_outlays = sum(
        !is.na(outlay_amount) & outlay_amount > 0, na.rm = TRUE
      ),
      file_c_total_outlays = sum(outlay_amount, na.rm = TRUE),
      .groups = "drop"
    )

  log_event(sprintf(
    "File C basic features: %d grants, median %d periods, %d with zero trailing months",
    nrow(features),
    stats::median(features$file_c_total_periods),
    sum(features$file_c_months_zero > 0L)
  ))

  # Temporal reconstruction if targeting dates available
  if (!is.null(targeting_dates) && nrow(targeting_dates) > 0L &&
      !is.null(discrepancies) && nrow(discrepancies) > 0L) {
    features <- .add_temporal_features(features, file_c_data,
                                       targeting_dates, discrepancies)
  } else {
    features <- features |>
      dplyr::mutate(
        outlays_before_targeting    = NA_real_,
        outlays_during_targeting    = NA_real_,
        pct_outlaid_at_targeting    = NA_real_,
        months_zero_during_freeze   = NA_integer_
      )
  }

  features
}

#' Enrich discrepancies with File C evidence
#'
#' Left-joins File C features onto the enriched discrepancies tibble and
#' computes `freeze_evidence` — a refined classification that upgrades
#' the existing freeze detection:
#' - "confirmed_freeze": >=3 consecutive $0 months + transaction gap >180d
#' - "likely_freeze": >=1 $0 months + transaction gap >90d
#' - "possible_freeze": outlay_ratio < 10% but no File C data
#' - "likely_not_frozen": File C shows recent nonzero outlays
#' - "confirmed_not_frozen": File C shows continuous activity
#'
#' Graceful degradation: if `file_c_features` is empty, adds NA columns
#' and preserves existing classification.
#'
#' If `file_c_data` is provided, also calls [confirm_post_termination_activity()]
#' to add `flag_confirmed_post_termination_outlays` — a defensible replacement
#' for the crude `flag_active_despite_terminated` flag (see that flag's
#' documentation for why the crude flag has high false-positive rate).
#'
#' @param discrepancies_enriched Tibble from [enrich_with_transactions()].
#' @param file_c_features Tibble from [compute_file_c_features()].
#' @param file_c_data Optional tibble from [fetch_file_c()]. If provided, enables
#'   [confirm_post_termination_activity()] analysis. Default NULL.
#' @return Enriched tibble with File C columns, freeze_evidence, and
#'   flag_confirmed_post_termination_outlays.
#' @export
enrich_with_file_c <- function(discrepancies_enriched, file_c_features,
                               file_c_data = NULL) {
  if (nrow(file_c_features) == 0L) {
    log_event("enrich_with_file_c: no File C features, adding NA columns", "WARN")
    return(discrepancies_enriched |>
      dplyr::mutate(
        file_c_last_outlay_date                  = as.Date(NA),
        file_c_months_zero                       = NA_integer_,
        file_c_total_periods                     = NA_integer_,
        file_c_periods_with_outlays              = NA_integer_,
        file_c_total_outlays                     = NA_real_,
        outlays_before_targeting                 = NA_real_,
        outlays_during_targeting                 = NA_real_,
        pct_outlaid_at_targeting                 = NA_real_,
        months_zero_during_freeze                = NA_integer_,
        freeze_evidence                          = NA_character_,
        flag_confirmed_post_termination_outlays  = NA
      ))
  }

  result <- discrepancies_enriched |>
    dplyr::left_join(file_c_features, by = "grant_number")

  # Compute freeze_evidence classification
  result <- result |>
    dplyr::mutate(
      freeze_evidence = dplyr::case_when(
        # No File C data: preserve existing classification
        is.na(file_c_total_periods) & discrepancy_type %in%
          c("possible_freeze", "possible_freeze_no_data") ~ "possible_freeze",
        is.na(file_c_total_periods) ~ NA_character_,

        # Confirmed freeze: 3+ zero months + large gap
        file_c_months_zero >= FILE_C_CONFIRMED_ZERO_MONTHS &
          !is.na(days_since_last_transaction) &
          days_since_last_transaction > FILE_C_CONFIRMED_GAP_DAYS ~ "confirmed_freeze",

        # Likely freeze: 1+ zero months + moderate gap
        file_c_months_zero >= FILE_C_LIKELY_ZERO_MONTHS &
          !is.na(days_since_last_transaction) &
          days_since_last_transaction > FILE_C_LIKELY_GAP_DAYS ~ "likely_freeze",

        # Confirmed not frozen: continuous recent activity
        file_c_months_zero == 0L &
          file_c_periods_with_outlays == file_c_total_periods ~ "confirmed_not_frozen",

        # Likely not frozen: recent nonzero outlays
        file_c_months_zero == 0L ~ "likely_not_frozen",

        # Fallback: possible freeze
        TRUE ~ "possible_freeze"
      )
    )

  # Post-termination confirmation using File C period data (Option A).
  # Replaces the crude flag_active_despite_terminated with a defensible signal:
  # outlays more than POST_TERMINATION_CLOSEOUT_DAYS after the termination notice.
  if (!is.null(file_c_data) && nrow(file_c_data) > 0L) {
    post_term <- confirm_post_termination_activity(
      file_c_data, discrepancies_enriched
    )
    result <- result |>
      dplyr::left_join(
        post_term |>
          dplyr::select(grant_number, flag_confirmed_post_termination_outlays),
        by = "grant_number"
      )
  } else {
    result <- result |>
      dplyr::mutate(flag_confirmed_post_termination_outlays = NA)
  }

  n_evidence <- table(result$freeze_evidence, useNA = "ifany")
  n_confirmed_post <- sum(
    isTRUE(result$flag_confirmed_post_termination_outlays), na.rm = TRUE
  )
  log_event(sprintf(
    "enrich_with_file_c: %d rows, freeze_evidence: %s; confirmed post-termination: %d",
    nrow(result),
    paste(names(n_evidence), n_evidence, sep = "=", collapse = ", "),
    n_confirmed_post
  ))

  result
}

# --------------------------------------------------------------------------- #
# File C internal helpers
# --------------------------------------------------------------------------- #

#' Count trailing zero-outlay months (most recent consecutive $0 streak)
#' @keywords internal
.trailing_zero_months <- function(outlay_amounts) {
  if (length(outlay_amounts) == 0L) return(0L)
  # Replace NA with 0 for counting purposes
  amounts <- dplyr::coalesce(outlay_amounts, 0)
  # Count from the end
  n <- length(amounts)
  count <- 0L
  for (i in seq(n, 1L)) {
    if (amounts[i] <= 0) {
      count <- count + 1L
    } else {
      break
    }
  }
  count
}

#' Add temporal reconstruction features by matching grants to institutions
#' @keywords internal
.add_temporal_features <- function(features, file_c_data,
                                   targeting_dates, discrepancies) {
  # Get org_name and award_amount for each grant via discrepancies
  org_lookup <- discrepancies |>
    dplyr::select(grant_number,
                  dplyr::any_of(c("recipient_name", "org_name", "award_amount"))) |>
    dplyr::distinct(grant_number, .keep_all = TRUE)

  # Determine the org name column
  org_col <- if ("recipient_name" %in% names(org_lookup)) "recipient_name" else "org_name"

  # Normalize org names for matching
  org_lookup <- org_lookup |>
    dplyr::mutate(org_name_upper = toupper(!!rlang::sym(org_col)))

  targeting_upper <- targeting_dates |>
    dplyr::mutate(org_name_upper = toupper(org_name))

  # Match grants to targeting dates via institution name
  grant_targeting <- org_lookup |>
    dplyr::inner_join(
      targeting_upper |> dplyr::select(org_name_upper, targeting_start, targeting_end),
      by = "org_name_upper"
    ) |>
    dplyr::select(grant_number, targeting_start, targeting_end,
                  dplyr::any_of("award_amount"))

  if (nrow(grant_targeting) == 0L) {
    log_event("No grants matched to targeting dates", "WARN")
    return(features |>
      dplyr::mutate(
        outlays_before_targeting  = NA_real_,
        outlays_during_targeting  = NA_real_,
        pct_outlaid_at_targeting  = NA_real_,
        months_zero_during_freeze = NA_integer_
      ))
  }

  # Carry award_amount through if available
  has_award_amount <- "award_amount" %in% names(grant_targeting)

  # Compute temporal features per grant
  temporal <- file_c_data |>
    dplyr::inner_join(grant_targeting, by = "grant_number") |>
    dplyr::group_by(grant_number, targeting_start, targeting_end,
                    dplyr::across(dplyr::any_of("award_amount"))) |>
    dplyr::summarise(
      outlays_before_targeting = sum(
        dplyr::if_else(
          !is.na(reporting_date) & reporting_date < targeting_start,
          dplyr::coalesce(outlay_amount, 0), 0
        )
      ),
      outlays_during_targeting = sum(
        dplyr::if_else(
          !is.na(reporting_date) &
            reporting_date >= targeting_start & reporting_date <= targeting_end,
          dplyr::coalesce(outlay_amount, 0), 0
        )
      ),
      months_zero_during_freeze = sum(
        !is.na(reporting_date) &
          reporting_date >= targeting_start & reporting_date <= targeting_end &
          (is.na(outlay_amount) | outlay_amount == 0)
      ),
      .groups = "drop"
    ) |>
    dplyr::select(-targeting_start, -targeting_end)

  # pct_outlaid_at_targeting: fraction of total award paid before targeting.
  # Use award_amount (total award) as denominator when available,
  # fall back to file_c_total_outlays (less meaningful but still useful).
  features_joined <- features |>
    dplyr::left_join(temporal, by = "grant_number")

  if (has_award_amount && "award_amount" %in% names(features_joined)) {
    features_joined |>
      dplyr::mutate(
        pct_outlaid_at_targeting = .safe_ratio(
          outlays_before_targeting, award_amount
        )
      ) |>
      dplyr::select(-dplyr::any_of("award_amount"))
  } else {
    features_joined |>
      dplyr::mutate(
        pct_outlaid_at_targeting = .safe_ratio(
          outlays_before_targeting, file_c_total_outlays
        )
      )
  }
}

#' Empty File C features tibble sentinel
#' @keywords internal
.empty_file_c_features <- function() {
  dplyr::tibble(
    grant_number                = character(0),
    file_c_last_outlay_date     = as.Date(character(0)),
    file_c_months_zero          = integer(0),
    file_c_total_periods        = integer(0),
    file_c_periods_with_outlays = integer(0),
    file_c_total_outlays        = double(0),
    outlays_before_targeting    = double(0),
    outlays_during_targeting    = double(0),
    pct_outlaid_at_targeting    = double(0),
    months_zero_during_freeze   = integer(0)
  )
}

# --------------------------------------------------------------------------- #
# Post-termination confirmation (Option A — File C period data)
# --------------------------------------------------------------------------- #

#' Confirm post-termination outlays using File C period data
#'
#' Uses period-by-period File C outlay data to identify grants with confirmed
#' outlays AFTER the 120-day administrative closeout window following their
#' termination notice date. This is the defensible replacement for
#' `flag_active_despite_terminated`, which fires on any cumulative historical
#' outlay and has a ~85-95% false-positive rate due to:
#'   - Legitimate closeout disbursements (2 CFR §200.344 allows 120 days)
#'   - Cumulative `total_outlays` counting all pre-termination spending
#'   - Fuzzy-match artifacts where the award is not actually terminated
#'   - Reinstated grants receiving outlays legally
#'
#' The 120-day window is the statutory closeout period from 2 CFR §200.344.
#' Outlays within it are routine; outlays beyond it in a terminated grant are
#' a genuine contradiction.
#'
#' @param file_c_data Tibble from [fetch_file_c()].
#' @param discrepancies Tibble from [join_and_flag()] with grant_number,
#'   notice_date columns.
#' @param closeout_days Integer. Days after notice_date before outlays are
#'   anomalous. Default POST_TERMINATION_CLOSEOUT_DAYS (120L).
#' @param min_outlay_amount Numeric. Minimum outlay ($) to count as evidence.
#'   Default POST_TERMINATION_MIN_OUTLAY (100). Filters accounting artifacts.
#' @return Tibble: grant_number, flag_confirmed_post_termination_outlays,
#'   n_post_termination_periods, post_termination_total_outlays,
#'   post_termination_first_date, post_termination_last_date.
#' @export
confirm_post_termination_activity <- function(
  file_c_data,
  discrepancies,
  closeout_days     = POST_TERMINATION_CLOSEOUT_DAYS,
  min_outlay_amount = POST_TERMINATION_MIN_OUTLAY
) {
  if (nrow(file_c_data) == 0L || nrow(discrepancies) == 0L) {
    return(.empty_post_termination_tibble())
  }

  # Extract termination notice dates for terminated grants
  terminated <- discrepancies |>
    dplyr::filter(!is.na(notice_date)) |>
    dplyr::select(grant_number, notice_date) |>
    dplyr::distinct(grant_number, .keep_all = TRUE) |>
    dplyr::mutate(closeout_deadline = notice_date + closeout_days)

  if (nrow(terminated) == 0L) {
    return(.empty_post_termination_tibble())
  }

  # Join File C to terminated grants
  file_c_terminated <- file_c_data |>
    dplyr::inner_join(
      terminated |> dplyr::select(grant_number, closeout_deadline),
      by = "grant_number"
    )

  if (nrow(file_c_terminated) == 0L) {
    return(.empty_post_termination_tibble())
  }

  # Periods with meaningful outlays AFTER the closeout window
  post_closeout <- file_c_terminated |>
    dplyr::filter(
      !is.na(reporting_date),
      reporting_date > closeout_deadline,
      !is.na(outlay_amount),
      outlay_amount >= min_outlay_amount
    )

  # Per-grant summary for grants WITH post-termination outlays
  if (nrow(post_closeout) == 0L) {
    confirmed <- .empty_post_termination_tibble()
  } else {
    confirmed <- post_closeout |>
      dplyr::group_by(grant_number) |>
      dplyr::summarise(
        flag_confirmed_post_termination_outlays = TRUE,
        n_post_termination_periods              = dplyr::n(),
        post_termination_total_outlays          = sum(outlay_amount, na.rm = TRUE),
        post_termination_first_date             = min(reporting_date, na.rm = TRUE),
        post_termination_last_date              = max(reporting_date, na.rm = TRUE),
        .groups = "drop"
      )
  }

  # Grants covered by File C but with no post-termination outlays (FALSE flag)
  covered_grants <- unique(file_c_terminated$grant_number)
  not_confirmed  <- setdiff(covered_grants, confirmed$grant_number)

  if (length(not_confirmed) > 0L) {
    padding <- dplyr::tibble(
      grant_number                            = not_confirmed,
      flag_confirmed_post_termination_outlays = FALSE,
      n_post_termination_periods              = 0L,
      post_termination_total_outlays          = 0,
      post_termination_first_date             = as.Date(NA),
      post_termination_last_date              = as.Date(NA)
    )
    confirmed <- dplyr::bind_rows(confirmed, padding)
  }

  n_confirmed <- sum(confirmed$flag_confirmed_post_termination_outlays, na.rm = TRUE)
  log_event(sprintf(
    "confirm_post_termination_activity: %d terminated grants with File C, %d confirmed post-closeout outlays",
    nrow(confirmed), n_confirmed
  ))

  confirmed |>
    dplyr::select(
      grant_number,
      flag_confirmed_post_termination_outlays,
      n_post_termination_periods,
      post_termination_total_outlays,
      post_termination_first_date,
      post_termination_last_date
    )
}

#' @keywords internal
.empty_post_termination_tibble <- function() {
  dplyr::tibble(
    grant_number                            = character(0),
    flag_confirmed_post_termination_outlays = logical(0),
    n_post_termination_periods              = integer(0),
    post_termination_total_outlays          = double(0),
    post_termination_first_date             = as.Date(character(0)),
    post_termination_last_date              = as.Date(character(0))
  )
}

# --------------------------------------------------------------------------- #
# Emergency fund flags — political targeting signal
# --------------------------------------------------------------------------- #

#' Enrich discrepancies with emergency fund exemption flags
#'
#' Adds `flag_emergency_exempt` to the enriched discrepancies tibble. TRUE
#' when a frozen or active-despite-terminated grant carries COVID-19 or ARP
#' `def_codes` (see [EMERGENCY_DEFC_CODES]) — meaning it receives congressionally
#' mandated pandemic emergency funding while being flagged as frozen for research.
#'
#' This is a political targeting signal: a grant frozen for "regular" research
#' activity but still receiving congressionally mandated emergency money
#' suggests selective interference rather than a blanket administrative hold.
#'
#' Only COVID-19 and ARP codes trigger the flag (see [EMERGENCY_DEFC_CODES]).
#' IIJA code `Q` is excluded — it appears on ~82% of awards and is not a
#' useful political targeting signal.
#'
#' @param discrepancies_file_c Tibble from [enrich_with_file_c()]. Must have
#'   `grant_number` and `discrepancy_type` columns.
#' @param usaspending_awards Tibble from [fetch_usaspending()] with
#'   `grant_number` and `def_codes` columns. If NULL or zero-row, falls back
#'   to `def_codes` already present in `discrepancies_file_c` (if any).
#' @return The input tibble with `flag_emergency_exempt` column appended.
#' @export
enrich_with_emergency_flags <- function(discrepancies_file_c,
                                        usaspending_awards = NULL) {
  if (nrow(discrepancies_file_c) == 0L) {
    log_event("enrich_with_emergency_flags: empty input", "WARN")
    return(discrepancies_file_c |> dplyr::mutate(flag_emergency_exempt = NA))
  }

  # Resolve source of def_codes: prefer explicit awards tibble over any
  # def_codes already embedded in the enriched discrepancies.
  if (!is.null(usaspending_awards) &&
      nrow(usaspending_awards) > 0L &&
      "def_codes" %in% names(usaspending_awards)) {

    def_lookup <- usaspending_awards |>
      dplyr::select(grant_number, def_codes) |>
      dplyr::distinct(grant_number, .keep_all = TRUE)

    # Overwrite def_codes in-place via match — avoids copying the full tibble
    result <- discrepancies_file_c |>
      dplyr::mutate(
        def_codes = def_lookup$def_codes[match(grant_number, def_lookup$grant_number)]
      )

  } else if ("def_codes" %in% names(discrepancies_file_c)) {
    result <- discrepancies_file_c
  } else {
    log_event("enrich_with_emergency_flags: no def_codes source available, flag set to NA", "WARN")
    return(discrepancies_file_c |> dplyr::mutate(flag_emergency_exempt = NA))
  }

  result <- result |>
    dplyr::mutate(
      flag_emergency_exempt = !is.na(def_codes) &
        # Any of the grant's semicolon/comma-separated codes matches a COVID/ARP code
        purrr::map_lgl(strsplit(def_codes, "[,;]+"), function(codes)
          any(trimws(codes) %in% EMERGENCY_DEFC_CODES)
        ) &
        discrepancy_type %in% FREEZE_RELATED_DISCREPANCY_TYPES
    )

  n_flagged <- sum(result$flag_emergency_exempt, na.rm = TRUE)
  log_event(sprintf(
    "enrich_with_emergency_flags: %d/%d discrepancy grants carry emergency funding codes",
    n_flagged, nrow(result)
  ))

  result
}
