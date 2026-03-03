#!/usr/bin/env ruby
# frozen_string_literal: true
#
# benchmarks/smarter_csv_versions.rb — Side-by-side SmarterCSV version comparison
#
# Each version is loaded in an isolated subprocess via fork() so multiple gem
# versions can coexist in a single benchmark run without requiring Bundler tricks.
#
# Prerequisites: install the versions you want to compare:
#   gem install smarter_csv -v 1.14.4
#   gem install smarter_csv -v 1.15.2
#   gem install smarter_csv -v 1.16.0
#
# Usage:
#   ruby benchmarks/smarter_csv_versions.rb
#   VERSIONS=1.14.4,1.15.2 ruby benchmarks/smarter_csv_versions.rb

require "json"
require "tmpdir"
require "fileutils"
require "csv"

root = File.expand_path("..", __dir__)

require_relative "../config/benchmark"

# ── Version list ──────────────────────────────────────────────────────────────

VERSIONS     = (ENV["VERSIONS"]&.split(",")&.map(&:strip) || BenchmarkConfig::SMARTER_CSV_VERSIONS).freeze
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

# ── Per-version subprocess ────────────────────────────────────────────────────

puts "=" * 90
puts "SmarterCSV Multi-Version Comparison"
puts "Ruby #{RUBY_VERSION} [#{RUBY_PLATFORM}]"
puts "Versions: #{VERSIONS.join(', ')}"
puts "Warmup: #{WARMUP}  |  Best of #{ITERATIONS} measured runs"
puts "=" * 90
puts

all_results = {}

VERSIONS.each do |version|
  tmp_path = File.join(Dir.tmpdir, "csv_bench_#{version}_#{Process.pid}.json")

  $stderr.puts "Benchmarking SmarterCSV #{version}..."

  pid = fork do
    # Activate exactly this version in the subprocess
    begin
      gem "smarter_csv", version
    rescue Gem::MissingSpecVersionError, Gem::LoadError => e
      $stderr.puts "  ERROR: #{e.message}"
      $stderr.puts "  Install with: gem install smarter_csv -v #{version}"
      File.write(tmp_path, JSON.generate({ version: version, error: e.message, timings: {} }))
      exit 1
    end

    require "smarter_csv"
    require "benchmark"

    timings = {}

    CSV_FILES.each do |filepath|
      filename = File.basename(filepath)

      file_opts = FILE_OPTIONS.fetch(filename, {})

      begin
        WARMUP.times { SmarterCSV.process(filepath, file_opts) }

        best = ITERATIONS.times.map do
          GC.start
          GC.compact rescue nil
          Benchmark.realtime { SmarterCSV.process(filepath, file_opts) }
        end.min

        timings[filename] = best
        $stderr.print "."
        $stderr.flush
      rescue StandardError => e
        $stderr.puts "\n  ERROR on #{filename}: #{e.message}"
        timings[filename] = nil
      end
    end

    $stderr.puts

    File.write(tmp_path, JSON.generate({ version: version, timings: timings }))
  end

  Process.wait(pid)

  begin
    all_results[version] = JSON.parse(File.read(tmp_path))
  rescue StandardError => e
    warn "Failed to read results for #{version}: #{e.message}"
    all_results[version] = { "version" => version, "timings" => {} }
  ensure
    FileUtils.rm_f(tmp_path)
  end
end

# ── Results table ─────────────────────────────────────────────────────────────

puts
puts "## Results (seconds, best of #{ITERATIONS})\n\n"

name_w = 36
ver_w  = 10

header = "| #{"File".ljust(name_w)} | #{"Rows".rjust(7)} |"
VERSIONS.each { |v| header += " #{("v" + v).ljust(ver_w)} |" }
puts header

sep = "|#{'-' * (name_w + 2)}|#{'-' * 9}|"
VERSIONS.each { sep += "#{'-' * (ver_w + 2)}|" }
puts sep

CSV_FILES.each do |filepath|
  filename = File.basename(filepath)
  rows     = count_rows(filepath)

  row = "| #{filename.ljust(name_w)} | #{rows.to_s.rjust(7)} |"
  VERSIONS.each do |version|
    t = all_results.dig(version, "timings", filename)
    row += t ? " #{format('%.4fs', t).rjust(ver_w)} |" : " #{'N/A'.rjust(ver_w)} |"
  end
  puts row
end

# ── Speedup table (relative to first version) ─────────────────────────────────

baseline = VERSIONS.first

puts
puts "## Speedup vs #{baseline} (>1 = faster)\n\n"

header2 = "| #{"File".ljust(name_w)} | #{"Rows".rjust(7)} |"
VERSIONS.drop(1).each { |v| header2 += " #{("v" + v).ljust(ver_w)} |" }
puts header2

sep2 = "|#{'-' * (name_w + 2)}|#{'-' * 9}|"
VERSIONS.drop(1).each { sep2 += "#{'-' * (ver_w + 2)}|" }
puts sep2

CSV_FILES.each do |filepath|
  filename = File.basename(filepath)
  rows     = count_rows(filepath)
  base_t   = all_results.dig(baseline, "timings", filename)

  next unless base_t && base_t > 0

  row = "| #{filename.ljust(name_w)} | #{rows.to_s.rjust(7)} |"
  VERSIONS.drop(1).each do |version|
    t = all_results.dig(version, "timings", filename)
    if t && t > 0
      ratio = base_t / t
      label = ratio >= 1 ? format("%.2f×", ratio) : format("0.#{format('%.2f', ratio)}×")
      row += " #{label.rjust(ver_w)} |"
    else
      row += " #{'N/A'.rjust(ver_w)} |"
    end
  end
  puts row
end

puts
puts "*(Baseline: SmarterCSV #{baseline})*"
puts "*(Warmup: #{WARMUP} discarded. Measured: best of #{ITERATIONS}. Each version in isolated subprocess.)*"

# ── Save JSON ─────────────────────────────────────────────────────────────────

FileUtils.mkdir_p(File.join(root, "results"))
timestamp   = Time.now.strftime("%Y-%m-%d")
result_path = File.join(root, "results", "#{timestamp}_versions.json")
File.write(result_path, JSON.pretty_generate(all_results))
puts "\nRaw results saved to: #{result_path}"
