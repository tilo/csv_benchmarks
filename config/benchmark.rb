# frozen_string_literal: true
#
# config/benchmark.rb — Single source of truth for all benchmark configuration.
#
# Edit this file to tune parameters, select adapters, or change the SmarterCSV
# versions compared by `rake versions`.
#
# Runtime overrides via environment variables:
#   ADAPTERS=smarter_csv/default,zsv/zsv_wrapped ruby benchmarks/run_all.rb
#   VERSIONS=1.15.2,1.16.0                       ruby benchmarks/smarter_csv_versions.rb

module BenchmarkConfig
  # ── Timing parameters ───────────────────────────────────────────────────────

  WARMUP     = 2   # discarded warm-up runs before measurement
  ITERATIONS = 40  # number of measured runs; all samples stored, reported value
                   # is computed via STATS_METHOD env var (default: :p10).
                   # Supported: min, p5, p10, median, best_window5.

  # ── Per-file options ────────────────────────────────────────────────────────
  #
  # Options passed to each adapter when processing a specific file.
  # Adapters that cannot handle the options declare accepts?(**opts) = false
  # and are recorded as N/A for that file.

  FILE_OPTIONS = {
    "multi_char_separator_20k.csv" => { col_sep: "::" },
    "tab_separated_20k.tsv"        => { col_sep: "\t" },
  }.freeze

  # ── Adapter list ────────────────────────────────────────────────────────────
  #
  # Default: all adapters. Override at runtime with ADAPTERS=key1,key2.
  # Keys must match ADAPTER_REGISTRY in benchmarks/run_all.rb.
  # Comment out any line below to permanently disable an adapter.

   ADAPTERS = (
     ENV["ADAPTERS"]&.split(",")&.map(&:strip) || %w[
     ]
   ).freeze

   # ADAPTERS = (
   #   ENV["ADAPTERS"]&.split(",")&.map(&:strip) || %w[
   #    ruby_csv/csv_read
   #    ruby_csv/csv_hashes
   #    smarter_csv/default
   #    smarter_csv/ruby_path
   #   ]
   # ).freeze

 # ADAPTERS = (
 #    ENV["ADAPTERS"]&.split(",")&.map(&:strip) || %w[
 #      ruby_csv/csv_read
 #      ruby_csv/csv_hashes
 #      ruby_csv/csv_table
 #      smarter_csv/default
 #      smarter_csv/ruby_path
 #      zsv/zsv_raw
 #      zsv/zsv_wrapped
 #    ]
 #  ).freeze

  # ── SmarterCSV versions ──────────────────────────────────────────────────────
  #
  # Used by benchmarks/smarter_csv_versions.rb for side-by-side comparison.
  # Each version must be installed first: gem install smarter_csv -v X.Y.Z
  # Override at runtime with VERSIONS=1.15.2,1.16.0.

  SMARTER_CSV_VERSIONS = (
    ENV["VERSIONS"]&.split(",")&.map(&:strip) || %w[
      1.14.4
      1.15.0
      1.15.2
      1.16.0
      1.16.4
      1.17.0.pre8
      1.17.0.pre9
    ]
  ).freeze
end
