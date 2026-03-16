#' @title Obligation Drought Visualizations
#' @description ggplot2 charts for the "obligation drought" — the collapse in
#'   new federal grant obligations invisible to GW's terminated-grant methodology.
#'   Uses `theme_gw()` from visualize.R.

# Fiscal period → calendar month label (period 1 = Oct)
.fiscal_period_labels <- c(
  "1"  = "Oct", "2"  = "Nov", "3"  = "Dec",
  "4"  = "Jan", "5"  = "Feb", "6"  = "Mar",
  "7"  = "Apr", "8"  = "May", "9"  = "Jun",
  "10" = "Jul", "11" = "Aug", "12" = "Sep"
)

# FY color palette — muted FY2023/2024 baseline, vibrant FY2025/2026
.fy_colors <- c(
  "FY2023" = "#cccccc",
  "FY2024" = "#aaaaaa",
  "FY2025" = "#570da0",
  "FY2026" = "#e38958"
)

#' Grouped bar chart of cumulative obligations by fiscal period
#'
#' Shows FY2024/2025/2026 cumulative obligation pace by fiscal period, faceted
#' by agency. The FY2026 collapse in Oct-Nov is the key signal.
#'
#' @param agency_obligations Tibble from `fetch_agency_obligations()`.
#' @param fiscal_years Integer vector of fiscal years to include. Default c(2024L, 2025L, 2026L).
#' @return A ggplot object.
#' @export
plot_obligation_drought <- function(
  agency_obligations,
  fiscal_years = c(2024L, 2025L, 2026L)
) {
  plot_data <- agency_obligations |>
    dplyr::filter(fiscal_year %in% fiscal_years) |>
    dplyr::mutate(
      fy_label     = paste0("FY", fiscal_year),
      period_label = factor(
        .fiscal_period_labels[as.character(fiscal_period)],
        levels = .fiscal_period_labels
      )
    )

  fy_levels <- paste0("FY", sort(fiscal_years))
  plot_data$fy_label <- factor(plot_data$fy_label, levels = fy_levels)
  colors <- .fy_colors[fy_levels]

  ggplot2::ggplot(
    plot_data,
    ggplot2::aes(x = period_label, y = obligations_cumulative / 1e3,
                 fill = fy_label)
  ) +
    ggplot2::geom_col(position = "dodge", width = 0.7) +
    ggplot2::facet_wrap(~agency, scales = "free_y", ncol = 1L) +
    ggplot2::scale_fill_manual(values = colors, name = "Fiscal Year") +
    ggplot2::scale_y_continuous(
      labels = scales::label_dollar(suffix = "B", scale = 1e-3)
    ) +
    ggplot2::labs(
      title    = "Federal Grant Obligation Pace: FY2026 vs. Baseline",
      subtitle = "Cumulative obligations by fiscal period. Orange = FY2026 collapse.",
      x = "Fiscal Period (Oct = start of FY)",
      y = "Cumulative Obligations ($B)",
      caption  = paste0(
        "Source: USAspending.gov budgetary resources (GTAS-certified) | ",
        "Grant Witness PoC"
      )
    ) +
    theme_gw()
}

