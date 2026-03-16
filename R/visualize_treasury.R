#' @title Treasury Spending Visualizations
#' @description ggplot2 charts for Treasury MTS outlay data — agency timelines
#'   and anomaly corroboration with grant-level signals.

#' Line chart of monthly outlays by bureau, with anomaly highlights
#'
#' @param mts_data Tibble from `fetch_mts_outlays()`.
#' @param anomalies Tibble with `anomaly_flag`, `bureau`, `record_date` columns.
#' @return A ggplot object.
#' @export
plot_agency_outlays_timeline <- function(mts_data, anomalies) {
  anomaly_dates <- anomalies |>
    dplyr::filter(anomaly_flag == TRUE) |>
    dplyr::select(bureau, record_date) |>
    dplyr::mutate(is_anomaly = TRUE)

  plot_data <- mts_data |>
    dplyr::left_join(anomaly_dates, by = c("bureau", "record_date")) |>
    dplyr::mutate(is_anomaly = dplyr::coalesce(is_anomaly, FALSE))

  # Prior-year overlay (365-day offset avoids leap-year NA on month-end dates)
  prior_year <- mts_data |>
    dplyr::mutate(record_date = record_date + 365L) |>
    dplyr::select(bureau, record_date, month_outlays)

  ggplot2::ggplot(plot_data, ggplot2::aes(x = record_date, y = month_outlays / 1e6)) +
    ggplot2::geom_line(
      data = prior_year,
      ggplot2::aes(x = record_date, y = month_outlays / 1e6),
      linetype = "dashed", color = "grey60", linewidth = 0.5
    ) +
    ggplot2::geom_line(color = "#570da0", linewidth = 0.8) +
    ggplot2::geom_point(
      data = plot_data |> dplyr::filter(is_anomaly),
      color = "#e38958", size = 3, shape = 18
    ) +
    ggplot2::facet_wrap(~bureau, scales = "free_y", ncol = 2) +
    ggplot2::scale_y_continuous(labels = scales::label_dollar(suffix = "M")) +
    ggplot2::labs(
      title    = "Monthly Federal Outlays by Bureau",
      subtitle = "Orange diamonds = anomalous months. Dashed = prior year.",
      x = NULL, y = "Monthly Gross Outlays ($M)",
      caption  = "Source: Treasury Fiscal Data \u2014 MTS Table 5 | Grant Witness PoC"
    ) +
    theme_gw()
}

#' Scatter of Treasury anomaly magnitude vs grant-level freeze signals
#'
#' @param anomalies_enriched Tibble from `cross_reference_anomalies()`.
#' @return A ggplot object.
#' @export
plot_anomaly_corroboration <- function(anomalies_enriched) {
  plot_data <- anomalies_enriched |>
    dplyr::filter(anomaly_flag == TRUE, !is.na(corroboration_score))

  ggplot2::ggplot(
    plot_data,
    ggplot2::aes(x = pct_change_mom, y = corroboration_score,
                 color = bureau, size = month_outlays / 1e6)
  ) +
    ggplot2::geom_point(alpha = 0.7) +
    ggplot2::scale_x_continuous(labels = scales::label_percent()) +
    ggplot2::scale_y_continuous(labels = scales::label_percent()) +
    ggplot2::scale_size_continuous(name = "Monthly Outlays ($M)", range = c(2, 8)) +
    ggplot2::scale_color_viridis_d(option = "plasma", name = "Bureau") +
    ggplot2::labs(
      title    = "Treasury Anomaly vs. Grant-Level Freeze Signals",
      subtitle = "Do macro spending drops correlate with our grant-level freeze flags?",
      x = "Month-over-Month Outlay Change",
      y = "Grant Distress Rate (freeze + terminated / total)",
      caption  = "Source: Treasury MTS + USAspending.gov | Grant Witness PoC"
    ) +
    theme_gw()
}

#' Save Treasury visualization PNGs
#'
#' @param mts_data Tibble from `fetch_mts_outlays()`.
#' @param anomalies_enriched Tibble from `cross_reference_anomalies()`.
#' @param out_dir Output directory. Default "output".
#' @return Character vector of saved file paths (for targets tracking).
#' @export
save_treasury_plots <- function(mts_data, anomalies_enriched, out_dir = "output") {
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

  plots <- list(
    treasury_outlays_timeline     = plot_agency_outlays_timeline(mts_data, anomalies_enriched),
    treasury_anomaly_corroboration = plot_anomaly_corroboration(anomalies_enriched)
  )

  paths <- character(length(plots))
  for (i in seq_along(plots)) {
    paths[i] <- file.path(out_dir, paste0(names(plots)[i], ".png"))
    ggplot2::ggsave(
      paths[i], plots[[i]],
      width = ifelse(i == 1L, 12, 10), height = ifelse(i == 1L, 8, 6),
      dpi = 150, bg = "white"
    )
    log_event(sprintf("Saved plot: %s", paths[i]))
  }

  paths
}
