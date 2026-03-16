#' @title Grant Witness PoC Visualizations
#' @description ggplot2 chart generators matching the Grant Witness visual style:
#'   viridis palette, minimal theme, white backgrounds, high information density.

# ---------------------------------------------------------------------------
# Theme — mirrors GW's clean academic-portal aesthetic
# ---------------------------------------------------------------------------

#' Base ggplot2 theme matching Grant Witness style
#' @return A ggplot2 theme object.
#' @export
theme_gw <- function() {
  ggplot2::theme_minimal(base_size = 13, base_family = "") +
    ggplot2::theme(
      plot.title       = ggplot2::element_text(face = "bold", size = 16, margin = ggplot2::margin(b = 8)),
      plot.subtitle    = ggplot2::element_text(color = "grey40", size = 11, margin = ggplot2::margin(b = 12)),
      plot.caption     = ggplot2::element_text(color = "grey50", size = 8, hjust = 0),
      panel.grid.major.y = ggplot2::element_line(color = "grey90"),
      panel.grid.major.x = ggplot2::element_blank(),
      panel.grid.minor   = ggplot2::element_blank(),
      axis.title       = ggplot2::element_text(size = 10, color = "grey30"),
      axis.text        = ggplot2::element_text(size = 9),
      legend.position  = "bottom",
      legend.title     = ggplot2::element_text(size = 9),
      plot.background  = ggplot2::element_rect(fill = "white", color = NA),
      panel.background = ggplot2::element_rect(fill = "white", color = NA)
    )
}

# GW accent colors for discrepancy types
GW_DISCREPANCY_COLORS <- c(
  "active_despite_terminated" = "#e38958",
  "possible_freeze"           = "#a4388a",
  "possible_freeze_no_data"   = "#c979b0",
  "untracked"                 = "#570da0",
  "normal"                    = "#cccccc"
)

# ---------------------------------------------------------------------------
# Plot 1: NIH Institute bar chart
# ---------------------------------------------------------------------------

