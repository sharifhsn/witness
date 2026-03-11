# _targets.R
# Grant Witness PoC Pipeline
#
# Orchestrates: scrape -> validate -> join -> export
# Run with: targets::tar_make()

library(targets)

# Source all R functions
tar_option_set(packages = c(
  "httr2", "dplyr", "stringr", "purrr", "tibble",
  "readr",      # scrape_nsf.R CSV parsing
  "assertr",    # validate.R schema enforcement
  "jsonlite",   # scrape_nih.R / fetch_usaspending.R API payloads
  "fuzzyjoin",  # transform.R fuzzy join
  "arrow",      # export target (Parquet)
  "ggplot2",    # visualize.R charts
  "scales",     # axis label formatting
  "maps"        # state choropleth base data
))

# Load custom functions
lapply(list.files("R", full.names = TRUE, pattern = "\\.R$"), source)

# Pipeline definition
list(
  # Phase 3: Scrape forensic data
  tar_target(notices_nih, scrape_nih()),
  tar_target(notices_nsf, scrape_nsf()),

  # Phase 4: Pull official USAspending data
  tar_target(usaspending_awards, fetch_usaspending()),

  # Validate both datasets
  tar_target(
    validated_notices,
    validate_notices(dplyr::bind_rows(notices_nih, notices_nsf))
  ),
  tar_target(validated_awards, validate_awards(usaspending_awards)),

  # Join and identify discrepancies
  tar_target(discrepancies, join_and_flag(validated_notices, validated_awards)),
  tar_target(discrepancy_summary, summarize_discrepancies(discrepancies)),

  # Visualize
  tar_target(
    plot_files,
    save_plots(validated_notices, discrepancies, discrepancy_summary),
    format = "file"
  ),

  # Export
  tar_target(
    export_parquet,
    {
      dir.create("output", showWarnings = FALSE)
      arrow::write_parquet(discrepancies, "output/discrepancies.parquet")
      "output/discrepancies.parquet"
    },
    format = "file"
  )
)