#' Stacked horizontal bar chart of full disruption magnitude per agency
#'
#' The "iceberg" chart: GW-tracked terminations (bottom) plus the untracked
#' pipeline stall (top). Handle NA pipeline_gap_estimate gracefully.
#'
#' @param pipeline_gap Tibble from `compute_pipeline_gap()`.
#' @return A ggplot object.
#' @export
plot_pipeline_gap <- function(pipeline_gap) {
  # Long format for stacking: two segments per agency
  plot_data <- pipeline_gap |>
    dplyr::select(agency, gw_lost_funding, pipeline_gap_estimate) |>
    tidyr::pivot_longer(
      cols      = c(gw_lost_funding, pipeline_gap_estimate),
      names_to  = "segment",
      values_to = "amount_m"
    ) |>
    dplyr::filter(!is.na(amount_m), amount_m > 0) |>
    dplyr::mutate(
      segment_label = dplyr::case_when(
        segment == "gw_lost_funding"       ~ "GW-tracked terminations",
        segment == "pipeline_gap_estimate" ~ "Untracked pipeline stall",
        TRUE                               ~ segment
      ),
      segment_label = factor(
        segment_label,
        levels = c("GW-tracked terminations", "Untracked pipeline stall")
      ),
      # Shorten HHS label for display
      agency_short = dplyr::case_when(
        stringr::str_detect(agency, "Health and Human") ~ "HHS / NIH",
        TRUE ~ agency
      )
    )

  ggplot2::ggplot(
    plot_data,
    ggplot2::aes(x = amount_m, y = agency_short, fill = segment_label)
  ) +
    ggplot2::geom_col(width = 0.5) +
    ggplot2::scale_fill_manual(
      values = c(
        "GW-tracked terminations"  = "#570da0",
        "Untracked pipeline stall" = "#e38958"
      ),
      name = NULL
    ) +
    ggplot2::scale_x_continuous(labels = scales::label_dollar(suffix = "M")) +
    ggplot2::labs(
      title    = "The Obligation Iceberg: Visible vs. Hidden Disruption",
      subtitle = paste0(
        "Purple = formally terminated grants (GW-tracked). ",
        "Orange = obligation shortfall beyond formal terminations."
      ),
      x = "Funding Disruption ($M, cumulative through comparison period)",
      y = NULL,
      caption  = paste0(
        "GW figures: Grant Witness published data. ",
        "Untracked segment = YoY obligation shortfall minus GW-tracked terminations.\n",
        "Source: USAspending.gov GTAS + Grant Witness | Grant Witness PoC"
      )
    ) +
    theme_gw()
}

#' Daily withdrawal time series: current year vs. prior year
#'
#' Solid line = current year 7-day rolling withdrawal; dashed = prior year
#' same window shifted +365 days. Highlights divergence from baseline.
#'
#' @param dts_data Tibble from `fetch_dts_withdrawals()`.
#' @param agency Character scalar. Agency to plot. Default "National Institutes of Health".
#' @return A ggplot object.
#' @export
plot_dts_daily <- function(
  dts_data,
  agency = "National Institutes of Health"
) {
  agency_data <- dts_data |>
    dplyr::filter(.data$agency == !!agency) |>
    dplyr::arrange(record_date)

  if (nrow(agency_data) == 0L) {
    # Return empty plot with informative title
    return(
      ggplot2::ggplot() +
        ggplot2::labs(
          title    = sprintf("Daily Treasury Withdrawals: %s", agency),
          subtitle = "No data available for this agency",
          x = NULL, y = NULL
        ) +
        theme_gw()
    )
  }

  # Reconstruct daily increment
  plot_data <- agency_data |>
    dplyr::mutate(
      prev_mtd  = dplyr::lag(mtd_withdrawals, 1L),
      prev_date = dplyr::lag(record_date, 1L),
      same_month = !is.na(prev_date) &
        format(record_date, "%m") == format(prev_date, "%m") &
        format(record_date, "%Y") == format(prev_date, "%Y"),
      daily_increment = dplyr::if_else(
        same_month & !is.na(prev_mtd),
        mtd_withdrawals - prev_mtd,
        mtd_withdrawals
      ),
      roll7 = slider::slide_dbl(
        daily_increment, sum, na.rm = TRUE,
        .before = 6L, .after = 0L, .complete = FALSE
      )
    )

  # Prior-year overlay: shift current dates +365 to overlay on same axis
  prior_year_data <- plot_data |>
    dplyr::mutate(record_date = record_date + 365L) |>
    dplyr::select(record_date, prior_roll7 = roll7)

  combined <- plot_data |>
    dplyr::left_join(prior_year_data, by = "record_date")

  ggplot2::ggplot(combined, ggplot2::aes(x = record_date)) +
    ggplot2::geom_line(
      ggplot2::aes(y = prior_roll7),
      linetype = "dashed", color = "grey60", linewidth = 0.6, na.rm = TRUE
    ) +
    ggplot2::geom_line(
      ggplot2::aes(y = roll7),
      color = "#570da0", linewidth = 0.9, na.rm = TRUE
    ) +
    ggplot2::scale_y_continuous(labels = scales::label_dollar(suffix = "M")) +
    ggplot2::labs(
      title    = sprintf("Daily Treasury Withdrawals: %s", agency),
      subtitle = "Purple = current year (7-day rolling sum). Dashed = prior year.",
      x = NULL, y = "7-Day Rolling Daily Withdrawals ($M)",
      caption  = "Source: Daily Treasury Statement | Treasury Fiscal Data API | Grant Witness PoC"
    ) +
    theme_gw()
}

