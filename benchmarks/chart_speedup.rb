#!/usr/bin/env ruby
# frozen_string_literal: true
#
# benchmarks/chart_speedup.rb — SVG horizontal bar chart
#
# Shows speedup of SmarterCSV C-accelerated over Ruby CSV.read per dataset.
# Speedup = CSV.read time ÷ SmarterCSV time  (higher = SmarterCSV is faster)
#
# Usage:
#   ruby benchmarks/chart_speedup.rb [path/to/results.json]
#   rake chart speedup
#   rake chart speedup results/2026-03-05_2211_ruby3.4.7.json

require "json"
require_relative "../tools/merge_helpers"

root      = File.expand_path("..", __dir__)
json_path = ARGV[0] || File.join(root, "results", "latest.json")

unless File.exist?(json_path.to_s)
  warn "No results JSON found at #{json_path}. Run 'rake bench' first."
  exit 1
end

raw             = JSON.parse(File.read(json_path))
ruby_version    = raw["ruby"]
iterations      = raw["iterations"]
csv_version     = '3.3.5'
smcsv_version   = raw["smarter_csv"]
version_timings = raw["version_timings"] || {}
results         = raw["results"] || {}

smcsv_timings = version_timings[smcsv_version] || {}

if smcsv_timings.empty?
  warn "ERROR: No version_timings for SmarterCSV #{smcsv_version} in #{json_path}."
  warn "Available versions: #{version_timings.keys.join(', ')}"
  exit 1
end

ADAPTER_KEY = "CSV.read (raw arrays)"

# ── Build data ────────────────────────────────────────────────────────────────

bars = []

results.each do |filename, file_data|
  csv_t   = MergeHelpers.cell_value(file_data[ADAPTER_KEY], "time")
  smcsv_t = MergeHelpers.cell_value(smcsv_timings[filename], "c")
  next unless csv_t && smcsv_t && smcsv_t > 0 && csv_t > 0

  bars << { label: File.basename(filename), speedup: csv_t / smcsv_t }
end

if bars.empty?
  warn "No data found. Ensure results JSON has both:"
  warn "  version_timings[\"#{smcsv_version}\"][file][\"c\"]"
  warn "  results[file][\"#{ADAPTER_KEY}\"][\"time\"]"
  exit 1
end

bars.sort_by! { |b| -b[:speedup] }

# ── Scale ─────────────────────────────────────────────────────────────────────

max_speedup = bars.map { |b| b[:speedup] }.max

tick_step = case max_speedup
            when 0..3   then 0.5
            when 3..10  then 1
            when 10..20 then 2
            else             5
            end

chart_max  = ((max_speedup * 1.1) / tick_step).ceil * tick_step
ticks      = (0..chart_max).step(tick_step).map { |t| t.is_a?(Float) ? t.round(10) : t }

# ── Dimensions ────────────────────────────────────────────────────────────────

NAME_W   = 240
CHART_W  = 500
PAD_R    = 24
TOTAL_W  = NAME_W + CHART_W + PAD_R
ROW_H    = 28
BAR_H    = 18
HEADER_H = 62
FOOTER_H = 38
TOTAL_H  = HEADER_H + bars.size * ROW_H + FOOTER_H

FONT        = "ui-monospace, 'Cascadia Code', 'Courier New', monospace"
BAR_COLOR   = "#1565C0"
LABEL_COLOR = "#424242"

# ── Helpers ───────────────────────────────────────────────────────────────────

def xml_escape(str)
  str.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
end

def fmt_speedup(v)
  v >= 10 ? format("%.1f×", v) : format("%.2f×", v)
end

# ── SVG ───────────────────────────────────────────────────────────────────────

svg = []
svg << <<~SVG.strip
  <svg xmlns="http://www.w3.org/2000/svg" width="#{TOTAL_W}" height="#{TOTAL_H}"
       font-family="#{FONT}" font-size="12">
SVG

svg << %(<rect width="#{TOTAL_W}" height="#{TOTAL_H}" fill="#ffffff"/>)

