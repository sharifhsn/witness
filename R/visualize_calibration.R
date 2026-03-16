#' @title Calibration Visualizations
#' @description ggplot2 charts for freeze heuristic calibration analysis.

# --------------------------------------------------------------------------- #
# Plot 1: Threshold sweep — precision/recall tradeoff
# --------------------------------------------------------------------------- #

#' Precision-recall tradeoff across freeze thresholds
#'
#' @param calibration_results List from [evaluate_heuristic()].
#' @return A ggplot object.
#' @export
plot_threshold_sweep <- function(calibration_results) {
  sweep <- calibration_results$threshold_sweep

  ggplot2::ggplot(sweep, ggplot2::aes(x = threshold)) +
    ggplot2::geom_line(ggplot2::aes(y = precision, color = "Precision"), linewidth = 1) +
    ggplot2::geom_line(ggplot2::aes(y = recall, color = "Recall"), linewidth = 1) +
    ggplot2::geom_line(ggplot2::aes(y = f1, color = "F1"), linewidth = 1, linetype = "dashed") +
    ggplot2::geom_vline(
      xintercept = calibration_results$current_threshold,
      linetype = "dotted", color = "grey40", linewidth = 0.5
    ) +
    ggplot2::geom_vline(
      xintercept = calibration_results$optimal_threshold,
      linetype = "dashed", color = "#e38958", linewidth = 0.5
    ) +
    ggplot2::annotate("text",
      x = calibration_results$current_threshold, y = 0.05,
      label = sprintf("Current (%.0f%%)", calibration_results$current_threshold * 100),
      hjust = -0.1, size = 3, color = "grey40"
    ) +
    ggplot2::annotate("text",
      x = calibration_results$optimal_threshold, y = 0.10,
      label = sprintf("Optimal (%.0f%%)", calibration_results$optimal_threshold * 100),
      hjust = -0.1, size = 3, color = "#e38958"
    ) +
    ggplot2::scale_color_manual(values = c(
      "Precision" = "#a4388a", "Recall" = "#570da0", "F1" = "#e38958"
    ), name = NULL) +
    ggplot2::scale_y_continuous(labels = scales::label_percent(), limits = c(0, 1)) +
    ggplot2::scale_x_continuous(labels = scales::label_percent()) +
    ggplot2::labs(
      title    = "Freeze Detection: Precision-Recall Tradeoff",
      subtitle = "Sweeping outlay ratio threshold against Grant Witness ground truth",
      x = "Outlay Ratio Threshold", y = "Score",
      caption  = "Source: Grant Witness labeled data + USAspending.gov"
    ) +
    theme_gw()
}

# --------------------------------------------------------------------------- #
# Plot 2: Confusion heatmap
# --------------------------------------------------------------------------- #

#' Confusion heatmap: our flags vs GW status
#'
#' @param calibration_data Tibble from [compute_calibration_features()].
#' @return A ggplot object.
#' @export
plot_confusion_heatmap <- function(calibration_data) {
  # Simplify GW status for display
  plot_data <- calibration_data |>
    dplyr::filter(!is.na(gw_status_detail), !is.na(discrepancy_type)) |>
    dplyr::mutate(
      gw_label = dplyr::case_when(
        grepl("Frozen", gw_status_detail)            ~ "Frozen",
        grepl("Unfrozen", gw_status_detail)          ~ "Unfrozen",
        grepl("Terminated", gw_status_detail)        ~ "Terminated",
        grepl("Reinstated", gw_status_detail)        ~ "Reinstated",
        TRUE                                          ~ "Other"
      ),
      our_label = dplyr::case_when(
        discrepancy_type == "active_despite_terminated" ~ "Active Despite\nTerminated",
        discrepancy_type == "possible_freeze"           ~ "Possible Freeze",
        discrepancy_type == "possible_freeze_no_data"   ~ "Freeze (No Data)",
        discrepancy_type == "untracked"                 ~ "Untracked",
        TRUE                                            ~ "Normal"
      )
    ) |>
    dplyr::count(our_label, gw_label)

  ggplot2::ggplot(plot_data, ggplot2::aes(x = gw_label, y = our_label, fill = n)) +
    ggplot2::geom_tile(color = "white", linewidth = 0.5) +
    ggplot2::geom_text(ggplot2::aes(label = n), size = 4, fontface = "bold") +
    ggplot2::scale_fill_viridis_c(option = "plasma", name = "Count", direction = -1) +
    ggplot2::labs(
      title    = "Our Classification vs. Grant Witness Labels",
      subtitle = "Cell counts show agreement/disagreement between methodologies",
      x = "Grant Witness Status", y = "Our Classification",
      caption  = "Source: Grant Witness labeled data + USAspending.gov"
    ) +
    theme_gw() +
    ggplot2::theme(
      panel.grid = ggplot2::element_blank(),
      axis.text.x = ggplot2::element_text(angle = 30, hjust = 1)
    )
}

