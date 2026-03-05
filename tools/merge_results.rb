#!/usr/bin/env ruby
# frozen_string_literal: true
#
# tools/merge_results.rb — Condense best SmarterCSV version timings from multiple runs.
#
# Scans all input JSON files, extracts version_timings for RELEASED versions only
# (plain X.Y.Z, no pre-release suffixes), and keeps the best (minimum) time for
# each (version, file, path) combination across all inputs.
#
# The output is a standalone reference JSON containing only version_timings.
# It is compatible with format_results.rb and chart_versions.rb.
#
# Usage:
#   ruby tools/merge_results.rb file1.json file2.json [...]
#   ruby tools/merge_results.rb file1.json file2.json [...] -o path/to/output/dir
#   rake merge_results file1.json file2.json

require "json"
require "rubygems"
require "net/http"
require "uri"
require "time"

root = File.expand_path("..", __dir__)

# ── Parse args ────────────────────────────────────────────────────────────────

out_idx  = ARGV.index("-o")
out_path = out_idx ? ARGV.delete_at(out_idx + 1) : nil
ARGV.delete("-o")
input_files = ARGV.dup

if input_files.size < 1
  warn "Usage: ruby tools/merge_results.rb file1.json [file2.json ...] [-o output.json]"
  exit 1
end

missing = input_files.reject { |f| File.exist?(f) }
if missing.any?
  warn "ERROR: file(s) not found: #{missing.join(', ')}"
  exit 1
end

# ── Fetch released versions from RubyGems ────────────────────────────────────

def fetch_released_versions(gem_name)
  uri  = URI("https://rubygems.org/api/v1/versions/#{gem_name}.json")
  resp = Net::HTTP.get_response(uri)
  raise "RubyGems API error: #{resp.code}" unless resp.is_a?(Net::HTTPSuccess)
  JSON.parse(resp.body)
    .reject { |v| v["prerelease"] }
    .map    { |v| v["number"] }
rescue => e
  warn "WARNING: could not fetch released versions from RubyGems (#{e.message})."
  warn "         Falling back to format check (X.Y.Z)."
  nil
end

$stderr.print "Fetching released smarter_csv versions from RubyGems... "
released_versions = fetch_released_versions("smarter_csv")
if released_versions
  $stderr.puts "#{released_versions.size} versions found (latest: #{released_versions.first})"
else
  $stderr.puts "offline fallback active"
end

def released?(version, released_versions)
  if released_versions
    released_versions.include?(version)
  else
    version.match?(/\A\d+\.\d+\.\d+\z/)
  end
end

# ── Load and condense ─────────────────────────────────────────────────────────

best_timings   = {}   # { version => { filename => { "c" => Float, "rb" => Float } } }
ruby_versions  = []
primary        = nil

input_files.each do |path|
  data = JSON.parse(File.read(path))
  primary = data
  ruby_versions |= [data["ruby"]]

  (data["version_timings"] || {}).each do |version, file_data|
    unless released?(version, released_versions)
      $stderr.puts "  Skipping unreleased version #{version} in #{File.basename(path)}"
      next
    end

    best_timings[version] ||= {}

    file_data.each do |filename, timings|
      best_timings[version][filename] ||= {}

      %w[c rb].each do |path_key|
        t = timings[path_key]&.to_f
        next unless t && t > 0
        existing = best_timings[version][filename][path_key]
        best_timings[version][filename][path_key] = existing ? [existing, t].min : t
      end
    end
  end
end

if ruby_versions.size > 1
  warn "WARNING: input files span multiple Ruby versions: #{ruby_versions.join(', ')}"
  warn "         Timings may not be comparable across Ruby versions."
end

versions_found = best_timings.keys.sort_by { |v| Gem::Version.new(v) }

if versions_found.empty?
  warn "ERROR: no released version timings found in input files."
  exit 1
end

# ── Save one file per released version ───────────────────────────────────────

out_dir = out_path || File.join(root, "results")

versions_found.each do |version|
  output = {
    "ruby"            => primary["ruby"],
    "platform"        => primary["platform"],
    "smarter_csv"     => version,
    "csv"             => primary["csv"],
    "zsv"             => primary["zsv"],
    "warmup"          => primary["warmup"],
    "iterations"      => primary["iterations"],
    "condensed_from"  => input_files.map { |f| File.basename(f) },
    "version_timings" => { version => best_timings[version] },
    "adapter_labels"  => {},
    "results"         => {},
  }

  path = File.join(out_dir, "smarter_csv_#{version}.json")
  File.write(path, JSON.pretty_generate(output))
  puts "  → #{path}"
end

puts "Done. #{versions_found.size} file(s) written for: #{versions_found.join(', ')}"