# Title
title = "SmarterCSV #{smcsv_version} vs Ruby CSV.read #{csv_version}"
svg << %(<text x="#{TOTAL_W / 2}" y="20" text-anchor="middle" font-size="14" ) +
       %(font-weight="bold" fill="#212121">#{xml_escape(title)}</text>)

# Subtitle
svg << %(<text x="#{TOTAL_W / 2}" y="36" text-anchor="middle" font-size="10" fill="#9e9e9e">) +
       %(Speedup = CSV.read time ÷ SmarterCSV time  (higher = SmarterCSV is faster) · ) +
       %(Ruby #{ruby_version} · best of #{iterations}</text>)

# X-axis label (above tick marks, below bars)
xlabel_y = HEADER_H + bars.size * ROW_H + 26
svg << %(<text x="#{NAME_W + CHART_W / 2}" y="#{xlabel_y}" text-anchor="middle" ) +
       %(font-size="11" fill="#616161">Speedup (CSV.read ÷ SmarterCSV #{smcsv_version} C)</text>)

# Vertical grid lines + tick labels
ticks.each do |t|
  x = NAME_W + (t / chart_max * CHART_W).round
  svg << %(<line x1="#{x}" y1="#{HEADER_H}" x2="#{x}" y2="#{HEADER_H + bars.size * ROW_H}" ) +
         %(stroke="#e0e0e0" stroke-width="1"/>)
  tick_lbl = t == t.to_i ? "#{t.to_i}×" : "#{t}×"
  svg << %(<text x="#{x}" y="#{HEADER_H + bars.size * ROW_H + 12}" text-anchor="middle" ) +
         %(font-size="11" fill="#757575">#{tick_lbl}</text>)
end

# 1× reference dashed line
one_x = NAME_W + (1.0 / chart_max * CHART_W).round
svg << %(<line x1="#{one_x}" y1="#{HEADER_H}" x2="#{one_x}" ) +
       %(y2="#{HEADER_H + bars.size * ROW_H}" stroke="#9e9e9e" stroke-width="1.5" stroke-dasharray="4,3"/>)

# X-axis baseline
axis_y = HEADER_H + bars.size * ROW_H
svg << %(<line x1="#{NAME_W}" y1="#{axis_y}" x2="#{NAME_W + CHART_W}" y2="#{axis_y}" ) +
       %(stroke="#bdbdbd" stroke-width="1"/>)

# Y-axis line
svg << %(<line x1="#{NAME_W}" y1="#{HEADER_H}" x2="#{NAME_W}" y2="#{axis_y}" ) +
       %(stroke="#bdbdbd" stroke-width="1"/>)

# Bars
bars.each_with_index do |bar, i|
  y     = HEADER_H + i * ROW_H
  bar_y = y + (ROW_H - BAR_H) / 2
  bw    = [(bar[:speedup] / chart_max * CHART_W).round, 1].max

  # Alternating row background
  svg << %(<rect x="0" y="#{y}" width="#{TOTAL_W}" height="#{ROW_H}" ) +
         %(fill="#{i.even? ? '#f5f5f5' : '#ffffff'}"/>)

  # File label
  svg << %(<text x="#{NAME_W - 8}" y="#{y + ROW_H / 2 + 4}" text-anchor="end" ) +
         %(font-size="11" fill="#{LABEL_COLOR}">#{xml_escape(bar[:label])}</text>)

  # Bar
  svg << %(<rect x="#{NAME_W}" y="#{bar_y}" width="#{bw}" height="#{BAR_H}" ) +
         %(fill="#{BAR_COLOR}" rx="2"/>)

  # Speedup label — inside bar if wide enough, outside otherwise
  lbl   = fmt_speedup(bar[:speedup])
  lbl_w = lbl.length * 7
  if bw > lbl_w + 8
    svg << %(<text x="#{NAME_W + bw - 4}" y="#{y + ROW_H / 2 + 4}" ) +
           %(text-anchor="end" font-size="10" fill="#ffffff" font-weight="bold">#{lbl}</text>)
  else
    svg << %(<text x="#{NAME_W + bw + 4}" y="#{y + ROW_H / 2 + 4}" ) +
           %(font-size="10" fill="#{BAR_COLOR}">#{lbl}</text>)
  end
end

svg << "</svg>"

# ── Save ──────────────────────────────────────────────────────────────────────

svg_path = File.realpath(json_path).sub(/\.json$/, "_speedup_chart.svg")
File.write(svg_path, svg.join("\n"))
puts "Chart saved to: #{svg_path}"
