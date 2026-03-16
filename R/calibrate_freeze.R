#' @title Freeze Heuristic Calibration Against Grant Witness Ground Truth
#' @description Joins GW labeled data against our pipeline features to measure
#'   precision/recall of our freeze detection, then builds a calibrated classifier.

# --------------------------------------------------------------------------- #
# Join GW labels to our discrepancies
# --------------------------------------------------------------------------- #

#' Join Grant Witness labeled data to our discrepancies by award ID
#'
#' @param gw_data Tibble from [fetch_gw_nih()].
#' @param our_discrepancies Tibble from [enrich_with_transactions()].
#' @return Joined tibble with both GW labels and our features.
#' @export
join_gw_usaspending <- function(gw_data, our_discrepancies) {
  log_event("Joining GW labels to our discrepancies")

  # GW's core_award_number (e.g., R01MH138335) should match USAspending Award ID
  # Both gw_data and our_discrepancies carry org_name; keep GW's (more curated)
  # and drop the USAspending-side copy to avoid .x/.y ambiguity downstream.
  joined <- dplyr::inner_join(
    gw_data,
    dplyr::select(our_discrepancies, -dplyr::any_of("org_name")),
    by = c("gw_award_id" = "grant_number")
  )

  n_gw <- dplyr::n_distinct(gw_data$gw_award_id)
  n_ours <- dplyr::n_distinct(our_discrepancies$grant_number)
  n_matched <- dplyr::n_distinct(joined$gw_award_id)

  # Coverage gap analysis
  gw_only <- setdiff(gw_data$gw_award_id, our_discrepancies$grant_number)
  ours_only <- setdiff(our_discrepancies$grant_number, gw_data$gw_award_id)

  log_event(sprintf(
    "Join results: %d GW grants, %d our grants, %d matched (%.1f%% of GW, %.1f%% of ours)",
    n_gw, n_ours, n_matched,
    100 * n_matched / max(n_gw, 1),
    100 * n_matched / max(n_ours, 1)
  ))
  log_event(sprintf(
    "Coverage gaps: %d in GW only, %d in ours only",
    length(gw_only), length(ours_only)
  ))

  joined
}

# --------------------------------------------------------------------------- #
# Compute calibration features
# --------------------------------------------------------------------------- #

#' Compute calibration features from joined GW + pipeline data
#'
#' @param joined_data Tibble from [join_gw_usaspending()].
#' @return Tibble with calibration features for each grant.
#' @export
compute_calibration_features <- function(joined_data) {
  log_event("Computing calibration features")

  # Parse GW status into binary frozen label
  frozen_statuses <- c(
    "\U0001f9ca Frozen Funding",
    "\U0001f4a7 Possibly Unfrozen Funding",
    "\U0001f6b0 Unfrozen Funding"
  )

  result <- joined_data |>
    dplyr::mutate(
      # Our features (already computed in pipeline)
      our_outlay_ratio    = outlay_ratio,
      our_elapsed_ratio   = elapsed_ratio,
      # Use the financial signal directly — discrepancy_type is always "untracked"
      # for GW-matched calibration grants (they have no matching termination notice
      # in our scrape), so the notice-based flag would always be FALSE and produce
      # misleading 0 precision/recall at the current threshold.
      #
      # Intentional divergence from production: sub_agency filtering is NOT applied
      # here. GW tracks only research grants (NIH/NSF), so no Medicaid/TANF/ACF
      # grants appear in gw_nih_data, making the sub_agency filter a no-op on this
      # calibration dataset. Calibration therefore measures the raw financial signal.
      our_freeze_flag     = !is.na(outlay_ratio) & outlay_ratio < FREEZE_RATIO_THRESHOLD,
      our_freeze_confidence = freeze_confidence,

      # GW ground truth
      gw_frozen           = ever_frozen | gw_status %in% frozen_statuses,
      gw_status_detail    = gw_status,

      # Temporal features from GW data
      days_frozen = dplyr::if_else(
        !is.na(targeted_start_date),
        as.numeric(dplyr::coalesce(targeted_end_date, Sys.Date()) - targeted_start_date),
        NA_real_
      ),

      # Days since last payment (from GW data)
      days_since_last_payment = dplyr::if_else(
        !is.na(last_payment_date),
        as.numeric(Sys.Date() - last_payment_date),
        NA_real_
      ),

      # Activity code grouping (R/T/F/K series)
      activity_code_group = dplyr::case_when(
        grepl("^R", activity_code) ~ "R",
        grepl("^T", activity_code) ~ "T",
        grepl("^F", activity_code) ~ "F",
        grepl("^K", activity_code) ~ "K",
        grepl("^P", activity_code) ~ "P",
        grepl("^U", activity_code) ~ "U",
        TRUE                       ~ "Other"
      )
    )

  log_event(sprintf(
    "Calibration features: %d grants, %d GW frozen, %d our freeze flag",
    nrow(result),
    sum(result$gw_frozen, na.rm = TRUE),
    sum(result$our_freeze_flag, na.rm = TRUE)
  ))

  result
}

