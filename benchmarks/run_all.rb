#!/usr/bin/env ruby
# frozen_string_literal: true
#
# benchmarks/run_all.rb — Run all available adapters against all csv_files/
#
# The SmarterCSV version used is the highest in BenchmarkConfig::SMARTER_CSV_VERSIONS.
# Gemfile.lock is irrelevant — the version is taken from config/benchmark.rb.
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
require "tmpdir"
require "csv"

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(root)

zsv_lib = File.join(Dir.home, "GitHub", "zsv-ruby", "lib")
$LOAD_PATH.unshift(zsv_lib) if Dir.exist?(zsv_lib) && !$LOAD_PATH.include?(zsv_lib)

require_relative "../config/benchmark"

# ── Parameters ────────────────────────────────────────────────────────────────

SMARTER_CSV_VERSIONS = BenchmarkConfig::SMARTER_CSV_VERSIONS
HIGHEST_VERSION      = SMARTER_CSV_VERSIONS.max_by { |v| Gem::Version.new(v) }
WARMUP               = BenchmarkConfig::WARMUP
ITERATIONS           = BenchmarkConfig::ITERATIONS
FILE_OPTIONS         = BenchmarkConfig::FILE_OPTIONS

# ── CSV file list ─────────────────────────────────────────────────────────────

CSV_FILES = (
  Dir[File.join(root, "csv_files", "actual",    "*.{csv,tsv}")] +
  Dir[File.join(root, "csv_files", "synthetic", "*.{csv,tsv}")]
).sort

if CSV_FILES.empty?
  warn "No CSV files found in csv_files/actual/ or csv_files/synthetic/."
  exit 1
end

# ── Multi-version SmarterCSV benchmarking ─────────────────────────────────────
#
# Each version runs in a fresh Ruby subprocess (via system) so that multiple
# gem versions can be activated without conflict. Results written to a temp
# JSON file and read back by the parent.
#
# If results/smarter_csv_<version>.json already exists, those timings are used
# instead of re-running. To force a re-run for specific versions:
#   RECOMPUTE_VERSIONS=1.14.4,1.15.2 rake bench
#   RECOMPUTE_VERSIONS=all rake bench

recompute_env     = ENV.fetch("RECOMPUTE_VERSIONS", "").split(",").map(&:strip)
recompute_all     = recompute_env.include?("all")

version_timings = {}

unless SMARTER_CSV_VERSIONS.empty?
  $stderr.puts "Benchmarking SmarterCSV versions: #{SMARTER_CSV_VERSIONS.join(', ')}..."

  zsv_lib_line = Dir.exist?(zsv_lib) ? "$LOAD_PATH.unshift(#{zsv_lib.inspect})" : ""

  SMARTER_CSV_VERSIONS.each do |version|
    canonical_path = File.join(root, "results", "smarter_csv_#{version}.json")

    if !recompute_all && !recompute_env.include?(version) && File.exist?(canonical_path)
      cached = JSON.parse(File.read(canonical_path))
      version_timings[version] = cached.dig("version_timings", version) || {}
      $stderr.puts "  SmarterCSV #{version}... loaded from #{File.basename(canonical_path)}"
      next
    end

    tmp_path = File.join(Dir.tmpdir, "csv_bench_ver_#{version}_#{Process.pid}.json")

    $stderr.print "  SmarterCSV #{version} [0/#{CSV_FILES.size}]"
    $stderr.flush

    script = <<~RUBY
      require "benchmark"
      require "json"
      #{zsv_lib_line}

      begin
        gem "smarter_csv", #{version.inspect}
      rescue Gem::MissingSpecVersionError, Gem::LoadError => e
        File.write(#{tmp_path.inspect}, JSON.generate({ version: #{version.inspect}, error: e.message, timings: {} }))
        exit 1
      end

      require "smarter_csv"

      csv_files   = #{JSON.generate(CSV_FILES)}
      file_options = #{JSON.generate(FILE_OPTIONS.transform_keys(&:to_s).transform_values { |v| v.transform_keys(&:to_s) })}
      warmup      = #{WARMUP}
      iterations  = #{ITERATIONS}
      timings     = {}

      csv_files.each_with_index do |filepath, i|
        filename  = File.basename(filepath)
        file_opts = (file_options[filename] || {}).transform_keys(&:to_sym)
        $stderr.print "\\r  SmarterCSV #{version} [\#{i + 1}/\#{csv_files.size}]"
        $stderr.flush

        begin
          warmup.times { SmarterCSV.process(filepath, file_opts) }
          c_time = iterations.times.map do
            GC.start; GC.compact rescue nil
            Benchmark.realtime { SmarterCSV.process(filepath, file_opts) }
          end.min

          rb_opts = file_opts.merge(acceleration: false)
          warmup.times { SmarterCSV.process(filepath, rb_opts) }
          rb_time = iterations.times.map do
            GC.start; GC.compact rescue nil
            Benchmark.realtime { SmarterCSV.process(filepath, rb_opts) }
          end.min

          timings[filename] = { c: c_time, rb: rb_time }
        rescue StandardError => e
          $stderr.puts "\\n    ERROR on \#{filename}: \#{e.message}"
          timings[filename] = { c: nil, rb: nil }
        end
      end

      File.write(#{tmp_path.inspect}, JSON.generate({ version: #{version.inspect}, timings: timings }))
    RUBY

    script_path = File.join(Dir.tmpdir, "csv_bench_ver_#{version}_#{Process.pid}.rb")
    File.write(script_path, script)
    if defined?(Bundler)
      Bundler.with_unbundled_env { system(RbConfig.ruby, script_path) }
    else
      system(RbConfig.ruby, script_path)
    end

    begin
      data = JSON.parse(File.read(tmp_path))
      version_timings[version] = data["timings"] || {}
      $stderr.puts "\r  SmarterCSV #{version}... done"
    rescue StandardError => e
      warn "Failed to read results for #{version}: #{e.message}"
      version_timings[version] = {}
    ensure
      FileUtils.rm_f(tmp_path)
      FileUtils.rm_f(script_path)
    end
  end
end

# ── Activate the highest SmarterCSV version from config ───────────────────────

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

# ── Run adapter benchmarks ────────────────────────────────────────────────────

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

json_path = File.join(root, "results", "#{timestamp}_#{ruby_tag}.json")
File.write(json_path, JSON.pretty_generate(
  ruby:                  RUBY_VERSION,
  platform:              RUBY_PLATFORM,
  smarter_csv:           smarter_version,
  csv:                   csv_version,
  zsv:                   zsv_version,
  warmup:                WARMUP,
  iterations:            ITERATIONS,
  timestamp:             Time.now.strftime("%Y-%m-%d %H:%M:%S"),
  adapter_labels:        ADAPTERS.each_with_object({}) { |a, h| h[a.name] = a.label },
  smarter_csv_versions:  SMARTER_CSV_VERSIONS,
  version_timings:       version_timings,
  results:               results
))
puts "JSON saved to: #{json_path}"

symlink_path = File.join(root, "results", "latest.json")
File.delete(symlink_path) if File.symlink?(symlink_path)
File.symlink(File.basename(json_path), symlink_path)
puts "Symlink updated: results/latest.json -> #{File.basename(json_path)}"
