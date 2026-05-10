# frozen_string_literal: true
#
# benchmarks/eta.rb — runtime estimator for benchmark runs.
#
# Scans all results/*.raw.json files and for each version that will run, finds
# the most recent run where THAT version was freshly measured. Uses those
# per-version timings to project total time:
#
#   estimate = Σ_version Σ_file (c + rb) × (WARMUP + ITERATIONS)
#
# Versions with no historical fresh data are estimated using the SLOWEST
# version that does have data (conservative — better to overestimate than
# underestimate). Versions are reported in the result so the caller can warn.
#
# In-process adapters per file are determined by the caller, since the
# SmarterCSV adapters source their timings from version_timings, not from
# in-process measurement.

require "json"
require_relative "../tools/merge_helpers"

class EtaEstimator
  def initialize(results_dir:, warmup:, iterations:)
    @results_dir = results_dir
    @factor      = warmup + iterations
  end

  def estimate(in_process_per_file:, versions_to_run:)
    raw_files = Dir.glob(File.join(@results_dir, "*.raw.json"))
                   .reject { |f| File.symlink?(f) }
                   .sort.reverse   # newest first by filename
    return nil if raw_files.empty?

    parsed = {}
    raw_files.each do |path|
      parsed[path] = JSON.parse(File.read(path)) rescue nil
    end
    parsed.compact!
    return nil if parsed.empty?

    # For each version, find the most recent run that has fresh data for it.
    per_version = {}
    versions_to_run.each do |version|
      raw_files.each do |path|
        data = parsed[path]
        next unless data
        cached = data["cached_versions"] || []
        next if cached.include?(version)
        timings = data.dig("version_timings", version)
        next unless timings.is_a?(Hash) && !timings.empty?
        per_version[version] = { path: path, data: data, timings: timings }
        break
      end
    end

    missing = versions_to_run - per_version.keys

    # For each missing version, fall back to the CLOSEST available version
    # (preferring the highest one ≤ missing; otherwise the lowest one above).
    # Track which fallback was used per missing version.
    fallback_used = {}   # missing_version => fallback_version_string
    if per_version.any?
      missing.each do |version|
        fb = closest_version(version, per_version.keys)
        fallback_used[version] = fb if fb
      end
    end

    # Sum version-phase time
    version_seconds_total = 0.0
    versions_to_run.each do |version|
      timings = per_version[version]&.dig(:timings) ||
                (fb = fallback_used[version]) && per_version[fb][:timings]
      next unless timings
      version_seconds_total += sum_cell_times(timings, in_process_per_file.keys) * @factor
    end

    # Sum adapter-phase time (uses one representative run for adapter results)
    adapter_seconds = 0.0
    primary_data = per_version.values.first&.dig(:data) || parsed.values.first
    in_process_per_file.each do |filename, adapter_names|
      adapter_names.each do |name|
        cell = primary_data.dig("results", filename, name)
        t = MergeHelpers.cell_value(cell, "time")
        adapter_seconds += t * @factor if t
      end
    end

    primary_path = per_version.values.first&.dig(:path) || raw_files.first

    {
      source:              primary_path,
      timestamp:           primary_data["timestamp"],
      ruby:                primary_data["ruby"],
      version_seconds:     version_seconds_total,
      adapter_seconds:     adapter_seconds,
      total_seconds:       version_seconds_total + adapter_seconds,
      per_version_sources: per_version.transform_values { |info| File.basename(info[:path]) },
      missing_versions:    missing,
      fallback_used:       fallback_used   # missing_version => closest_version_used
    }
  end

  # Closest available version to `target`, preferring the highest one ≤ target;
  # if none below, the lowest one above. Returns nil if no candidates.
  def closest_version(target, available)
    return nil if available.empty?
    target_v = Gem::Version.new(target) rescue nil
    return available.first unless target_v
    sorted = available.sort_by { |v| Gem::Version.new(v) rescue Gem::Version.new("0") }
    below = sorted.select { |v| (Gem::Version.new(v) rescue Gem::Version.new("0")) <= target_v }
    below.last || sorted.first
  end
  private :closest_version

  # Sum c+rb timings (using cell_value, default p10) over the specified files.
  def sum_cell_times(timings, filenames)
    filenames.sum do |filename|
      cell = timings[filename]
      next 0.0 unless cell
      (MergeHelpers.cell_value(cell, "c") || 0) +
        (MergeHelpers.cell_value(cell, "rb") || 0)
    end
  end
  private :sum_cell_times

  # Coarse formatter for ETA display: drops seconds when total >= 1 minute.
  def self.format(seconds)
    total = seconds.round
    h, rem = total.divmod(3600)
    m, s   = rem.divmod(60)
    if h > 0
      m > 0 ? "#{h}h #{m}m" : "#{h}h"
    elsif m > 0
      "#{m}m"
    else
      "#{s}s"
    end
  end
end