# --------------------------------------------------------------------------- #
# Plot 3: File C outlay timeline for sample frozen grants
# --------------------------------------------------------------------------- #

#' File C outlay timelines for frozen vs unfrozen grants
#'
#' @param calibration_data Tibble from [compute_calibration_features()].
#' @param n_sample Number of grants per status to show. Default 6.
#' @return A ggplot object.
#' @export
plot_temporal_reconstruction <- function(calibration_data, n_sample = 6L) {
  # Select sample grants with File C data
  sample_data <- calibration_data |>
    dplyr::filter(!is.na(file_c_outlays_raw), nchar(file_c_outlays_raw) > 5L) |>
    dplyr::mutate(
      freeze_label = dplyr::if_else(gw_frozen, "Frozen", "Not Frozen")
    )

  # Sample n_sample per group (slice_sample handles n > group size gracefully)
  sampled <- sample_data |>
    dplyr::group_by(freeze_label) |>
    dplyr::slice_sample(n = n_sample) |>
    dplyr::ungroup()

  if (nrow(sampled) == 0L) return(ggplot2::ggplot() + ggplot2::labs(title = "No File C data available"))

  # Parse File C for each sampled grant
  timeline <- sampled |>
    dplyr::select(gw_award_id, file_c_outlays_raw, targeted_start_date, freeze_label) |>
    dplyr::mutate(
      file_c = purrr::map(file_c_outlays_raw, parse_file_c_outlays)
    ) |>
    tidyr::unnest(file_c)

  if (nrow(timeline) == 0L) return(ggplot2::ggplot() + ggplot2::labs(title = "No parseable File C data"))

  ggplot2::ggplot(timeline, ggplot2::aes(x = period_date, y = amount)) +
    ggplot2::geom_col(fill = "#a4388a", alpha = 0.7) +
    ggplot2::geom_vline(
      ggplot2::aes(xintercept = as.numeric(targeted_start_date)),
      linetype = "dashed", color = "#e38958", linewidth = 0.5
    ) +
    ggplot2::facet_wrap(~ gw_award_id + freeze_label, scales = "free_y", ncol = 2) +
    ggplot2::scale_y_continuous(labels = scales::label_dollar(scale_cut = scales::cut_short_scale())) +
    ggplot2::labs(
      title    = "File C Outlay Timelines: Frozen vs. Not Frozen Grants",
      subtitle = "Orange dashed line = institutional targeting start date",
      x = "Period", y = "Outlay Amount",
      caption  = "Source: Grant Witness File C data"
    ) +
    theme_gw() +
    ggplot2::theme(strip.text = ggplot2::element_text(size = 7))
}

# --------------------------------------------------------------------------- #
# Plot 4: Institution-level performance
# --------------------------------------------------------------------------- #

#' Precision and recall by institution
#'
#' @param calibration_results List from [evaluate_heuristic()].
#' @return A ggplot object.
#' @export
plot_institution_performance <- function(calibration_results) {
  inst <- calibration_results$institution_breakdown |>
    dplyr::filter(n_grants >= 10L) |>  # only institutions with enough data
    dplyr::mutate(
      org_short = sub("^(THE )?", "", org_name),
      org_short = substr(org_short, 1, 30)
    ) |>
    tidyr::pivot_longer(
      cols = c(precision, recall),
      names_to = "metric",
      values_to = "value"
    ) |>
    dplyr::filter(!is.na(value))

  if (nrow(inst) == 0L) {
    return(ggplot2::ggplot() + ggplot2::labs(title = "Insufficient data for institution breakdown"))
  }

  ggplot2::ggplot(inst, ggplot2::aes(x = value, y = stats::reorder(org_short, value), fill = metric)) +
    ggplot2::geom_col(position = "dodge", alpha = 0.8) +
    ggplot2::scale_fill_manual(values = c("precision" = "#a4388a", "recall" = "#570da0"), name = NULL) +
    ggplot2::scale_x_continuous(labels = scales::label_percent(), limits = c(0, 1)) +
    ggplot2::labs(
      title    = "Freeze Detection Performance by Institution",
      subtitle = "Our heuristic vs. Grant Witness labels (institutions with 10+ grants)",
      x = "Score", y = NULL,
      caption  = "Source: Grant Witness labeled data + USAspending.gov"
    ) +
    theme_gw()
}

