#!/usr/bin/env ruby
# frozen_string_literal: true
#
# tools/compare_versions.rb — Generate an apples-to-apples cross-version
# comparison JSON.
#
# Reads results/<timestamp>_ruby<X.Y.Z>.raw.json files chronologically (newest first),
# filters to runs where ALL requested versions were freshly measured in
# the same session (cached_versions doesn't include them), then for each
# cell:
#
#   1. Within each run: apply stats_method to the 40-sample array
#      → per-run number for that (version, file, c|rb).
#   2. Across N matching runs: aggregate (median for 3+, mean for 2,
#      identity for 1) those per-run numbers.
#
# Same stats method is applied to every cell, including non-SmarterCSV
# adapters (CSV.read etc) sourced from `results`, so the comparison is
# truly apples-to-apples.
#
# Output: results/<timestamp>_ruby<X.Y.Z>_<stats>.comparison.json
#
# Usage:
#   ruby tools/compare_versions.rb <stats_method> <version1> [<version2>...]
#   N=5 ruby tools/compare_versions.rb p10 1.14.4 1.15.2 1.16.4 1.17.0.pre8
#       # cap at the most recent 5 matching runs

require "json"
require "rubygems"
require "time"
require_relative "merge_helpers"

VALID_METHODS = %w[min p5 p10 median best_window5].freeze

if ARGV.size < 2
  warn "Usage: ruby tools/compare_versions.rb <stats_method> <version1> [<version2>...]"
  warn "Example: ruby tools/compare_versions.rb p10 1.14.4 1.15.2 1.16.0 1.16.4 1.17.0.pre8"
  warn "Stats methods: #{VALID_METHODS.join(', ')}"
  exit 1
end

stats_method = ARGV[0]
versions     = ARGV[1..]

unless VALID_METHODS.include?(stats_method)
  warn "ERROR: invalid stats_method #{stats_method.inspect}; must be one of: #{VALID_METHODS.join(', ')}"
  exit 1
end

invalid = versions.reject { |v| v.match?(/\A\d+\.\d+\.\d+(\.\w+)?\z/) }
if invalid.any?
  warn "ERROR: invalid version format: #{invalid.join(', ')}"
  exit 1
end

method_sym = stats_method.to_sym
n_cap      = ENV["N"]&.to_i

root     = File.expand_path("..", __dir__)
scan_dir = File.join(root, "results")
out_dir  = scan_dir

unless Dir.exist?(scan_dir)
  warn "ERROR: scan dir not found: #{scan_dir}"
  exit 1
end

# Most-recent first by filename (filenames are YYYY-MM-DD_HHMM_…)
candidates = Dir.glob(File.join(scan_dir, "202*.raw.json"))
                .reject { |f| File.symlink?(f) }
                .sort
                .reverse

# For each version, find raw runs where that version is FRESH (not loaded from
# cache). Most recent first, optionally capped by env N. Different versions may
# end up sourced from different sessions — that's the cross-session case. The
# `version_sources` map records per-version provenance so consumers can see if
# numbers came from the same session or not.
#
# The earlier "strict same-session" requirement is still implicitly there for
# any user who runs all versions in one bench session — they'll get matching
# source lists per version. Where they don't match, that's surfaced.
parsed = {}
candidates.each do |path|
  begin
    parsed[path] = JSON.parse(File.read(path))
  rescue JSON::ParserError => e
    warn "WARNING: could not parse #{File.basename(path)}: #{e.message}"
  end
end

version_sources = {}   # version => [[path, data], ...] in newest-first order
versions.each do |version|
  found = parsed.select do |_, data|
    cached = data["cached_versions"] || []
    vt     = data["version_timings"] || {}
    !cached.include?(version) && vt[version].is_a?(Hash) && !vt[version].empty?
  end.to_a
  found = found.first(n_cap) if n_cap
  version_sources[version] = found
end

missing = version_sources.select { |_, srcs| srcs.empty? }.keys
if missing.any?
  warn "ERROR: no fresh raw runs found for: #{missing.join(', ')}"
  exit 1
end

# Detect cross-session situation: same set of source files for every version?
source_signatures = version_sources.transform_values { |srcs| srcs.map { |p, _| File.basename(p) }.sort }
all_same_sources  = source_signatures.values.uniq.size == 1

puts "Comparing #{versions.size} version(s), stats_method=#{stats_method}"
if all_same_sources
  puts "Same-session source for all versions (apples-to-apples):"
  source_signatures.values.first.each { |b| puts "  - #{b}" }
