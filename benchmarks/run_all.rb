#!/usr/bin/env ruby
# frozen_string_literal: true
#
# benchmarks/run_all.rb — Run all available adapters against all csv_files/
#
# Output: Markdown tables to STDOUT and results/YYYY-MM-DD_rubyX.Y.Z.md
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

# ── Output helpers ────────────────────────────────────────────────────────────

# Collect all output so it can be written to both STDOUT and the results file.
output_lines = []

def emit(line = "", output_lines)
  puts line
  output_lines << line
end

# ── Banner ────────────────────────────────────────────────────────────────────

smarter_version = SmarterCSV::VERSION rescue "?"

emit "# CSV Benchmarks", output_lines
emit "", output_lines
emit "- Date: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}", output_lines
emit "- Ruby: #{RUBY_VERSION} [#{RUBY_PLATFORM}]", output_lines
emit "- SmarterCSV: #{smarter_version}", output_lines
emit "- Warmup: #{WARMUP} iteration(s), Measured: best of #{ITERATIONS}", output_lines
emit "- Adapters: #{ADAPTERS.map(&:name).join(', ')}", output_lines
emit "", output_lines
if ADAPTERS.any? { |a| a.is_a?(Adapters::ZSV::ZsvRaw) || a.is_a?(Adapters::ZSV::ZsvWrapped) }
  emit "> **Note:** ZSV results have GC disabled during calls (zsv-ruby 1.3.1 GC bug", output_lines
  emit "> on Ruby 3.4.x). This gives ZSV a slight speed advantage — no GC pauses.", output_lines
  emit "", output_lines
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

# ── Reference adapter (SmarterCSV C-accelerated) ──────────────────────────────

ref_name = Adapters::SmarterCSVAdapter::Default.new.name

# ── Table helpers ─────────────────────────────────────────────────────────────

name_w = [36, CSV_FILES.map { |f| File.basename(f).length }.max].max
col_w  = 10

def table_header(name_w, col_w, adapters, extra_cols = [])
  row = "| #{"File".ljust(name_w)} | #{"Rows".rjust(7)} |"
  adapters.each { |a| row += " #{a.name.slice(0, col_w).ljust(col_w)} |" }
  extra_cols.each { |c| row += " #{c} |" }
  row
end

def table_sep(name_w, col_w, adapters, extra_cols = [])
  row = "|#{'-' * (name_w + 2)}|#{'-' * 9}|"
  adapters.each { row += "#{'-' * (col_w + 2)}|" }
  extra_cols.each { |c| row += "#{'-' * (c.length + 2)}|" }
  row
end

# ── Full Results table (seconds) ──────────────────────────────────────────────

emit "## Full Results (seconds, best of #{ITERATIONS} runs)\n", output_lines
emit table_header(name_w, col_w, ADAPTERS, ["vs SmarterCSV"]), output_lines
emit table_sep(name_w, col_w, ADAPTERS, ["vs SmarterCSV"]), output_lines

results.each do |filename, data|
  rows     = data[:_rows]
  ref_time = data.dig(ref_name, :time)

  row = "| #{filename.ljust(name_w)} | #{rows.to_s.rjust(7)} |"
  ADAPTERS.each do |adapter|
    t    = data.dig(adapter.name, :time)
    cell = t ? fmt_time(t) : "N/A"
    row += " #{cell.rjust(col_w)} |"
  end

  # Speedup column: each non-reference adapter's time relative to SmarterCSV
  if ref_time
    parts = ADAPTERS.reject { |a| a.name == ref_name }.filter_map do |adapter|
      t = data.dig(adapter.name, :time)
      next unless t && t > 0
      "#{adapter.name.slice(0, 12)}: #{speedup_label(ref_time, t)}"
    end
    speedup_cell = parts.empty? ? "ref" : parts.join(" | ")
  else
    speedup_cell = "N/A"
  end

  row += " #{speedup_cell} |"
  emit row, output_lines
end

emit "", output_lines

# ── Throughput table (rows/second) ────────────────────────────────────────────

emit "## Throughput (rows/second)\n", output_lines
emit table_header(name_w, col_w, ADAPTERS), output_lines
emit table_sep(name_w, col_w, ADAPTERS), output_lines

results.each do |filename, data|
  rows = data[:_rows]
  row  = "| #{filename.ljust(name_w)} | #{rows.to_s.rjust(7)} |"
  ADAPTERS.each do |adapter|
    t    = data.dig(adapter.name, :time)
    cell = t ? fmt_rows_per_sec(rows, t) : "N/A"
    row += " #{cell.rjust(col_w)} |"
  end
  emit row, output_lines
end

emit "", output_lines

# ── Save to file ──────────────────────────────────────────────────────────────

FileUtils.mkdir_p(File.join(root, "results"))
timestamp   = Time.now.strftime("%Y-%m-%d")
ruby_tag    = "ruby#{RUBY_VERSION}"

result_path = File.join(root, "results", "#{timestamp}_#{ruby_tag}.md")
File.write(result_path, output_lines.join("\n") + "\n")
puts "Results saved to: #{result_path}"

json_path = File.join(root, "results", "#{timestamp}_#{ruby_tag}.json")
File.write(json_path, JSON.pretty_generate(
  ruby:        RUBY_VERSION,
  platform:    RUBY_PLATFORM,
  smarter_csv: smarter_version,
  warmup:      WARMUP,
  iterations:  ITERATIONS,
  results:     results.transform_values { |v| v.reject { |k, _| k == :_rows } }
))
puts "JSON saved to:    #{json_path}"
