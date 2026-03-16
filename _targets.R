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
  "maps",       # state choropleth base data
  "mapproj",    # coord_map() projection support
  "tidyr",      # calibration analysis (unnest)
  "rlang"       # tidy evaluation (File C temporal features)
))

# Load custom functions
lapply(list.files("R", full.names = TRUE, pattern = "\\.R$"), source)

# Pipeline definition
list(
  # Phase 3: Scrape forensic data
  # .rds_or() reads data/raw/{name}.rds when present — no re-fetch on code changes.
  # Delete the .rds file (or run scripts/fetch_data.R --force <name>) to refresh.
  tar_target(notices_nih, .rds_or("notices_nih", scrape_nih)),
  tar_target(notices_nsf, .rds_or("notices_nsf", scrape_nsf)),

  # Phase 4: Pull official USAspending data
  tar_target(usaspending_awards, .rds_or("usaspending_awards", fetch_usaspending)),

  # Validate both datasets
  tar_target(
    validated_notices,
    validate_notices(dplyr::bind_rows(notices_nih, notices_nsf))
  ),
  tar_target(validated_awards, validate_awards(usaspending_awards)),

  # Join and identify discrepancies
  tar_target(discrepancies, join_and_flag(validated_notices, validated_awards)),
  tar_target(discrepancy_summary, summarize_discrepancies(discrepancies)),

  # Transaction-level data for all disruption-type grants (freeze + ADT)
  # Previously excluded active_despite_terminated, leaving ADT enrichment null.
  tar_target(
    transaction_data,
    fetch_transactions(
      discrepancies$grant_number[discrepancies$discrepancy_type %in% FREEZE_RELATED_DISCREPANCY_TYPES]
    )
  ),

  # Enrich discrepancies with transaction-level freeze confidence
  tar_target(
    discrepancies_enriched,
    enrich_with_transactions(discrepancies, transaction_data)
  ),

  # File C: period-by-period outlay data for temporal freeze reconstruction
  tar_target(file_c_probe, {
    # Probe with an HHS grant specifically (most grants are HHS/NIH)
    hhs_ids <- discrepancies$grant_number[
      !is.na(discrepancies$grant_number) &
        discrepancies$agency_name == "Department of Health and Human Services"
    ]
    probe_file_c_endpoint(hhs_ids[1])
  }),
  tar_target(file_c_data, {
    if (!file_c_probe$success) return(.empty_file_c_tibble())
    freeze_grants <- discrepancies_enriched |>
      dplyr::filter(discrepancy_type %in% FREEZE_RELATED_DISCREPANCY_TYPES)
    fetch_file_c(freeze_grants$grant_number,
                 agency_names = freeze_grants$agency_name)
  }),
  tar_target(targeting_lookup, build_targeting_lookup(gw_nih_data)),
  tar_target(
    file_c_features,
    compute_file_c_features(file_c_data, targeting_lookup, discrepancies_enriched)
  ),
  tar_target(
    discrepancies_file_c,
    enrich_with_file_c(discrepancies_enriched, file_c_features, file_c_data)
  ),

  # USAspending-recorded termination actions (action_type E/F in transaction data)
  # Independent confirmation of termination date, more precise than notice_date.
  tar_target(
    termination_actions,
    extract_termination_actions(transaction_data)
  ),

  # Reinstatement pattern detection: termination (E/F) followed by new activity (A/B/C/G)
  # Equivalent to GW's "Possibly Reinstated" category.
  tar_target(
    reinstatement_patterns,
    detect_reinstatement_pattern(transaction_data)
  ),

  # Visualize
  tar_target(
    plot_files,
    save_plots(validated_notices, discrepancies_file_c, discrepancy_summary),
    format = "file"
  ),

  # Export
  tar_target(
    export_parquet,
    {
      dir.create("output", showWarnings = FALSE)
      arrow::write_parquet(discrepancies_emergency, "output/discrepancies.parquet")
      "output/discrepancies.parquet"
    },
    format = "file"
  ),

  # Subaward data for downstream impact analysis
  tar_target(subaward_data, fetch_subawards()),
  tar_target(
    subaward_analysis,
    analyze_subaward_flow(subaward_data, discrepancies_file_c)
  ),

  # Per-prime-award subaward impact: count and obligation totals for terminated grants.
  # Quantifies downstream sub-recipient exposure without fetching individual records.
  tar_target(
    subaward_impact,
    fetch_subaward_impact(
      discrepancies_file_c$grant_number[
        discrepancies_file_c$discrepancy_type %in% FREEZE_RELATED_DISCREPANCY_TYPES
      ]
    )
  ),

  # Emergency fund flags: frozen grants that also carry COVID/IIJA def_codes.
  # Political targeting signal: research frozen but emergency funding continues.
  tar_target(
    discrepancies_emergency,
    enrich_with_emergency_flags(discrepancies_file_c, usaspending_awards)
  ),

  # De-obligation detection (early signal of fund clawbacks)
  tar_target(
    deobligation_summary,
    detect_deobligations(transaction_data)
  ),
  tar_target(
    deobligation_spikes,
    detect_deobligation_spikes(transaction_data, discrepancies)
  ),

  # Calibration: Grant Witness ground truth
  tar_target(gw_nih_data, .rds_or("gw_nih_data", fetch_gw_nih)),
  # gw_nsf_data: fetch_gw_nsf() — available but not wired yet (no NSF calibration target)
  tar_target(
    calibration_data,
    join_gw_usaspending(gw_nih_data, discrepancies_file_c)
  ),
  tar_target(
    calibration_features,
    compute_calibration_features(calibration_data)
  ),
  tar_target(
    calibration_results,
    evaluate_heuristic(calibration_features)
  ),
  tar_target(
    temporal_analysis,
    analyze_temporal_gap(calibration_features)
  ),
  tar_target(
    freeze_classifier,
    build_freeze_classifier(calibration_features)
  ),
  tar_target(
    calibration_plots,
    save_calibration_plots(calibration_features, calibration_results, freeze_classifier),
    format = "file"
  ),

  # CFDA program breakdown — which NSF/NIH programs are most affected (YoY)
  # Novel capability: GW tracks institution-level; this adds program-level targeting.
  # Requires two calls per agency (FY2025 baseline + FY2026 current).
  tar_target(
    cfda_breakdown,
    dplyr::bind_rows(
      # NSF FY2026
      fetch_cfda_breakdown(
        agency_spec = list(type = "awarding", tier = "toptier", name = "National Science Foundation"),
        start_date  = "2025-10-01"
      ),
      # NSF FY2025 (baseline)
      fetch_cfda_breakdown(
        agency_spec = list(type = "awarding", tier = "toptier", name = "National Science Foundation"),
        start_date  = "2024-10-01", end_date = "2025-09-30"
      ),
      # NIH FY2026
      fetch_cfda_breakdown(
        agency_spec = list(type = "awarding", tier = "subtier",
                           name = "National Institutes of Health",
                           toptier_name = "Department of Health and Human Services"),
        start_date  = "2025-10-01"
      ),
      # NIH FY2025 (baseline)
      fetch_cfda_breakdown(
        agency_spec = list(type = "awarding", tier = "subtier",
                           name = "National Institutes of Health",
                           toptier_name = "Department of Health and Human Services"),
        start_date  = "2024-10-01", end_date = "2025-09-30"
      )
    )
  ),

  # USAspending agency-level budget execution (GTAS-sourced, independent of award data)
  tar_target(
    agency_obligations,
    .rds_or("agency_obligations", fetch_agency_obligations,
            agency_toptier_codes = AGENCY_TOPTIER_CODES,
            fiscal_years = c(2023L, 2024L, 2025L, 2026L))
  ),

  # Award obligation flow — new grant actions per fiscal month (spending_over_time)
  # Complements GTAS stock signal with a transaction-level flow signal.
  # fiscal_period=1 means October (fiscal month 1), same convention as File C.
  tar_target(
    award_obligations_flow,
    .rds_or("award_obligations_flow", fetch_award_obligations_flow,
            agency_names = names(AGENCY_TOPTIER_CODES),
            fiscal_years = c(2024L, 2025L, 2026L))
  ),

  # Recipient-level grant compression — data-driven institution targeting detection.
  # Identifies which research institutions have anomalous FY2026 obligation drops
  # WITHOUT requiring a manually curated list (unlike GW's 8-institution approach).
  # Base rate: 1 institution at >-40% in a normal year vs 5 in FY2026.
  # Amounts = sum of federal_action_obligation actions in window (new awards +
  # continuation-year fundings + amendments). Not lifetime award face value.
  tar_target(
    recipient_compression,
    .rds_or("recipient_compression", function() {
      # baseline_end tracks today - 365 days so both windows are the same length.
      # Both NIH and NSF use the same cutoff to ensure comparable YoY metrics.
      baseline_end <- format(Sys.Date() - 365, "%Y-%m-%d")
      dplyr::bind_rows(
        fetch_recipient_compression(
          agency_spec    = list(type = "awarding", tier = "subtier",
                                name = "National Institutes of Health"),
          baseline_start = "2024-10-01",
          baseline_end   = baseline_end,
          current_start  = "2025-10-01"
        ),
        fetch_recipient_compression(
          agency_spec    = list(type = "awarding", tier = "toptier",
                                name = "National Science Foundation"),
          baseline_start = "2024-10-01",
          baseline_end   = baseline_end,
          current_start  = "2025-10-01"
        )
      )
    })
  )
)
