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

require_relative "../config/benchmark"

require "adapters/ruby_csv/csv_read"
require "adapters/ruby_csv/csv_hashes"
require "adapters/ruby_csv/csv_table"
require "adapters/smarter_csv/default"
require "adapters/smarter_csv/ruby_path"
require "adapters/zsv/zsv_raw"
require "adapters/zsv/zsv_wrapped"

# ── Adapter registry ──────────────────────────────────────────────────────────
#
# Keys match BenchmarkConfig::ADAPTERS entries.
# To add a new adapter: require it above, add an entry here, and add the key
# to BenchmarkConfig::ADAPTERS in config/benchmark.rb.

ADAPTER_REGISTRY = {
  "ruby_csv/csv_read"     => Adapters::RubyCSV::CsvRead.new,
  "ruby_csv/csv_hashes"   => Adapters::RubyCSV::CsvHashes.new,
  "ruby_csv/csv_table"    => Adapters::RubyCSV::CsvTable.new,
  "smarter_csv/default"   => Adapters::SmarterCSVAdapter::Default.new,
  "smarter_csv/ruby_path" => Adapters::SmarterCSVAdapter::RubyPath.new,
  "zsv/zsv_raw"           => Adapters::ZSV::ZsvRaw.new,
  "zsv/zsv_wrapped"       => Adapters::ZSV::ZsvWrapped.new,
}.freeze

ALL_ADAPTERS = BenchmarkConfig::ADAPTERS.filter_map { |key| ADAPTER_REGISTRY[key] }.freeze

ADAPTERS = ALL_ADAPTERS.select(&:available?)

unavailable = ALL_ADAPTERS.reject(&:available?)
unavailable.each { |a| warn "SKIP: #{a.name} (not available)" }

# ── Benchmark parameters ──────────────────────────────────────────────────────

WARMUP         = BenchmarkConfig::WARMUP
ITERATIONS     = BenchmarkConfig::ITERATIONS
FILE_OPTIONS   = BenchmarkConfig::FILE_OPTIONS

# ── CSV file list ─────────────────────────────────────────────────────────────
#
# Scans csv_files/actual/ and csv_files/synthetic/ for .csv and .tsv files.
# Adapters that cannot handle a file's separator declare accepts?(**opts) = false
# and are recorded as N/A for that file rather than being excluded globally.

CSV_FILES = (
  Dir[File.join(root, "csv_files", "actual",    "*.{csv,tsv}")] +
  Dir[File.join(root, "csv_files", "synthetic", "*.{csv,tsv}")]
).sort

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

def timed_run(adapter, filepath, opts = {})
  # Warmup — not measured; critical for C extensions (see project plan)
  WARMUP.times { adapter.call(filepath, **opts) }

  # Measured runs — take minimum to reduce GC/scheduler noise
  times = ITERATIONS.times.map do
    GC.start
    GC.compact rescue nil # Ruby 2.7+
    Benchmark.realtime { adapter.call(filepath, **opts) }
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

  file_opts = FILE_OPTIONS.fetch(filename, {})

  ADAPTERS.each do |adapter|
    unless adapter.accepts?(**file_opts)
      results[filename][adapter.name] = { time: nil, rows_per_sec: nil }
      next
    end
    begin
      t = timed_run(adapter, filepath, file_opts)
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
