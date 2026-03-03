#!/usr/bin/env ruby
# frozen_string_literal: true
#
# benchmarks/compare_parsers.rb — Fair-group head-to-head comparison
#
# Compares only the three adapters that produce equivalent output:
#   - CSV.table (smarter_csv-equivalent)
#   - SmarterCSV.process (C accelerated)       ← reference
#   - ZSV + wrapper (smarter_csv-equivalent)   ← optional
#
# "Fair" means all three return Array<Hash> with Symbol keys, numeric
# conversion, whitespace stripping, and empty-value removal — so timing
# differences reflect parser performance, not output differences.
#
# Usage:
#   ruby benchmarks/compare_parsers.rb
#   bundle exec ruby benchmarks/compare_parsers.rb

require "benchmark"
require "fileutils"
require "csv"

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(root)

zsv_lib = File.join(Dir.home, "GitHub", "zsv-ruby", "lib")
$LOAD_PATH.unshift(zsv_lib) if Dir.exist?(zsv_lib) && !$LOAD_PATH.include?(zsv_lib)

require_relative "../config/benchmark"

require "adapters/ruby_csv/csv_table"
require "adapters/smarter_csv/default"
require "adapters/zsv/zsv_wrapped"

# ── Fair-comparison adapter set ───────────────────────────────────────────────

FAIR_GROUP = [
  Adapters::RubyCSV::CsvTable.new,
  Adapters::SmarterCSVAdapter::Default.new,
  Adapters::ZSV::ZsvWrapped.new,
].select(&:available?).freeze

# Reference = SmarterCSV (C accelerated)
REFERENCE = FAIR_GROUP.find { |a| a.is_a?(Adapters::SmarterCSVAdapter::Default) }

abort "SmarterCSV adapter not available — cannot run comparison" unless REFERENCE

# ── Parameters ────────────────────────────────────────────────────────────────

WARMUP         = BenchmarkConfig::WARMUP
ITERATIONS     = BenchmarkConfig::ITERATIONS

EXCLUDED_FILES = BenchmarkConfig::EXCLUDE_FILES

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
  n = 0
  File.foreach(filepath) { n += 1 }
  [n - 1, 0].max
end

def timed_run(adapter, filepath)
  WARMUP.times { adapter.call(filepath) }
  times = ITERATIONS.times.map do
    GC.start
    GC.compact rescue nil
    Benchmark.realtime { adapter.call(filepath) }
  end
  times.min
end

# ── Banner ────────────────────────────────────────────────────────────────────

puts "=" * 100
puts "Fair-Group Comparison: #{FAIR_GROUP.map(&:name).join(' | ')}"
puts "Ruby #{RUBY_VERSION} [#{RUBY_PLATFORM}]  |  SmarterCSV #{SmarterCSV::VERSION}"
puts "Warmup: #{WARMUP}  |  Best of #{ITERATIONS} measured runs"
puts "All three adapters return: Array<Hash>, Symbol keys, numeric conversion, whitespace stripped"
puts "=" * 100
puts

# ── Run ───────────────────────────────────────────────────────────────────────

timings = {}

CSV_FILES.each do |filepath|
  filename = File.basename(filepath)
  rows     = count_rows(filepath)
  timings[filename] = { rows: rows, times: {} }

  $stderr.print "  #{filename} (#{rows} rows)..."
  $stderr.flush

  FAIR_GROUP.each do |adapter|
    t = timed_run(adapter, filepath)
    timings[filename][:times][adapter.name] = t
  end

  $stderr.puts " done"
end

# ── Results table ─────────────────────────────────────────────────────────────

ref_name = REFERENCE.name
name_w   = 36
time_w   = 10

puts
puts "## Results (seconds, best of #{ITERATIONS})\n\n"

header = "| #{"File".ljust(name_w)} | #{"Rows".rjust(7)} |"
FAIR_GROUP.each { |a| header += " #{a.name.slice(0, time_w).ljust(time_w)} |" }
header += " Smarter vs CSV.table | Smarter vs ZSV+wrap |" if FAIR_GROUP.size == 3
puts header

sep = "|#{'-' * (name_w + 2)}|#{'-' * 9}|"
FAIR_GROUP.each { sep += "#{'-' * (time_w + 2)}|" }
sep += "#{'-' * 23}|#{'-' * 22}|" if FAIR_GROUP.size == 3
puts sep

timings.each do |filename, data|
  rows   = data[:rows]
  times  = data[:times]

  row = "| #{filename.ljust(name_w)} | #{rows.to_s.rjust(7)} |"
  FAIR_GROUP.each do |adapter|
    t = times[adapter.name]
    row += " #{format('%.4fs', t).rjust(time_w)} |"
  end

  if FAIR_GROUP.size == 3
    csv_table_name = FAIR_GROUP.find { |a| a.is_a?(Adapters::RubyCSV::CsvTable) }&.name
    zsv_name       = FAIR_GROUP.find { |a| a.is_a?(Adapters::ZSV::ZsvWrapped) }&.name
    ref_t          = times[ref_name]

    if csv_table_name && (csv_t = times[csv_table_name]) && csv_t > 0
      ratio = csv_t / ref_t
      smarter_vs_csv = ratio >= 1 ? format("%.2f× faster", ratio) : format("%.2f× slower", 1.0 / ratio)
    else
      smarter_vs_csv = "N/A"
    end

    if zsv_name && (zsv_t = times[zsv_name]) && zsv_t > 0
      ratio = ref_t / zsv_t
      smarter_vs_zsv = ratio >= 1 ? format("SmarterCSV %.2f× slower", ratio) : format("SmarterCSV %.2f× faster", 1.0 / ratio)
    else
      smarter_vs_zsv = "N/A"
    end

    row += " #{smarter_vs_csv.ljust(21)} | #{smarter_vs_zsv.ljust(20)} |"
  end

  puts row
end

# ── Summary ───────────────────────────────────────────────────────────────────

puts
puts "## Summary\n"
puts
puts "Speedup = CSV.table time / SmarterCSV time  (>1 = SmarterCSV faster)"
puts

ref_t_total = 0.0
csv_t_total = 0.0

csv_table_name = FAIR_GROUP.find { |a| a.is_a?(Adapters::RubyCSV::CsvTable) }&.name

timings.each_value do |data|
  ref_t_total += data[:times][ref_name].to_f
  csv_t_total += data[:times][csv_table_name].to_f if csv_table_name
end

if csv_table_name && csv_t_total > 0
  overall = csv_t_total / ref_t_total
  puts "Overall: SmarterCSV is #{format('%.2f×', overall)} faster than CSV.table across all files"
end

puts
puts "*(Warmup: #{WARMUP} discarded runs. Measured: best of #{ITERATIONS}.)*"
puts "*(GC.start between each run. GC.compact where supported.)*"
if FAIR_GROUP.any? { |a| a.is_a?(Adapters::ZSV::ZsvWrapped) }
  puts "*(ZSV: GC disabled during calls — known zsv-ruby 1.3.1 GC bug on Ruby 3.4.x)*"
end
