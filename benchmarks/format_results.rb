#!/usr/bin/env ruby
# frozen_string_literal: true
#
# benchmarks/format_results.rb — Format a benchmark JSON into Markdown tables.
#
# Output: Markdown tables to STDOUT and results/<basename>.md
#
# Usage:
#   ruby benchmarks/format_results.rb [path/to/results.json]
#   (defaults to results/latest.json symlink)

require "json"

root = File.expand_path("..", __dir__)

# ── Find JSON file ─────────────────────────────────────────────────────────────

json_path = ARGV[0] || File.join(root, "results", "latest.json")

unless json_path && File.exist?(json_path.to_s)
  warn "No results JSON found. Run 'rake bench' first, or pass a path as argument."
  exit 1
end

raw = JSON.parse(File.read(json_path))

ruby_version    = raw["ruby"]
platform        = raw["platform"]
smarter_version = raw["smarter_csv"]
warmup          = raw["warmup"]
iterations      = raw["iterations"]
timestamp       = raw["timestamp"] || File.basename(json_path, ".json")
adapter_labels  = raw["adapter_labels"] || {}
results         = raw["results"]

# Adapter names in column order (insertion order preserved by JSON parser)
adapter_names = results.values.first&.keys&.reject { |k| k == "_rows" } || []

# Reference adapter names for speedup tables
ref_c_name  = "SmarterCSV.process (C accelerated)"
ref_rb_name = "SmarterCSV.process (no acceleration)"

# Footnote marks by short label (applied to non-SmarterCSV adapters)
FOOTNOTE_RAW  = "¹"
FOOTNOTE_NEAR = "²"
footnote_by_label = {
  "CSV.read"    => FOOTNOTE_RAW,
  "CSV.hashes"  => FOOTNOTE_RAW,
  "CSV.table"   => FOOTNOTE_NEAR,
  "ZSV.read"    => FOOTNOTE_RAW,
  "ZSV+wrapper" => FOOTNOTE_NEAR,
}

# Display labels: short label + footnote mark where applicable
display_labels = adapter_labels.transform_values { |lbl| lbl + (footnote_by_label[lbl] || "") }

# ── Helpers ───────────────────────────────────────────────────────────────────

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

output_lines = []

def emit(line = "", output_lines)
  puts line
  output_lines << line
end

# ── Column widths ─────────────────────────────────────────────────────────────

name_w = [36, results.keys.map(&:length).max].max
col_w  = [10, adapter_names.map { |n| (display_labels[n] || n).length }.max].max

def table_header(name_w, col_w, adapter_names, display_labels)
  row = "| #{"File".ljust(name_w)} | #{"Rows".rjust(7)} |"
  adapter_names.each { |n| row += " #{(display_labels[n] || n).ljust(col_w)} |" }
  row
end

def table_sep(name_w, col_w, adapter_names)
  row = "|#{'-' * (name_w + 2)}|#{'-' * 9}|"
  adapter_names.each { row += "#{'-' * (col_w + 2)}|" }
  row
end

# ── Banner ────────────────────────────────────────────────────────────────────

has_zsv = adapter_names.any? { |n| n.start_with?("ZSV") }

emit "# CSV Benchmarks", output_lines
emit "", output_lines
emit "- Date: #{timestamp}", output_lines
emit "- Ruby: #{ruby_version} [#{platform}]", output_lines
emit "- SmarterCSV: #{smarter_version}", output_lines
emit "- Warmup: #{warmup} iteration(s), Measured: best of #{iterations}", output_lines
emit "- Adapters: #{adapter_names.map { |n| display_labels[n] || n }.join(', ')}", output_lines
emit "", output_lines
if has_zsv
  emit "> **Note:** ZSV results have GC disabled during calls (zsv-ruby 1.3.1 GC bug", output_lines
  emit "> on Ruby 3.4.x). This gives ZSV a slight speed advantage — no GC pauses.", output_lines
  emit "", output_lines
end

# ── Full Results table (seconds) ──────────────────────────────────────────────

emit "## Full Results (seconds, best of #{iterations} runs)\n", output_lines
emit table_header(name_w, col_w, adapter_names, display_labels), output_lines
emit table_sep(name_w, col_w, adapter_names), output_lines

results.each do |filename, data|
  rows = data["_rows"].to_i
  row  = "| #{filename.ljust(name_w)} | #{rows.to_s.rjust(7)} |"
  adapter_names.each do |name|
    t    = data.dig(name, "time")
    cell = t ? fmt_time(t) : "N/A"
    row += " #{cell.rjust(col_w)} |"
  end
  emit row, output_lines
end

emit "", output_lines

# ── Throughput table (rows/second) ────────────────────────────────────────────

emit "## Throughput (rows/second)\nHigher numbers are better\n\n", output_lines
emit table_header(name_w, col_w, adapter_names, display_labels), output_lines
emit table_sep(name_w, col_w, adapter_names), output_lines

results.each do |filename, data|
  rows = data["_rows"].to_i
  row  = "| #{filename.ljust(name_w)} | #{rows.to_s.rjust(7)} |"
  adapter_names.each do |name|
    t    = data.dig(name, "time")
    cell = t ? fmt_rows_per_sec(rows, t) : "N/A"
    row += " #{cell.rjust(col_w)} |"
  end
  emit row, output_lines
end

emit "", output_lines

# ── Speedup tables ────────────────────────────────────────────────────────────

[
  ["## Speedup vs SmarterCSV (C accelerated)\n", ref_c_name,  ref_rb_name],
  ["## Speedup vs SmarterCSV (Ruby path)\n",      ref_rb_name, ref_c_name],
].each do |title, ref_name, excluded_name|
  next unless adapter_names.include?(ref_name)

  table_adapters = adapter_names.reject { |n| n == excluded_name }

  emit title, output_lines
  emit table_header(name_w, col_w, table_adapters, display_labels), output_lines
  emit table_sep(name_w, col_w, table_adapters), output_lines

  results.each do |filename, data|
    rows     = data["_rows"].to_i
    ref_time = data.dig(ref_name, "time")
    row      = "| #{filename.ljust(name_w)} | #{rows.to_s.rjust(7)} |"

    table_adapters.each do |name|
      cell = if name == ref_name
               "ref"
             elsif ref_time && (t = data.dig(name, "time"))
               speedup_label(ref_time, t)
             else
               "N/A"
             end
      row += " #{cell.rjust(col_w)} |"
    end

    emit row, output_lines
  end

  emit "", output_lines
end

# ── Footnotes ─────────────────────────────────────────────────────────────────

emit "---", output_lines
emit "", output_lines
emit "#{FOOTNOTE_RAW} **Raw output** — no post-processing applied. Returns plain arrays or string-keyed hashes.", output_lines
emit "  No header normalization, type conversion, whitespace stripping, or empty-value removal.", output_lines
emit "  Your own post-processing must be added to produce usable data.", output_lines
emit "", output_lines
emit "#{FOOTNOTE_NEAR} **Near-equivalent** to SmarterCSV output (symbol keys, numeric conversion), but not 100%", output_lines
emit "  identical. Whitespace handling, empty-value removal, and duplicate-header behavior may differ.", output_lines
emit "", output_lines

# ── Save Markdown ─────────────────────────────────────────────────────────────

md_path = json_path.sub(/\.json$/, ".md")
File.write(md_path, output_lines.join("\n") + "\n")
puts "Markdown saved to: #{md_path}"