#' Bar chart of NIH institutes by inactive grant count
#'
#' @param notices Validated notices tibble (includes NIH institute field).
#' @param top_n Number of institutes to show. Default 15.
#' @return A ggplot object.
#' @export
plot_institute_bars <- function(notices, top_n = 15L) {
  inst_data <- notices |>
    dplyr::filter(agency_name == "NIH", !is.na(institute)) |>
    dplyr::group_by(institute) |>
    dplyr::summarise(
      n_grants     = dplyr::n(),
      total_amount = sum(award_amount, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::slice_max(n_grants, n = top_n) |>
    dplyr::mutate(institute = stats::reorder(institute, n_grants))

  ggplot2::ggplot(inst_data, ggplot2::aes(x = n_grants, y = institute, fill = total_amount)) +
    ggplot2::geom_col() +
    ggplot2::scale_fill_viridis_c(
      option = "plasma", labels = scales::label_dollar(scale = 1e-6, suffix = "M"),
      name = "Total Award Amount"
    ) +
    ggplot2::labs(
      title    = "NIH Institutes by Terminated Grant Count",
      subtitle = "Colored by total award dollar exposure",
      x = "Number of Grants", y = NULL,
      caption  = "Source: NIH Reporter API | Grant Witness PoC"
    ) +
    theme_gw()
}

# ---------------------------------------------------------------------------
# Plot 2: Discrepancy type breakdown
# ---------------------------------------------------------------------------

#' Stacked bar chart of discrepancy types by agency
#'
#' @param summary_df Tibble from summarize_discrepancies().
#' @return A ggplot object.
#' @export
plot_discrepancy_summary <- function(summary_df) {
  plot_data <- summary_df |>
    dplyr::mutate(
      discrepancy_label = dplyr::case_when(
        discrepancy_type == "active_despite_terminated" ~ "Active Despite Terminated",
        discrepancy_type == "possible_freeze"           ~ "Possible Freeze",
        discrepancy_type == "possible_freeze_no_data"   ~ "Possible Freeze (No Data)",
        discrepancy_type == "untracked"                 ~ "Untracked",
        TRUE                                            ~ discrepancy_type
      )
    )

  ggplot2::ggplot(
    plot_data,
    ggplot2::aes(x = total_award_amount, y = agency_name, fill = discrepancy_label)
  ) +
    ggplot2::geom_col(position = "stack") +
    ggplot2::scale_fill_manual(values = c(
      "Active Despite Terminated" = "#e38958",
      "Possible Freeze"           = "#a4388a",
      "Possible Freeze (No Data)" = "#c979b0",
      "Untracked"                 = "#570da0"
    ), name = "Discrepancy Type") +
    ggplot2::scale_x_continuous(labels = scales::label_dollar(scale_cut = scales::cut_short_scale())) +
    ggplot2::labs(
      title    = "Federal Grant Discrepancies by Agency",
      subtitle = "Dollar exposure by discrepancy type (excludes normal matches)",
      x = "Total Award Amount", y = NULL,
      caption  = "Source: USAspending.gov + NIH Reporter + NSF | Grant Witness PoC"
    ) +
    theme_gw()
}

# ---------------------------------------------------------------------------
# Plot 3: Obligation vs Outlay scatter
# ---------------------------------------------------------------------------

#' Scatter plot of award amount vs outlay ratio, colored by discrepancy type
#'
#' @param discrepancies Tibble from join_and_flag().
#' @return A ggplot object.
#' @export
plot_outlay_scatter <- function(discrepancies) {
  plot_data <- discrepancies |>
    dplyr::filter(!is.na(outlay_ratio), !is.na(award_amount), award_amount > 0) |>
    dplyr::mutate(
      discrepancy_label = dplyr::case_when(
        discrepancy_type == "active_despite_terminated" ~ "Active Despite Terminated",
        discrepancy_type == "possible_freeze"           ~ "Possible Freeze",
        discrepancy_type == "possible_freeze_no_data"   ~ "Possible Freeze (No Data)",
        discrepancy_type == "untracked"                 ~ "Untracked",
        TRUE                                            ~ "Normal"
      )
    )

  ggplot2::ggplot(
    plot_data,
    ggplot2::aes(x = award_amount, y = outlay_ratio, color = discrepancy_label)
  ) +
    ggplot2::geom_point(alpha = 0.6, size = 2) +
    ggplot2::scale_color_manual(values = c(
      "Active Despite Terminated" = "#e38958",
      "Possible Freeze"           = "#a4388a",
      "Possible Freeze (No Data)" = "#c979b0",
      "Untracked"                 = "#570da0",
      "Normal"                    = "#cccccc"
    ), name = "Discrepancy Type") +
    ggplot2::scale_x_continuous(labels = scales::label_dollar(scale_cut = scales::cut_short_scale())) +
    ggplot2::scale_y_continuous(labels = scales::label_percent()) +
    ggplot2::geom_hline(yintercept = 0.10, linetype = "dashed", color = "grey50", linewidth = 0.5) +
    ggplot2::annotate("text", x = Inf, y = 0.12, label = "Freeze threshold (10%)",
                      hjust = 1.1, size = 3, color = "grey50") +
    ggplot2::labs(
      title    = "Award Amount vs. Outlay Ratio",
      subtitle = "Grants below the dashed line may be frozen in practice",
      x = "Award Amount", y = "Outlay Ratio (Disbursed / Obligated)",
      caption  = "Source: USAspending.gov | Grant Witness PoC"
    ) +
    theme_gw()
}

# ---------------------------------------------------------------------------
# Plot 4: State-level heatmap (NIH only — has org_state)
# ---------------------------------------------------------------------------

#' US state choropleth of disrupted grants
#'
#' @param notices Validated notices tibble (has org_state from NIH).
#' @return A ggplot object.
#' @export
plot_state_map <- function(notices) {
  state_data <- notices |>
    dplyr::filter(!is.na(org_state), nchar(org_state) == 2L) |>
    dplyr::group_by(state_abbr = org_state) |>
    dplyr::summarise(
      n_grants     = dplyr::n(),
      total_amount = sum(award_amount, na.rm = TRUE),
      .groups = "drop"
    )

  # Map abbreviations to lowercase full names for ggplot2::map_data
  state_lookup <- dplyr::tibble(
    state_abbr = datasets::state.abb,
    region     = tolower(datasets::state.name)
  )

  map_df <- ggplot2::map_data("state") |>
    dplyr::left_join(state_lookup, by = "region") |>
    dplyr::left_join(state_data, by = "state_abbr")

  ggplot2::ggplot(map_df, ggplot2::aes(x = long, y = lat, group = group, fill = n_grants)) +
    ggplot2::geom_polygon(color = "white", linewidth = 0.3) +
    ggplot2::scale_fill_viridis_c(
      option = "plasma", name = "Disrupted Grants",
      na.value = "grey95"
    ) +
    ggplot2::coord_map("albers", lat0 = 29.5, lat1 = 45.5) +
    ggplot2::labs(
      title    = "Geographic Distribution of Disrupted Grants",
      subtitle = "State-level count of terminated or frozen grants",
      caption  = "Source: NIH Reporter API | Grant Witness PoC"
    ) +
    theme_gw() +
    ggplot2::theme(
      axis.text  = ggplot2::element_blank(),
      axis.title = ggplot2::element_blank(),
      panel.grid = ggplot2::element_blank()
    )
}

# ---------------------------------------------------------------------------
# Plot 5: Freeze severity — elapsed_ratio vs outlay_ratio for possible_freeze
# ---------------------------------------------------------------------------

#' Freeze severity scatter: how far through the award period vs how much was spent
#'
#' Each point is a "possible_freeze" grant. The most alarming grants are in the
#' top-right (nearly expired period, near-zero outlays). Sized by award amount.
#'
#' @param discrepancies Tibble from join_and_flag().
#' @return A ggplot object.
#' @export
plot_freeze_severity <- function(discrepancies) {
  plot_data <- discrepancies |>
    dplyr::filter(
      discrepancy_type %in% c("possible_freeze", "possible_freeze_no_data"),
      !is.na(elapsed_ratio),
      !is.na(outlay_ratio),
      !is.na(award_amount)
    ) |>
    dplyr::mutate(
      # Highlight the most alarming quadrant: >50% elapsed, <10% outlaid
      severity = dplyr::if_else(
        elapsed_ratio > 0.5 & outlay_ratio < FREEZE_RATIO_THRESHOLD,
        "High Urgency", "Lower Urgency"
      )
    )

  ggplot2::ggplot(
    plot_data,
    ggplot2::aes(x = elapsed_ratio, y = outlay_ratio,
                 size = award_amount, color = severity)
  ) +
    ggplot2::geom_point(alpha = 0.5) +
    ggplot2::scale_color_manual(
      values = c("High Urgency" = "#e38958", "Lower Urgency" = "#a4388a"),
      name = "Freeze Urgency"
    ) +
    ggplot2::scale_size_continuous(
      labels = scales::label_dollar(scale_cut = scales::cut_short_scale()),
      name = "Award Amount", range = c(1, 6)
    ) +
    ggplot2::scale_x_continuous(labels = scales::label_percent(), limits = c(0, 1)) +
    ggplot2::scale_y_continuous(labels = scales::label_percent(), limits = c(0, 1)) +
    ggplot2::geom_vline(xintercept = 0.5, linetype = "dashed", color = "grey60", linewidth = 0.4) +
    ggplot2::geom_hline(yintercept = FREEZE_RATIO_THRESHOLD,
                        linetype = "dashed", color = "grey60", linewidth = 0.4) +
    ggplot2::annotate("text", x = 0.75, y = 0.03,
                      label = "High urgency:\n>50% elapsed,\n<10% outlaid",
                      size = 3, color = "#e38958", hjust = 0.5) +
    ggplot2::labs(
      title    = "Freeze Severity: Award Period Elapsed vs. Disbursement",
      subtitle = "Possible-freeze grants — upper-right quadrant is most alarming",
      x = "Fraction of Award Period Elapsed",
      y = "Outlay Ratio (Disbursed / Obligated)",
      caption  = "Source: USAspending.gov | Grant Witness PoC"
    ) +
    theme_gw()
}

# ---------------------------------------------------------------------------
# Save helper — called by targets
# ---------------------------------------------------------------------------

#' Save all visualization PNGs to the output directory
#'
#' @param notices Validated notices tibble (has institute, org_state from NIH).
#' @param discrepancies Tibble from join_and_flag().
#' @param summary_df Tibble from summarize_discrepancies().
#' @param out_dir Output directory for PNG files.
#' @return Character vector of saved file paths (for targets tracking).
#' @export
save_plots <- function(notices, discrepancies, summary_df, out_dir = "output") {
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

  plots <- list(
    institute_bars     = plot_institute_bars(notices),
    discrepancy_summary = plot_discrepancy_summary(summary_df),
    outlay_scatter     = plot_outlay_scatter(discrepancies),
    state_map          = plot_state_map(notices),
    freeze_severity    = plot_freeze_severity(discrepancies)
  )

  paths <- character(length(plots))
  for (i in seq_along(plots)) {
    path <- file.path(out_dir, paste0(names(plots)[i], ".png"))
    ggplot2::ggsave(
      path, plots[[i]],
      width = 10, height = 6, dpi = 150, bg = "white"
    )
    paths[i] <- path
    log_event(sprintf("Saved plot: %s", path))
  }

  paths
}
