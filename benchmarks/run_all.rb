#!/usr/bin/env ruby
# frozen_string_literal: true
#
# benchmarks/run_all.rb — Run all available adapters against all csv_files/
#
# Saves raw timing results to results/YYYY-MM-DD_rubyX.Y.Z.json.
# To format results into Markdown tables, run:
#   ruby benchmarks/format_results.rb
#
# Usage:
#   ruby benchmarks/run_all.rb
#   bundle exec ruby benchmarks/run_all.rb

require "benchmark"
require "fileutils"
require "json"
require "csv"

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(root)

# ZSV: optional — load from local build if present
zsv_lib = File.join(Dir.home, "GitHub", "zsv-ruby", "lib")
$LOAD_PATH.unshift(zsv_lib) if Dir.exist?(zsv_lib) && !$LOAD_PATH.include?(zsv_lib)

require "adapters/ruby_csv/csv_read"
require "adapters/ruby_csv/csv_hashes"
require "adapters/ruby_csv/csv_table"
require "adapters/smarter_csv/default"
require "adapters/smarter_csv/ruby_path"
require "adapters/zsv/zsv_raw"
require "adapters/zsv/zsv_wrapped"

# ── Adapter registry ──────────────────────────────────────────────────────────

ALL_ADAPTERS = [
  Adapters::RubyCSV::CsvRead.new,
  Adapters::RubyCSV::CsvHashes.new,
  Adapters::RubyCSV::CsvTable.new,
  Adapters::SmarterCSVAdapter::Default.new,
  Adapters::SmarterCSVAdapter::RubyPath.new,
  Adapters::ZSV::ZsvRaw.new,
  Adapters::ZSV::ZsvWrapped.new,
].freeze

ADAPTERS = ALL_ADAPTERS.select(&:available?)

unavailable = ALL_ADAPTERS.reject(&:available?)
unavailable.each { |a| warn "SKIP: #{a.name} (not available)" }

# ── Benchmark parameters ──────────────────────────────────────────────────────

WARMUP     = 2
ITERATIONS = 10

# ── CSV file list ─────────────────────────────────────────────────────────────
#
# Scans csv_files/actual/ and csv_files/synthetic/ for .csv files.
# Excludes files that require non-default separators (multi-char, tab) since
# those are incompatible with default adapter options and with ZSV.
# Add them to a custom adapter + benchmark script if needed.

EXCLUDED_FILES = %w[
  multi_char_separator_20k.csv
  tab_separated_20k.tsv
].freeze

CSV_FILES = (
  Dir[File.join(root, "csv_files", "actual",    "*.csv")] +
  Dir[File.join(root, "csv_files", "synthetic", "*.csv")]
).reject { |f| EXCLUDED_FILES.include?(File.basename(f)) }.sort

if CSV_FILES.empty?
  warn "No CSV files found in csv_files/actual/ or csv_files/synthetic/."
  exit 1
end

# ── Helpers ───────────────────────────────────────────────────────────────────

def count_rows(filepath)
  # Fast physical-line count; accurate for files without embedded newlines.
  # For embedded_newlines_20k.csv this is approximate — acceptable for display.
  n = 0
  File.foreach(filepath) { n += 1 }
  [n - 1, 0].max
end

def timed_run(adapter, filepath)
  # Warmup — not measured; critical for C extensions (see project plan)
  WARMUP.times { adapter.call(filepath) }

  # Measured runs — take minimum to reduce GC/scheduler noise
  times = ITERATIONS.times.map do
    GC.start
    GC.compact rescue nil # Ruby 2.7+
    Benchmark.realtime { adapter.call(filepath) }
  end

  times.min
end

# ── Run benchmarks ────────────────────────────────────────────────────────────

# results[filename] = { _rows: N, adapter_name => { time:, rows_per_sec: }, ... }
results = {}

CSV_FILES.each do |filepath|
  filename = File.basename(filepath)
  rows     = count_rows(filepath)
  results[filename] = { _rows: rows }

  $stderr.print "Benchmarking #{filename} (#{rows} rows)..."
  $stderr.flush

  ADAPTERS.each do |adapter|
    begin
      t = timed_run(adapter, filepath)
      results[filename][adapter.name] = { time: t, rows_per_sec: rows / t }
    rescue StandardError => e
      warn "\n  ERROR running #{adapter.name} on #{filename}: #{e.message}"
      results[filename][adapter.name] = { time: nil, rows_per_sec: nil }
    end
  end

  $stderr.puts " done"
end

# ── Save JSON ─────────────────────────────────────────────────────────────────

smarter_version = SmarterCSV::VERSION rescue "?"

FileUtils.mkdir_p(File.join(root, "results"))
timestamp = Time.now.strftime("%Y-%m-%d")
ruby_tag  = "ruby#{RUBY_VERSION}"

json_path = File.join(root, "results", "#{timestamp}_#{ruby_tag}.json")
File.write(json_path, JSON.pretty_generate(
  ruby:           RUBY_VERSION,
  platform:       RUBY_PLATFORM,
  smarter_csv:    smarter_version,
  warmup:         WARMUP,
  iterations:     ITERATIONS,
  timestamp:      Time.now.strftime("%Y-%m-%d %H:%M:%S"),
  adapter_labels: ADAPTERS.each_with_object({}) { |a, h| h[a.name] = a.label },
  results:        results
))
puts "JSON saved to: #{json_path}"

symlink_path = File.join(root, "results", "latest.json")
File.delete(symlink_path) if File.symlink?(symlink_path)
File.symlink(File.basename(json_path), symlink_path)
puts "Symlink updated: results/latest.json -> #{File.basename(json_path)}"