# --------------------------------------------------------------------------- #
# Plot 5: ROC-style curve from classifier
# --------------------------------------------------------------------------- #

#' ROC curve from the logistic regression classifier
#'
#' @param classifier_results List from [build_freeze_classifier()].
#' @return A ggplot object.
#' @export
plot_roc_curve <- function(classifier_results) {
  if (is.null(classifier_results$model)) {
    return(ggplot2::ggplot() + ggplot2::labs(title = "Classifier not built (insufficient data)"))
  }

  preds <- classifier_results$cv_predictions
  thresholds <- seq(0.01, 0.99, by = 0.01)

  roc_data <- purrr::map_dfr(thresholds, function(thresh) {
    pred_pos <- preds$cv_probability >= thresh
    tp <- sum(pred_pos & preds$frozen_binary == 1)
    fp <- sum(pred_pos & preds$frozen_binary == 0)
    fn <- sum(!pred_pos & preds$frozen_binary == 1)
    tn <- sum(!pred_pos & preds$frozen_binary == 0)
    dplyr::tibble(
      threshold = thresh,
      tpr = .safe_ratio(tp, tp + fn) %||% 0,
      fpr = .safe_ratio(fp, fp + tn) %||% 0
    )
  })

  ggplot2::ggplot(roc_data, ggplot2::aes(x = fpr, y = tpr)) +
    ggplot2::geom_line(color = "#a4388a", linewidth = 1) +
    ggplot2::geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "grey60") +
    ggplot2::annotate("text",
      x = 0.6, y = 0.3,
      label = sprintf("AUC = %.3f", classifier_results$auc),
      size = 5, color = "#a4388a", fontface = "bold"
    ) +
    ggplot2::scale_x_continuous(labels = scales::label_percent()) +
    ggplot2::scale_y_continuous(labels = scales::label_percent()) +
    ggplot2::labs(
      title    = "ROC Curve: Logistic Regression Freeze Classifier",
      subtitle = "5-fold cross-validated predictions vs. Grant Witness labels",
      x = "False Positive Rate", y = "True Positive Rate",
      caption  = "Source: Grant Witness labeled data + USAspending.gov"
    ) +
    theme_gw()
}

# --------------------------------------------------------------------------- #
# Save helper
# --------------------------------------------------------------------------- #

#' Save all calibration plots
#'
#' @param calibration_features Tibble from [compute_calibration_features()].
#' @param calibration_results List from [evaluate_heuristic()].
#' @param classifier_results List from [build_freeze_classifier()]. Optional.
#' @param out_dir Output directory.
#' @return Character vector of saved file paths.
#' @export
save_calibration_plots <- function(calibration_features, calibration_results,
                                   classifier_results = NULL, out_dir = "output") {
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

  plots <- list(
    threshold_sweep  = plot_threshold_sweep(calibration_results),
    confusion_heatmap = plot_confusion_heatmap(calibration_features),
    institution_perf  = plot_institution_performance(calibration_results)
  )

  # Only add plots that need data we may not have
  if (!is.null(classifier_results) && !is.null(classifier_results$model)) {
    plots$roc_curve <- plot_roc_curve(classifier_results)
  }

  # Temporal reconstruction requires File C data
  has_file_c <- any(!is.na(calibration_features$file_c_outlays_raw))
  if (has_file_c) {
    plots$temporal_timelines <- plot_temporal_reconstruction(calibration_features)
  }

  paths <- character(length(plots))
  for (i in seq_along(plots)) {
    path <- file.path(out_dir, paste0("cal_", names(plots)[i], ".png"))
    ggplot2::ggsave(path, plots[[i]], width = 10, height = 6, dpi = 150, bg = "white")
    paths[i] <- path
    log_event(sprintf("Saved calibration plot: %s", path))
  }

  paths
}
