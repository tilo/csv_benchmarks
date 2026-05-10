#!/usr/bin/env ruby
# frozen_string_literal: true
#
# tools/backfill_cached_versions.rb — Retroactively add a cached_versions
# array to every results/202*.raw.json file that doesn't already have one.
#
# Detection algorithm:
#   For each version, scan results files in chronological order. The first
#   time a particular timing fingerprint (deterministic dump of c+rb values
#   per filename) appears, that run actually measured the version. Every
#   subsequent run with the same fingerprint loaded from cache.
#
# Edge case: after a re-aggregation (rake merge_results), the canonical's
# numbers no longer match any prior single run. The first run that loads the
# new canonical will be misclassified as "fresh" — one false-positive per
# re-merge. Acceptable in practice.
#
# File mtime is preserved so this doesn't disturb existing chronological
# ordering on disk.
#
# Usage:
#   ruby tools/backfill_cached_versions.rb [--dry-run]

require "json"

dry_run = ARGV.delete("--dry-run")

root     = File.expand_path("..", __dir__)
scan_dir = File.join(root, "results")

unless Dir.exist?(scan_dir)
  warn "ERROR: scan dir not found: #{scan_dir}"
  exit 1
end

files = Dir.glob(File.join(scan_dir, "202*.raw.json"))
           .reject { |f| File.symlink?(f) }
           .sort   # ascending = chronological by filename

if files.empty?
  warn "ERROR: no results/202*.raw.json files found"
  exit 1
end

# fingerprint: deterministic dump of timings — same numbers ⇒ same fingerprint.
def fingerprint(timings)
  return nil if timings.nil? || timings.empty?
  timings.sort.map { |fn, vals| "#{fn}|#{vals["c"]}|#{vals["rb"]}" }.join("\n")
end

seen     = Hash.new { |h, v| h[v] = {} }   # version => { fingerprint => first_filename }
updated  = 0
skipped  = 0
already  = 0
classifications = []   # [path, cached_list, fresh_list]

files.each do |path|
  begin
    data = JSON.parse(File.read(path))
  rescue JSON::ParserError => e
    warn "WARNING: skipping unparseable #{File.basename(path)}: #{e.message}"
    skipped += 1
    next
  end

  if data.key?("cached_versions")
    already += 1
    next
  end

  vt = data["version_timings"] || {}
  cached_here = []
  fresh_here  = []

  vt.each do |version, timings|
    fp = fingerprint(timings)
    next unless fp   # empty/nil timings: skip — neither cached nor fresh, just absent
    if seen[version].key?(fp)
      cached_here << version
    else
      seen[version][fp] = File.basename(path)
      fresh_here << version
    end
  end

  classifications << [path, cached_here, fresh_here]

  unless dry_run
    mtime = File.mtime(path)
    atime = File.atime(path)
    data["cached_versions"] = cached_here
    File.write(path, JSON.pretty_generate(data))
    File.utime(atime, mtime, path)
  end
  updated += 1
end

# ── Summary ────────────────────────────────────────────────────────────────

puts "#{dry_run ? "DRY-RUN: would update" : "Updated"} #{updated} file(s); #{already} already had marker; #{skipped} skipped"
puts

classifications.each do |path, cached, fresh|
  basename = File.basename(path)
  parts = []
  parts << "fresh: #{fresh.join(', ')}" unless fresh.empty?
  parts << "cached: #{cached.join(', ')}" unless cached.empty?
  parts << "(no version_timings)" if parts.empty?
  puts "  #{basename}  →  #{parts.join('  |  ')}"
end
