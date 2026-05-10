#!/usr/bin/env ruby
# frozen_string_literal: true
#
# tools/merge_results.rb — Refresh canonical SmarterCSV version cache files.
#
# Auto-discovers all results JSON files, selects only those produced on the
# latest Ruby version found (by Gem::Version), and for each requested version
# extracts ONLY measurements where that version wasn't loaded from a canonical
# cache file (skipping runs whose cached_versions marker lists the version,
# since those would double-count). Aggregates per (filename, c|rb) using
# median for 3+ runs, mean for 2, identity for 1, and writes one canonical
# results/smarter_csv_<version>.json per requested version.
#
# Usage:
#   ruby tools/merge_results.rb 1.15.2 1.16.4
#
# Environment overrides:
#   ANY_RUBY=1    Include data from all Ruby versions found
#                 (default: only data from the latest Ruby found)

require "json"
require "rubygems"
require "set"
require_relative "merge_helpers"

root     = File.expand_path("..", __dir__)
scan_dir = File.join(root, "results")
out_dir  = File.join(root, "results")
any_ruby = !ENV["ANY_RUBY"].to_s.empty?

versions = ARGV.dup

if versions.empty?
  warn "Usage: ruby tools/merge_results.rb <version> [<version>...]"
  warn "Example: ruby tools/merge_results.rb 1.15.2 1.16.4"
  exit 1
end

invalid = versions.reject { |v| v.match?(/\A\d+\.\d+\.\d+(\.\w+)?\z/) }
if invalid.any?
  warn "ERROR: invalid version format: #{invalid.join(', ')}"
  warn "Expected: X.Y.Z or X.Y.Z.preN"
  exit 1
end

# ── Discover JSON files ──────────────────────────────────────────────────────

unless Dir.exist?(scan_dir)
  warn "ERROR: scan dir not found: #{scan_dir}"
  exit 1
end

# Only raw per-run JSONs — skip canonicals (smarter_csv_*.json), comparison
# files (*.comparison.json), and the latest.json symlink.
all_jsons = Dir.glob(File.join(scan_dir, "*.raw.json")).reject { |f| File.symlink?(f) }.sort

if all_jsons.empty?
  warn "ERROR: no *.raw.json files found in #{scan_dir}"
  exit 1
end

# ── Pick latest Ruby version present in the data ─────────────────────────────

file_data = {}
all_jsons.each do |path|
  begin
    file_data[path] = JSON.parse(File.read(path))
  rescue JSON::ParserError => e
    warn "WARNING: could not parse #{File.basename(path)}: #{e.message}"
  end
end

rubies_seen = file_data.values.map { |d| d["ruby"] }.compact.uniq
if rubies_seen.empty?
  warn "ERROR: no Ruby version data found in any JSON"
  exit 1
end

latest_ruby = rubies_seen.max_by { |v| Gem::Version.new(v) }

if any_ruby
  selected = file_data
  ruby_label = "all Ruby versions (#{rubies_seen.sort_by { |v| Gem::Version.new(v) }.join(', ')})"
else
  selected = file_data.select { |_, d| d["ruby"] == latest_ruby }
  ruby_label = "Ruby #{latest_ruby}"
end

puts "Merging from: #{ruby_label} (#{selected.size} JSON file(s) in #{scan_dir})"

# ── Per version: gather fresh runs, then median-aggregate ────────────────────

warned = Set.new
written = 0

versions.each do |version|
  fresh_meta = []   # [[source_basename, timestamp, timings], ...]

  selected.each do |path, data|
    timings = MergeHelpers.usable_timings_for(data, version, source_path: path, warned: warned)
    next unless timings.is_a?(Hash) && !timings.empty?
    fresh_meta << [File.basename(path), data["timestamp"], data["warmup"], timings]
  end

  if fresh_meta.empty?
    warn "WARNING: no fresh timings for #{version} in #{ruby_label}"
    next
  end

  collected = MergeHelpers.collect_runs(fresh_meta)

  primary = selected.find { |_, d| d.dig("version_timings", version) }&.last || selected.values.first

  output = {
    "ruby"            => primary["ruby"],
    "platform"        => primary["platform"],
    "smarter_csv"     => version,
    "csv"             => primary["csv"],
    "zsv"             => primary["zsv"],
    "warmup"          => primary["warmup"],
    "iterations"      => primary["iterations"],
    "merged_from"     => fresh_meta.map(&:first),
    "version_timings" => { version => collected },
    "adapter_labels"  => {},
    "results"         => {}
  }

  path = File.join(out_dir, "smarter_csv_#{version}.json")
  File.write(path, JSON.pretty_generate(output))
  puts "  -> #{path}  (#{fresh_meta.size} fresh run(s) preserved with provenance)"
  written += 1
end

skipped = rubies_seen - [latest_ruby]
if !any_ruby && skipped.any?
  puts ""
  puts "Note: skipped data from Ruby #{skipped.sort_by { |v| Gem::Version.new(v) }.join(', ')} (set ANY_RUBY=1 to include)"
end

exit(written > 0 ? 0 : 1)
