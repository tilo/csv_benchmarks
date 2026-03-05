# frozen_string_literal: true
#
# config/chart.rb — Chart configuration for benchmarks/chart_versions.rb
#
# Edit this file to tune parameters, select adapters, or change the SmarterCSV
# versions that should be part of the chart.
#
# Two mutually exclusive chart types:
#
#   type: :versions  — compares SmarterCSV versions C-to-C and/or Ruby-to-Ruby.
#                      baseline = oldest version in the list.
#                      paths: [:c]       — C-accelerated only
#                      paths: [:rb]      — Ruby path only
#                      paths: [:c, :rb]  — both (default)
#
#   type: :adapters  — compares adapters against a specific SmarterCSV version
#                      (C accelerated). baseline_version + baseline_path must
#                      be present in version_timings of the results JSON.
#
# Usage:
#   ruby benchmarks/chart_versions.rb versions
#   ruby benchmarks/chart_versions.rb adapters results/2026-03-05_1430_ruby3.4.7.json
#   rake chart versions
#   rake chart adapters results/2026-03-05_1430_ruby3.4.7.json

module ChartConfig
  # Colors assigned to series in order (C-accelerated, Ruby path, additional versions…)
  SERIES_COLORS = %w[#1565C0 #BF360C #2E7D32 #6A1B9A #E65100 #00838F].freeze

  CHARTS = {
    "versions" => {
      title:    "SmarterCSV version improvements (C accelerated)",
      type:     :versions,
      paths:    [:c],        # :c, :rb, or both [:c, :rb]
      versions: %w[
        1.14.4
        1.15.2
        1.16.0
      ],
    },

    "adapters" => {
      title:            "Parser comparison vs SmarterCSV",
      type:             :adapters,
      # Baseline: SmarterCSV C-accelerated for this version
      baseline_version: "1.16.0",
      baseline_path:    :c,
      # Adapter names must match adapter #name in the results JSON
      adapters: [
        "ZSV + wrapper (smarter_csv-equivalent)",
        "SmarterCSV.process (no acceleration)",
        "CSV.table (symbol keys + numeric conversion)",
        "CSV.read (raw hashes, string keys)",
        "ZSV.read (raw arrays)",
        "CSV.read (raw arrays)",
      ],
    },
  }.freeze
end