# --------------------------------------------------------------------------- #
# Evaluate our heuristic
# --------------------------------------------------------------------------- #

#' Evaluate our freeze heuristic against GW ground truth
#'
#' @param calibration_data Tibble from [compute_calibration_features()].
#' @return List with confusion matrix, metrics, threshold sweep, and breakdowns.
#' @export
evaluate_heuristic <- function(calibration_data) {
  log_event("Evaluating freeze heuristic")

  # Filter to grants with both labels
  eval_data <- calibration_data |>
    dplyr::filter(!is.na(gw_frozen), !is.na(our_outlay_ratio))

  # --- Confusion matrix at current threshold ---
  cm <- table(
    predicted = eval_data$our_freeze_flag,
    actual    = eval_data$gw_frozen
  )

  tp <- if ("TRUE" %in% rownames(cm) && "TRUE" %in% colnames(cm)) cm["TRUE", "TRUE"] else 0L
  fp <- if ("TRUE" %in% rownames(cm) && "FALSE" %in% colnames(cm)) cm["TRUE", "FALSE"] else 0L
  fn <- if ("FALSE" %in% rownames(cm) && "TRUE" %in% colnames(cm)) cm["FALSE", "TRUE"] else 0L
  tn <- if ("FALSE" %in% rownames(cm) && "FALSE" %in% colnames(cm)) cm["FALSE", "FALSE"] else 0L

  precision <- .safe_ratio(tp, tp + fp) %||% NA_real_
  recall    <- .safe_ratio(tp, tp + fn) %||% NA_real_
  f1 <- if (!is.na(precision) && !is.na(recall) && (precision + recall) > 0) {
    2 * precision * recall / (precision + recall)
  } else {
    NA_real_
  }

  log_event(sprintf(
    "Current threshold (%.2f): P=%.3f, R=%.3f, F1=%.3f (TP=%d, FP=%d, FN=%d, TN=%d)",
    FREEZE_RATIO_THRESHOLD,
    dplyr::coalesce(precision, 0), dplyr::coalesce(recall, 0), dplyr::coalesce(f1, 0),
    tp, fp, fn, tn
  ))

  # --- Threshold sweep ---
  thresholds <- seq(0.01, 0.50, by = 0.01)
  sweep <- purrr::map_dfr(thresholds, function(thresh) {
    pred <- !is.na(eval_data$our_outlay_ratio) & eval_data$our_outlay_ratio < thresh &
      !is.na(eval_data$elapsed_ratio) # proxy for "active award"
    tp_t <- sum(pred & eval_data$gw_frozen, na.rm = TRUE)
    fp_t <- sum(pred & !eval_data$gw_frozen, na.rm = TRUE)
    fn_t <- sum(!pred & eval_data$gw_frozen, na.rm = TRUE)
    p <- dplyr::coalesce(.safe_ratio(tp_t, tp_t + fp_t), 0)
    r <- dplyr::coalesce(.safe_ratio(tp_t, tp_t + fn_t), 0)
    f1_val <- if ((p + r) > 0) 2 * p * r / (p + r) else 0
    dplyr::tibble(
      threshold = thresh,
      precision = p,
      recall    = r,
      f1        = f1_val,
      tp = tp_t, fp = fp_t, fn = fn_t
    )
  })

  optimal_idx <- which.max(sweep$f1)
  optimal_threshold <- sweep$threshold[optimal_idx]

  log_event(sprintf(
    "Optimal threshold: %.2f (P=%.3f, R=%.3f, F1=%.3f)",
    optimal_threshold,
    sweep$precision[optimal_idx],
    sweep$recall[optimal_idx],
    sweep$f1[optimal_idx]
  ))

  # --- Breakdown by institution ---
  institution_breakdown <- eval_data |>
    dplyr::filter(!is.na(org_name)) |>
    dplyr::group_by(org_name) |>
    dplyr::summarise(
      n_grants   = dplyr::n(),
      n_gw_frozen = sum(gw_frozen, na.rm = TRUE),
      n_our_flag  = sum(our_freeze_flag, na.rm = TRUE),
      tp = sum(our_freeze_flag & gw_frozen, na.rm = TRUE),
      fp = sum(our_freeze_flag & !gw_frozen, na.rm = TRUE),
      fn = sum(!our_freeze_flag & gw_frozen, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      precision = .safe_ratio(tp, tp + fp),
      recall    = .safe_ratio(tp, tp + fn)
    ) |>
    dplyr::arrange(dplyr::desc(n_grants))

  # --- Breakdown by activity code ---
  activity_breakdown <- eval_data |>
    dplyr::filter(!is.na(activity_code_group)) |>
    dplyr::group_by(activity_code_group) |>
    dplyr::summarise(
      n_grants   = dplyr::n(),
      n_gw_frozen = sum(gw_frozen, na.rm = TRUE),
      n_our_flag  = sum(our_freeze_flag, na.rm = TRUE),
      tp = sum(our_freeze_flag & gw_frozen, na.rm = TRUE),
      fp = sum(our_freeze_flag & !gw_frozen, na.rm = TRUE),
      fn = sum(!our_freeze_flag & gw_frozen, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      precision = .safe_ratio(tp, tp + fp),
      recall    = .safe_ratio(tp, tp + fn)
    )

  # --- False positive / false negative analysis ---
  false_positives <- eval_data |>
    dplyr::filter(our_freeze_flag & !gw_frozen) |>
    dplyr::select(gw_award_id, org_name, gw_status_detail, our_outlay_ratio, our_elapsed_ratio, award_amount)

  false_negatives <- eval_data |>
    dplyr::filter(!our_freeze_flag & gw_frozen) |>
    dplyr::select(gw_award_id, org_name, gw_status_detail, our_outlay_ratio, our_elapsed_ratio, award_amount)

  list(
    confusion_matrix       = cm,
    precision              = precision,
    recall                 = recall,
    f1                     = f1,
    current_threshold      = FREEZE_RATIO_THRESHOLD,
    threshold_sweep        = sweep,
    optimal_threshold      = optimal_threshold,
    optimal_f1             = sweep$f1[optimal_idx],
    institution_breakdown  = institution_breakdown,
    activity_breakdown     = activity_breakdown,
    false_positives        = false_positives,
    false_negatives        = false_negatives,
    n_eval                 = nrow(eval_data)
  )
}

# --------------------------------------------------------------------------- #
# Temporal gap analysis
# --------------------------------------------------------------------------- #

#' Analyze the temporal reconstruction gap
#'
#' GW checks outlays at time of targeting, not current time. This function
#' quantifies the difference and identifies grants where temporal reconstruction
#' changes the classification.
#'
#' @param calibration_data Tibble from [compute_calibration_features()].
#' @return List with temporal analysis results.
#' @export
analyze_temporal_gap <- function(calibration_data) {
  log_event("Analyzing temporal reconstruction gap")

  # Focus on grants at targeted institutions with File C data
  targeted <- calibration_data |>
    dplyr::filter(!is.na(targeted_start_date), !is.na(file_c_outlays_raw))

  if (nrow(targeted) == 0L) {
    log_event("No grants with targeting dates and File C data found", "WARN")
    return(list(
      n_targeted = 0L,
      n_with_file_c = 0L,
      temporal_mismatches = dplyr::tibble(),
      duke_analysis = dplyr::tibble()
    ))
  }

  # Parse File C outlays for each grant
  targeted <- targeted |>
    dplyr::mutate(
      file_c_parsed = purrr::map(file_c_outlays_raw, parse_file_c_outlays)
    )

  # For each grant: compute outlays before vs during targeting
  temporal_features <- targeted |>
    dplyr::mutate(
      outlays_before_targeting = purrr::map2_dbl(
        file_c_parsed, targeted_start_date,
        function(fc, tsd) {
          if (nrow(fc) == 0L || is.na(tsd)) return(NA_real_)
          sum(fc$amount[!is.na(fc$period_date) & fc$period_date < tsd], na.rm = TRUE)
        }
      ),
      outlays_during_targeting = purrr::map2_dbl(
        file_c_parsed, targeted_start_date,
        function(fc, tsd) {
          if (nrow(fc) == 0L || is.na(tsd)) return(NA_real_)
          sum(fc$amount[!is.na(fc$period_date) & fc$period_date >= tsd], na.rm = TRUE)
        }
      ),
      pct_outlaid_at_targeting = .safe_ratio(outlays_before_targeting, gw_total_award),
      months_zero_during_freeze = purrr::map2_int(
        file_c_parsed, targeted_start_date,
        function(fc, tsd) {
          if (nrow(fc) == 0L || is.na(tsd)) return(NA_integer_)
          during <- fc |> dplyr::filter(!is.na(period_date), period_date >= tsd)
          sum(during$amount == 0, na.rm = TRUE)
        }
      )
    )

  # Temporal mismatches: grants that look different now vs at targeting
  temporal_mismatches <- temporal_features |>
    dplyr::filter(!is.na(pct_outlaid_at_targeting), !is.na(our_outlay_ratio)) |>
    dplyr::mutate(
      looks_paid_now = our_outlay_ratio > 0.50,
      was_low_at_targeting = pct_outlaid_at_targeting < 0.50,
      temporal_mismatch = looks_paid_now & was_low_at_targeting
    )

  n_mismatches <- sum(temporal_mismatches$temporal_mismatch, na.rm = TRUE)

  log_event(sprintf(
    "Temporal analysis: %d targeted grants, %d with File C data, %d temporal mismatches",
    nrow(targeted), sum(!is.na(targeted$file_c_outlays_raw)), n_mismatches
  ))

  # Duke anomaly analysis
  duke <- temporal_features |>
    dplyr::filter(grepl("DUKE", org_name, ignore.case = TRUE))

  if (nrow(duke) > 0L) {
    log_event(sprintf(
      "Duke anomaly: %d grants, %d with outlays during freeze period",
      nrow(duke), sum(duke$outlays_during_targeting > 100, na.rm = TRUE)
    ))
  }

  list(
    n_targeted          = nrow(targeted),
    n_with_file_c       = sum(!is.na(targeted$file_c_outlays_raw)),
    n_temporal_mismatches = n_mismatches,
    temporal_mismatches = temporal_mismatches |>
      dplyr::filter(temporal_mismatch) |>
      dplyr::select(gw_award_id, org_name, our_outlay_ratio,
                    pct_outlaid_at_targeting, gw_status_detail),
    duke_analysis       = duke |>
      dplyr::select(gw_award_id, org_name, outlays_before_targeting,
                    outlays_during_targeting, pct_outlaid_at_targeting,
                    gw_status_detail, our_outlay_ratio)
  )
}

# --------------------------------------------------------------------------- #
# Simple freeze classifier
# --------------------------------------------------------------------------- #

#' Build a logistic regression freeze classifier
#'
#' Uses our pipeline features to predict GW's frozen label. Keeps it simple
#' and interpretable — no hyperparameter tuning, just glm + cross-validation.
#'
#' @param calibration_data Tibble from [compute_calibration_features()].
#' @return List with model, predictions, AUC, and feature importance.
#' @export
build_freeze_classifier <- function(calibration_data) {
  log_event("Building freeze classifier")

  # Prepare modeling data
  model_data <- calibration_data |>
    dplyr::filter(
      !is.na(gw_frozen),
      !is.na(our_outlay_ratio),
      !is.na(our_elapsed_ratio)
    ) |>
    dplyr::mutate(
      frozen_binary = as.integer(gw_frozen),
      days_since_txn = dplyr::coalesce(
        as.numeric(days_since_last_transaction),
        365  # default for missing transaction data
      ),
      activity_R = as.integer(activity_code_group == "R"),
      activity_T = as.integer(activity_code_group == "T"),
      activity_F = as.integer(activity_code_group == "F"),
      activity_K = as.integer(activity_code_group == "K")
    )

  if (nrow(model_data) < 50L) {
    log_event("Too few observations for classifier", "WARN")
    return(list(model = NULL, n_obs = nrow(model_data), auc = NA_real_))
  }

  # 5-fold cross-validation
  set.seed(42L)
  n <- nrow(model_data)
  folds <- sample(rep(1:5, length.out = n))
  cv_predictions <- numeric(n)

  for (k in 1:5) {
    train <- model_data[folds != k, ]
    test  <- model_data[folds == k, ]

    fit <- stats::glm(
      frozen_binary ~ our_outlay_ratio + our_elapsed_ratio + days_since_txn +
        activity_R + activity_T + activity_F + activity_K,
      data = train,
      family = stats::binomial()
    )

    cv_predictions[folds == k] <- stats::predict(fit, newdata = test, type = "response")
  }

  # Full model for coefficients
  full_fit <- stats::glm(
    frozen_binary ~ our_outlay_ratio + our_elapsed_ratio + days_since_txn +
      activity_R + activity_T + activity_F + activity_K,
    data = model_data,
    family = stats::binomial()
  )

  # AUC computation (manual — avoid pROC dependency)
  auc <- .compute_auc(cv_predictions, model_data$frozen_binary)

  # Feature importance from coefficients
  coefs <- summary(full_fit)$coefficients
  feature_importance <- dplyr::tibble(
    feature = rownames(coefs),
    coefficient = coefs[, "Estimate"],
    std_error   = coefs[, "Std. Error"],
    z_value     = coefs[, "z value"],
    p_value     = coefs[, "Pr(>|z|)"]
  ) |>
    dplyr::filter(feature != "(Intercept)") |>
    dplyr::arrange(p_value)

  # Optimal threshold by F1 on CV predictions
  thresholds <- seq(0.1, 0.9, by = 0.05)
  best_f1 <- 0
  best_thresh <- 0.5
  for (thresh in thresholds) {
    pred_class <- cv_predictions >= thresh
    tp <- sum(pred_class & model_data$frozen_binary == 1)
    fp <- sum(pred_class & model_data$frozen_binary == 0)
    fn <- sum(!pred_class & model_data$frozen_binary == 1)
    p <- dplyr::coalesce(.safe_ratio(tp, tp + fp), 0)
    r <- dplyr::coalesce(.safe_ratio(tp, tp + fn), 0)
    f <- if ((p + r) > 0) 2 * p * r / (p + r) else 0
    if (f > best_f1) {
      best_f1 <- f
      best_thresh <- thresh
    }
  }

  model_data$cv_probability <- cv_predictions

  log_event(sprintf(
    "Classifier: %d obs, AUC=%.3f, optimal threshold=%.2f (F1=%.3f)",
    n, auc, best_thresh, best_f1
  ))

  list(
    model              = full_fit,
    n_obs              = n,
    auc                = auc,
    optimal_threshold  = best_thresh,
    optimal_f1         = best_f1,
    feature_importance = feature_importance,
    cv_predictions     = model_data |>
      dplyr::select(gw_award_id, frozen_binary, cv_probability, gw_status_detail, org_name)
  )
}

#' Compute AUC using the Mann-Whitney U statistic
#' @keywords internal
.compute_auc <- function(predictions, labels) {
  pos <- predictions[labels == 1]
  neg <- predictions[labels == 0]
  if (length(pos) == 0L || length(neg) == 0L) return(NA_real_)

  # Mann-Whitney U: fraction of (pos, neg) pairs where pos > neg
  n_pairs <- length(pos) * length(neg)
  if (n_pairs == 0L) return(NA_real_)

  u <- sum(vapply(pos, function(p) sum(p > neg) + 0.5 * sum(p == neg), numeric(1)))
  u / n_pairs
}