else
  puts "WARNING: cross-session comparison — versions sourced from different runs."
  puts "Per-version sources:"
  versions.each do |version|
    srcs = version_sources[version].map { |p, _| File.basename(p) }
    puts "  #{version}:"
    srcs.each { |b| puts "    - #{b}" }
  end
end

# ── Aggregate version_timings per (version, filename, c|rb) ──────────────────

version_timings_out = {}
versions.each do |version|
  per_cell = Hash.new { |h, fn| h[fn] = { "c" => [], "rb" => [] } }
  version_sources[version].each do |_, data|
    timings = data.dig("version_timings", version) || {}
    timings.each do |filename, cell|
      %w[c rb].each do |path|
        v = MergeHelpers.cell_value(cell, path, method: method_sym)
        per_cell[filename][path] << v if v && v > 0
      end
    end
  end
  out = {}
  per_cell.each do |filename, paths|
    cell = {}
    %w[c rb].each do |path|
      agg = MergeHelpers.aggregate(paths[path])
      cell[path] = agg if agg
    end
    out[filename] = cell unless cell.empty?
  end
  version_timings_out[version] = out
end

# Build a flat matching list for the rest of the script (adapter aggregation,
# primary metadata pickup, merged_from): use the union of source files across
# all versions, preserving newest-first order.
union_paths = version_sources.values.flat_map { |srcs| srcs.map(&:first) }.uniq
matching = union_paths.map { |p| [p, parsed[p]] }

# ── Aggregate non-SmarterCSV adapter results across runs ─────────────────────

adapter_samples = Hash.new { |h, fn| h[fn] = Hash.new { |hh, an| hh[an] = [] } }
adapter_rows    = {}

matching.each do |_, data|
  (data["results"] || {}).each do |filename, file_data|
    adapter_rows[filename] ||= file_data["_rows"]
    file_data.each do |adapter_name, cell|
      next if adapter_name == "_rows"
      next if adapter_name.start_with?("SmarterCSV.")  # already in version_timings
      v = MergeHelpers.cell_value(cell, "time", method: method_sym)
      adapter_samples[filename][adapter_name] << v if v && v > 0
    end
  end
end

# Build results_out for EVERY file present in version_timings (so the report's
# version-comparison tables have row counts), even when no adapters ran.
results_out = {}
all_filenames = version_timings_out.values.flat_map(&:keys).uniq
all_filenames.each do |filename|
  entry = { "_rows" => adapter_rows[filename] }
  (adapter_samples[filename] || {}).each do |adapter_name, vals|
    agg = MergeHelpers.aggregate(vals)
    rows = adapter_rows[filename]
    entry[adapter_name] = { "time" => agg, "rows_per_sec" => (agg && rows ? rows / agg : nil) } if agg
  end
  results_out[filename] = entry
end

# ── Write output ─────────────────────────────────────────────────────────────

primary = matching.first[1]

# Per-version run counts → choose the across-runs aggregation label by max count
max_runs = version_sources.values.map(&:size).max

output = {
  "ruby"            => primary["ruby"],
  "platform"        => primary["platform"],
  "csv"             => primary["csv"],
  "zsv"             => primary["zsv"],
  "stats_method"    => stats_method,
  "across_runs"     => max_runs >= 3 ? "median" : (max_runs == 2 ? "mean" : "single"),
  "same_session"    => all_same_sources,
  "warmup"          => primary["warmup"],
  "iterations"      => primary["iterations"],
  "versions"        => versions,
  "version_sources" => version_sources.transform_values { |srcs|
    srcs.map { |path, data| { "source" => File.basename(path), "timestamp" => data["timestamp"] } }
  },
  "merged_from"     => matching.map { |path, data| { "source" => File.basename(path), "timestamp" => data["timestamp"] } },
  "version_timings" => version_timings_out,
  "adapter_labels"  => primary["adapter_labels"] || {},
  "results"         => results_out
}

ts       = Time.now.strftime("%Y-%m-%d_%H%M")
ruby_tag = "ruby#{primary["ruby"] || RUBY_VERSION}"
out_name = "#{ts}_#{ruby_tag}_#{stats_method}.comparison.json"
out_path = File.join(out_dir, out_name)
File.write(out_path, JSON.pretty_generate(output))
puts "  -> #{out_path}"
