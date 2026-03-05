#!/usr/bin/env ruby
# frozen_string_literal: true
#
# benchmarks/compare_parsers.rb — Run all adapters and format comparison tables.
#
# Saves timing results to results/YYYY-MM-DD_compare_rubyX.Y.Z.json,
# then invokes format_results.rb to produce Markdown tables.
#
# Usage:
#   ruby benchmarks/compare_parsers.rb
#   bundle exec ruby benchmarks/compare_parsers.rb

require "benchmark"
require "fileutils"
require "json"
require "csv"

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(root)

zsv_lib = File.join(Dir.home, "GitHub", "zsv-ruby", "lib")
$LOAD_PATH.unshift(zsv_lib) if Dir.exist?(zsv_lib) && !$LOAD_PATH.include?(zsv_lib)

require_relative "../config/benchmark"

# ── Activate the highest SmarterCSV version from config ───────────────────────

HIGHEST_VERSION = BenchmarkConfig::SMARTER_CSV_VERSIONS.max_by { |v| Gem::Version.new(v) }

if HIGHEST_VERSION
  begin
    gem "smarter_csv", HIGHEST_VERSION
  rescue Gem::MissingSpecVersionError, Gem::LoadError => e
    abort "ERROR: smarter_csv #{HIGHEST_VERSION} is not installed.\n" \
          "Install with: gem install smarter_csv -v #{HIGHEST_VERSION}"
  end
end

require "adapters/ruby_csv/csv_read"
require "adapters/ruby_csv/csv_hashes"
require "adapters/ruby_csv/csv_table"
require "adapters/smarter_csv/default"
require "adapters/smarter_csv/ruby_path"
require "adapters/zsv/zsv_raw"
require "adapters/zsv/zsv_wrapped"

# ── Adapter registry ──────────────────────────────────────────────────────────

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
ADAPTERS     = ALL_ADAPTERS.select(&:available?)

ALL_ADAPTERS.reject(&:available?).each { |a| warn "SKIP: #{a.name} (not available)" }

# ── Parameters ────────────────────────────────────────────────────────────────

WARMUP       = BenchmarkConfig::WARMUP
ITERATIONS   = BenchmarkConfig::ITERATIONS
FILE_OPTIONS = BenchmarkConfig::FILE_OPTIONS

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
  n = 0
  File.foreach(filepath) { n += 1 }
  [n - 1, 0].max
end

def timed_run(adapter, filepath, opts = {})
  WARMUP.times { adapter.call(filepath, **opts) }
  times = ITERATIONS.times.map do
    GC.start
    GC.compact rescue nil
    Benchmark.realtime { adapter.call(filepath, **opts) }
  end
  times.min
end

# ── Run benchmarks ────────────────────────────────────────────────────────────

results = {}

CSV_FILES.each_with_index do |filepath, i|
  filename  = File.basename(filepath)
  rows      = count_rows(filepath)
  file_opts = FILE_OPTIONS.fetch(filename, {})
  results[filename] = { _rows: rows }

  $stderr.print "[#{i + 1}/#{CSV_FILES.size}] #{filename} (#{rows} rows)..."
  $stderr.flush

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
csv_version     = CSV::VERSION rescue "?"
zsv_version     = (defined?(ZSV) ? ZSV::VERSION : "n/a") rescue "n/a"

FileUtils.mkdir_p(File.join(root, "results"))
timestamp = Time.now.strftime("%Y-%m-%d_%H%M")
ruby_tag  = "ruby#{RUBY_VERSION}"

json_path = File.join(root, "results", "#{timestamp}_compare_#{ruby_tag}.json")
File.write(json_path, JSON.pretty_generate(
  ruby:           RUBY_VERSION,
  platform:       RUBY_PLATFORM,
  smarter_csv:    smarter_version,
  csv:            csv_version,
  zsv:            zsv_version,
  warmup:         WARMUP,
  iterations:     ITERATIONS,
  timestamp:      Time.now.strftime("%Y-%m-%d %H:%M:%S"),
  adapter_labels: ADAPTERS.each_with_object({}) { |a, h| h[a.name] = a.label },
  results:        results
))
puts "JSON saved to: #{json_path}"

# ── Format results ────────────────────────────────────────────────────────────

format_script = File.join(root, "benchmarks", "format_results.rb")
system(RbConfig.ruby, format_script, json_path)
