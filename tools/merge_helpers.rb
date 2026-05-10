# frozen_string_literal: true
#
# tools/merge_helpers.rb — Shared logic for reading and merging benchmark runs.
#
# Schema (Option A, post-2026-05-09):
#
#   Per-run JSONs (results/<timestamp>_ruby<X.Y.Z>.raw.json) store per-cell
#   SAMPLE ARRAYS:
#     "uscities.csv": { "c_samples": [0.080, 0.081, ...40 floats], "rb_samples": [...] }
#
#   Canonical cache files (results/smarter_csv_X.Y.Z.json) store per-cell
#   PER-RUN SAMPLE ARRAYS with provenance (Option B):
#     "uscities.csv": { "runs": [{source, timestamp, warmup, c_samples, rb_samples}, ...] }
#
#   Comparison JSONs (results/<timestamp>_ruby<X.Y.Z>_<stats>.comparison.json)
#   store per-cell AGGREGATED single values (one stats method applied uniformly):
#     "uscities.csv": { "c": 0.080, "rb": 1.10 }
#
#   Legacy JSONs may have only the aggregated form { "c": ..., "rb": ... }
#   without samples; cell_value falls back to that.
#
# Tunable knob:
#   STATS_METHOD env var selects the within-run statistic computed from samples.
#   Supported: :min, :p5, :p10, :median, :best_window5
#   Default: :p10  (4th-lowest of 40 — robust to a few timer flukes,
#   still rewards fast execution).

module MergeHelpers
  module_function

  DEFAULT_STATS_METHOD = :p10

  def stats_method
    (ENV["STATS_METHOD"] || DEFAULT_STATS_METHOD).to_sym
  end

  # Linear-interpolated percentile of an Array of Floats.
  def percentile(values, pct)
    return nil if values.nil? || values.empty?
    sorted = values.sort
    rank = (pct / 100.0) * (sorted.length - 1)
    lo, hi = sorted[rank.floor], sorted[rank.ceil]
    lo + (hi - lo) * (rank - rank.floor)
  end

  # Within-run statistic from a sample array. Returns nil for empty input.
  def within_run_stat(samples, method: stats_method)
    return nil if samples.nil? || samples.empty?
    case method
    when :min          then samples.min.to_f
    when :p5           then percentile(samples, 5)
    when :p10          then percentile(samples, 10)
    when :median, :p50 then percentile(samples, 50)
    when :best_window5
      return samples.first.to_f if samples.size < 5
      samples.each_cons(5).map { |w| w.sum / 5.0 }.min
    else
      raise ArgumentError, "Unknown STATS_METHOD: #{method.inspect} (supported: min, p5, p10, median, best_window5)"
    end
  end

  # Read a per-cell value, applying within_run_stat (and across-run aggregate
  # for canonical-shaped cells), in this priority order:
  #
  #   1. cell["runs"]     → Array of run records, each {source, timestamp,
  #                         c_samples, rb_samples}. Apply within_run_stat to
  #                         each run's samples, then aggregate() across runs
  #                         (median for 3+, mean for 2).
  #                         Used by canonical files (smarter_csv_X.Y.Z.json).
  #
  #   2. "{path}_samples" → single Array (one run's 40 samples).
  #                         Apply within_run_stat. Used by per-run JSONs.
  #
  #   3. cell[path]       → legacy pre-aggregated single Float.
  #                         Used by pre-Option-A JSONs.
  #
  # path: "c", "rb", or "time".
  def cell_value(cell, path, method: stats_method)
    return nil unless cell.is_a?(Hash)

    runs = cell["runs"]
    if runs.is_a?(Array) && !runs.empty?
      samples_key = "#{path}_samples"
      per_run = runs.map { |r| within_run_stat(r.is_a?(Hash) ? r[samples_key] : nil, method: method) }.compact
      return aggregate(per_run)
    end

    samples = cell["#{path}_samples"]
    if samples.is_a?(Array) && !samples.empty?
      return within_run_stat(samples, method: method)
    end

    v = cell[path]
    v.is_a?(Numeric) ? v.to_f : nil
  end

  # ── Across-run aggregation (median for 3+, mean for 2, identity for 1) ────

  def aggregate(values)
    vals = values.compact.select { |v| v.is_a?(Numeric) && v > 0 }
    return nil if vals.empty?
    return vals.first.to_f if vals.size == 1
    return (vals.sum.to_f / 2) if vals.size == 2

    sorted = vals.sort
    mid = sorted.size / 2
    sorted.size.odd? ? sorted[mid].to_f : (sorted[mid - 1] + sorted[mid]) / 2.0
  end

  # Collect per-run sample arrays into the canonical shape with provenance:
  #
  #   { filename => { "runs" => [
  #       { "source" => "...", "timestamp" => "...",
  #         "c_samples" => [40 floats], "rb_samples" => [40 floats] },
  #       ...
  #   ] } }
  #
  # Each "runs" entry carries its own source filename and timestamp, so
  # downstream tools can identify which run produced any given measurement.
  # Run boundaries are preserved → any stats method can be applied at read
  # time without re-merging (true apples-to-apples flexibility).
  #
  # `runs_meta` is an Array of [source_basename, timestamp, warmup, timings_hash].
  # When a run's cell is legacy (only c/rb single value), that value is
  # wrapped as a 1-element samples array so the run still contributes.
  def collect_runs(runs_meta)
    out = Hash.new { |h, fn| h[fn] = { "runs" => [] } }
    runs_meta.each do |source, timestamp, warmup, timings|
      timings.each do |filename, cell|
        record = { "source" => source, "timestamp" => timestamp, "warmup" => warmup }
        %w[c rb].each do |path|
          samples = cell["#{path}_samples"]
          if samples.is_a?(Array) && !samples.empty?
            record["#{path}_samples"] = samples.map(&:to_f)
          elsif (v = cell[path]).is_a?(Numeric) && v > 0
            record["#{path}_samples"] = [v.to_f]   # legacy fallback
          end
        end
        # Skip records where neither path produced data.
        out[filename]["runs"] << record if record.key?("c_samples") || record.key?("rb_samples")
      end
    end
    out.reject! { |_, c| c["runs"].empty? }
    out
  end

  # ── cached_versions handling (unchanged from before) ──────────────────────

  def usable_timings_for(data, version, source_path:, warned:)
    cached = data["cached_versions"]
    if cached.nil?
      unless warned.include?(source_path)
        warn "NOTE: #{File.basename(source_path)} predates the cached_versions marker; treating all version_timings as fresh"
        warned << source_path
      end
      return data.dig("version_timings", version)
    end
    return nil if cached.include?(version)
    data.dig("version_timings", version)
  end
end
