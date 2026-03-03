# frozen_string_literal: true
#
# config/benchmark.rb — Central configuration for all benchmark scripts.
#
# Edit this file to tune parameters, select adapters, or change the SmarterCSV
# versions compared by `rake versions`.

module BenchmarkConfig
  # ── Timing parameters ───────────────────────────────────────────────────────

  WARMUP     = 2   # discarded warm-up runs before measurement
  ITERATIONS = 8  # number of measured runs; minimum time is reported

  # ── Per-file options ────────────────────────────────────────────────────────
  #
  # Options passed to each adapter when processing a specific file.
  # Adapters that cannot handle the options (e.g. ZSV with non-comma separators)
  # will skip the file and record N/A.

  FILE_OPTIONS = {
    "multi_char_separator_20k.csv" => { col_sep: "::" },
    "tab_separated_20k.tsv"        => { col_sep: "\t" },
  }.freeze

  # ── Adapter list (for rake bench) ───────────────────────────────────────────
  #
  # Comment out any adapter to skip it.
  # Keys must match ADAPTER_REGISTRY in benchmarks/run_all.rb.

  ADAPTERS = %w[
    ruby_csv/csv_read
    ruby_csv/csv_hashes
    ruby_csv/csv_table
    smarter_csv/default
    smarter_csv/ruby_path
    zsv/zsv_raw
    zsv/zsv_wrapped
  ].freeze

  # ── SmarterCSV versions (for rake versions) ─────────────────────────────────
  #
  # Install each version first:
  #   gem install smarter_csv -v X.Y.Z
  # Override at runtime: VERSIONS=1.14.4,1.16.0 rake versions

  SMARTER_CSV_VERSIONS = %w[
    1.14.4
    1.15.2
    1.16.0
  ].freeze
end