#' Monthly new grant award flow: current year vs. baseline
#'
#' Bar chart of new grant obligations per fiscal month (from spending_over_time),
#' faceted by agency. Shows the "flow" collapse: how many new grants were issued
#' each month vs. the prior year baseline. Complements the GTAS cumulative stock chart.
#'
#' @param award_obligations_flow Tibble from `fetch_award_obligations_flow()`.
#' @param fiscal_years Integer vector of fiscal years to plot. Default c(2025L, 2026L).
#' @return A ggplot object.
#' @export
plot_award_flow <- function(
  award_obligations_flow,
  fiscal_years = c(2025L, 2026L)
) {
  if (nrow(award_obligations_flow) == 0L) {
    return(
      ggplot2::ggplot() +
        ggplot2::labs(
          title    = "Monthly New Grant Award Flow",
          subtitle = "No data available",
          x = NULL, y = NULL
        ) +
        theme_gw()
    )
  }

  plot_data <- award_obligations_flow |>
    dplyr::filter(fiscal_year %in% fiscal_years) |>
    dplyr::mutate(
      fy_label     = paste0("FY", fiscal_year),
      period_label = factor(
        .fiscal_period_labels[as.character(fiscal_period)],
        levels = .fiscal_period_labels
      )
    )

  fy_levels <- paste0("FY", sort(fiscal_years))
  plot_data$fy_label <- factor(plot_data$fy_label, levels = fy_levels)
  colors <- .fy_colors[fy_levels]

  ggplot2::ggplot(
    plot_data,
    ggplot2::aes(x = period_label, y = monthly_grant_obligations / 1e6,
                 fill = fy_label)
  ) +
    ggplot2::geom_col(position = "dodge", width = 0.7) +
    ggplot2::facet_wrap(~agency, scales = "free_y", ncol = 1L) +
    ggplot2::scale_fill_manual(values = colors, name = "Fiscal Year") +
    ggplot2::scale_y_continuous(
      labels = scales::label_dollar(suffix = "M")
    ) +
    ggplot2::labs(
      title    = "New Grant Award Flow: FY2026 vs. FY2025",
      subtitle = "Monthly new grant obligations (transaction-level). Orange = FY2026 near-zero months.",
      x = "Fiscal Period (Oct = start of FY)",
      y = "New Grant Obligations ($M)",
      caption  = paste0(
        "Source: USAspending.gov spending_over_time (transaction-level, not cumulative) | ",
        "Grant Witness PoC"
      )
    ) +
    theme_gw()
}

#' Save obligation drought PNG plots
#'
#' @param agency_obligations Tibble from `fetch_agency_obligations()`.
#' @param pipeline_gap Tibble from `compute_pipeline_gap()`.
#' @param dts_data Tibble from `fetch_dts_withdrawals()`.
#' @param award_obligations_flow Optional tibble from `fetch_award_obligations_flow()`.
#'   If NULL or zero-row, the award flow chart is skipped.
#' @param out_dir Output directory. Default "output".
#' @return Character vector of saved file paths (for targets tracking).
#' @export
save_obligation_plots <- function(
  agency_obligations,
  pipeline_gap,
  dts_data,
  award_obligations_flow = NULL,
  out_dir = "output"
) {
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

  plots <- list(
    obligation_drought = plot_obligation_drought(agency_obligations),
    pipeline_gap       = plot_pipeline_gap(pipeline_gap),
    dts_nih_daily      = plot_dts_daily(dts_data, "National Institutes of Health"),
    dts_nsf_daily      = plot_dts_daily(dts_data, "National Science Foundation")
  )
  widths  <- c(12, 10, 10, 10)
  heights <- c(10,  6,  5,  5)

  if (!is.null(award_obligations_flow) && nrow(award_obligations_flow) > 0L) {
    plots[["award_flow"]] <- plot_award_flow(award_obligations_flow)
    widths  <- c(widths,  12)
    heights <- c(heights, 10)
  }

  paths <- character(length(plots))
  for (i in seq_along(plots)) {
    paths[i] <- file.path(out_dir, paste0(names(plots)[i], ".png"))
    ggplot2::ggsave(
      paths[i], plots[[i]],
      width = widths[i], height = heights[i],
      dpi = 150, bg = "white"
    )
    log_event(sprintf("Saved plot: %s", paths[i]))
  }

  paths
}
