#!/usr/bin/env ruby
# frozen_string_literal: true
#
# benchmarks/run_all.rb — Run all available adapters against all csv_files/
#
# Output: Markdown table to STDOUT and results/YYYY-MM-DD_rubyX.Y.Z.md
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
ITERATIONS = 6

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
  # For variation_embedded_newlines_20k.csv this is approximate — acceptable
  # for display purposes.
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

def fmt_time(t)
  format("%.4fs", t)
end

def fmt_rows_per_sec(rows, t)
  t > 0 ? format("%9.0f", rows / t) : "       N/A"
end

def speedup_label(ref_time, adapter_time)
  return "ref" if ref_time == adapter_time

  ratio = ref_time / adapter_time
  if ratio >= 1.0
    format("%.2f× faster", ratio)
  else
    format("%.2f× slower", 1.0 / ratio)
  end
end

# ── Banner ────────────────────────────────────────────────────────────────────

smarter_version = begin
  SmarterCSV::VERSION
rescue StandardError
  "?"
end

banner_lines = [
  "# CSV Benchmarks",
  "",
  "- Date: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}",
  "- Ruby: #{RUBY_VERSION} [#{RUBY_PLATFORM}]",
  "- SmarterCSV: #{smarter_version}",
  "- Warmup: #{WARMUP} iteration(s), Measured: best of #{ITERATIONS}",
  "- Adapters: #{ADAPTERS.map(&:name).join(', ')}",
  "",
  "> **Note:** ZSV results (when present) have GC disabled during calls due to",
  "> a known GC marking bug in zsv-ruby 1.3.1 on Ruby 3.4.x. This gives ZSV",
  "> a slight speed advantage (no GC pauses). All other adapters run with GC.",
  "",
]

puts banner_lines.join("\n")

# ── Run benchmarks ────────────────────────────────────────────────────────────

# results[file][adapter_name] = { time:, rows_per_sec: }
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

# ── Output tables ─────────────────────────────────────────────────────────────

# Reference adapter for speedup column
ref_adapter = Adapters::SmarterCSVAdapter::Default.new
ref_name    = ref_adapter.name

col_w    = 12
name_w   = 36

header = "| #{"File".ljust(name_w)} | #{"Rows".rjust(7)} |" +
         ADAPTERS.map { |a| " #{a.name.slice(0, col_w - 2).ljust(col_w - 2)} |" }.join +
         " vs SmarterCSV |"
sep    = "|#{'-' * (name_w + 2)}|#{'-' * 9}|" +
         ADAPTERS.map { "#{'-' * (col_w + 2)}|" }.join +
         "#{'-' * 16}|"

puts "## Full Results\n\n"
puts header
puts sep

results.each do |filename, data|
  rows     = data[:_rows]
  ref_time = data.dig(ref_name, :time)

  row = "| #{filename.ljust(name_w)} | #{rows.to_s.rjust(7)} |"
  ADAPTERS.each do |adapter|
    entry = data[adapter.name]
    cell  = entry&.dig(:time) ? fmt_time(entry[:time]) : "    N/A"
    row  += " #{cell.rjust(col_w - 2)} |"
  end

  speedup = ref_time ? speedup_label(ref_time, ref_time) : "N/A"
  row += " #{speedup.ljust(14)} |"
  puts row
end

puts "\n*(times = best of #{ITERATIONS} runs, seconds)*\n"

# ── Rows/second table ─────────────────────────────────────────────────────────

puts "\n## Throughput (rows/second)\n\n"
puts header.sub("| vs SmarterCSV |", "|")
puts sep.sub("#{'-' * 16}|", "")

results.each do |filename, data|
  rows = data[:_rows]
  row  = "| #{filename.ljust(name_w)} | #{rows.to_s.rjust(7)} |"
  ADAPTERS.each do |adapter|
    entry = data[adapter.name]
    cell  = entry&.dig(:rows_per_sec) ? format("%10.0f", entry[:rows_per_sec]) : "       N/A"
    row  += " #{cell.rjust(col_w - 2)} |"
  end
  puts row
end

# ── Save to file ──────────────────────────────────────────────────────────────

FileUtils.mkdir_p(File.join(root, "results"))
timestamp   = Time.now.strftime("%Y-%m-%d")
ruby_tag    = "ruby#{RUBY_VERSION}"
result_path = File.join(root, "results", "#{timestamp}_#{ruby_tag}.md")

# Capture all output to file as well (re-run output collection)
File.open(result_path, "w") do |f|
  f.puts banner_lines
  f.puts "*(Full output captured — re-run `ruby benchmarks/run_all.rb` for formatted tables)*"
  f.puts
  f.puts JSON.pretty_generate(
    ruby: RUBY_VERSION,
    platform: RUBY_PLATFORM,
    smarter_csv: smarter_version,
    warmup: WARMUP,
    iterations: ITERATIONS,
    results: results.transform_values { |v| v.reject { |k, _| k == :_rows } }
  )
end

puts "\nResults saved to: #{result_path}"
