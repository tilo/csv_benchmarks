#!/usr/bin/env ruby
# frozen_string_literal: true
#
# benchmarks/chart_versions.rb — SVG log-scale speedup chart
#
# Usage:
#   ruby benchmarks/chart_versions.rb versions [path/to/results.json]
#   ruby benchmarks/chart_versions.rb adapters [path/to/results.json]
#   rake chart versions
#   rake chart adapters results/2026-03-05_1430_ruby3.4.7.json
#
# Chart type is defined in config/chart.rb.
# JSON defaults to results/latest.json.

require "json"
require "rubygems"  # Gem::Version

root = File.expand_path("..", __dir__)
require File.join(root, "config", "chart")

# ── CLI args ──────────────────────────────────────────────────────────────────

chart_name = ARGV[0]
json_path  = ARGV[1] || File.join(root, "results", "latest.json")

unless chart_name && ChartConfig::CHARTS.key?(chart_name)
  warn "Usage: ruby benchmarks/chart_versions.rb <#{ChartConfig::CHARTS.keys.join('|')}> [path/to/results.json]"
  exit 1
end

unless File.exist?(json_path.to_s)
  warn "No results JSON found at #{json_path}. Run 'rake bench' first."
  exit 1
end

chart_cfg = ChartConfig::CHARTS[chart_name]

raw             = JSON.parse(File.read(json_path))
ruby_version    = raw["ruby"]
iterations      = raw["iterations"]
version_timings = raw["version_timings"] || {}
results         = raw["results"] || {}

# ── Build series ──────────────────────────────────────────────────────────────
#
# Each series is { name:, color:, shape: :circle|:square, rows: [{file:, ratio:}] }
# Rows are keyed by filename; we merge all series into one row list.

series_list = []
all_filenames = []

case chart_cfg[:type]

when :versions
  versions_cfg = chart_cfg[:versions]
  versions_sorted = versions_cfg.sort_by { |v| Gem::Version.new(v) }

  if versions_sorted.size < 2
    warn "ERROR: versions chart requires at least 2 versions in config/chart.rb, found #{versions_sorted.size}."
    exit 1
  end

  missing = versions_sorted.reject { |v| version_timings.key?(v) }
  if missing.any?
    warn "ERROR: versions #{missing.join(', ')} not found in #{json_path}."
    warn "Available: #{version_timings.keys.join(', ')}"
    exit 1
  end

  baseline    = versions_sorted.first
  show_paths  = chart_cfg[:paths] || [:c, :rb]
  color_idx   = 0

  # One series per (version, path) pair vs baseline, filtered by paths:
  versions_sorted[1..].each do |ver|
    label_suffix = versions_sorted.size > 2 ? " (v#{ver})" : ""

    { c: "C accelerated", rb: "Ruby path" }.each do |path_key, path_label|
      next unless show_paths.include?(path_key)

      path_str = path_key.to_s
      rows = []

      version_timings[baseline].each do |filename, base_data|
        ver_data = version_timings.dig(ver, filename)
        next unless ver_data

        base_t = base_data[path_str]&.to_f
        ver_t  = ver_data[path_str]&.to_f
        next unless base_t && ver_t && ver_t > 0

        label = File.basename(filename, ".*")
        label = label[0..29] + "…" if label.length > 30
        all_filenames |= [label]
        rows << { file: label, ratio: base_t / ver_t }
      end

      color  = ChartConfig::SERIES_COLORS[color_idx % ChartConfig::SERIES_COLORS.size]
      shape  = path_key == :c ? :circle : :square
      color_idx += 1

      series_list << { name: "#{path_label}#{label_suffix}", color: color, shape: shape, rows: rows }
    end
  end

  title_detail = "v#{versions_sorted.last} vs v#{baseline}"

when :adapters
  baseline_version = chart_cfg[:baseline_version]
  baseline_path    = chart_cfg[:baseline_path].to_s  # "c" or "rb"
  adapter_names    = chart_cfg[:adapters]

  unless version_timings.key?(baseline_version)
    warn "ERROR: baseline_version #{baseline_version} not found in #{json_path}."
    warn "Available: #{version_timings.keys.join(', ')}"
    exit 1
  end

  adapter_names.each_with_index do |adapter_name, idx|
    rows = []

    results.each do |filename, file_data|
      base_data = version_timings.dig(baseline_version, filename)
      next unless base_data

      base_t    = base_data[baseline_path]&.to_f
      adapter_t = file_data.dig(adapter_name, "time")&.to_f
      next unless base_t && adapter_t && adapter_t > 0

      label = File.basename(filename, ".*")
      label = label[0..29] + "…" if label.length > 30

      all_filenames |= [label]
      rows << { file: label, ratio: base_t / adapter_t }
    end

    color = ChartConfig::SERIES_COLORS[idx % ChartConfig::SERIES_COLORS.size]
    shape = idx.even? ? :circle : :square
    # Shorten adapter label for legend
    short_name = adapter_name.sub(/\s*\(.*\)/, "").strip
    short_name = short_name[0..34] + "…" if short_name.length > 35

    series_list << { name: short_name, color: color, shape: shape, rows: rows }
  end

  title_detail = "vs SmarterCSV #{baseline_version} (#{baseline_path == 'c' ? 'C accelerated' : 'Ruby path'})"
end

# ── Merge into row list sorted by primary series ──────────────────────────────

primary = series_list.first&.dig(:rows) || []
sorted_files = primary.sort_by { |r| -r[:ratio] }.map { |r| r[:file] }
# Append any filenames only in secondary series
sorted_files += (all_filenames - sorted_files)

rows = sorted_files.map do |label|
  points = series_list.map do |s|
    s[:rows].find { |r| r[:file] == label }&.dig(:ratio)
  end
  { file: label, points: points }
end

rows.reject! { |r| r[:points].all?(&:nil?) }

# ── Scale ─────────────────────────────────────────────────────────────────────

ALL_TICKS = [0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200].freeze

all_ratios = rows.flat_map { |r| r[:points] }.compact
max_ratio  = all_ratios.max || 2.0
min_ratio  = all_ratios.min || 0.5

# Always include 1× on axis; extend both directions as needed
chart_max = ALL_TICKS.find { |t| t >= [max_ratio * 1.1, 1.0].max } || ALL_TICKS.last
chart_min = ALL_TICKS.reverse.find { |t| t <= [min_ratio / 1.1, 1.0].min } || ALL_TICKS.first
chart_min = [chart_min, 0.1].max

ticks = ALL_TICKS.select { |t| t >= chart_min && t <= chart_max }

# ── Dimensions ────────────────────────────────────────────────────────────────

NAME_W    = 220
CHART_W   = 580
PAD_R     = 20
TOTAL_W   = NAME_W + CHART_W + PAD_R
ROW_H     = 26
HEADER_H  = 60
LEGEND_H  = 20 * series_list.size + 28
TOTAL_H   = HEADER_H + rows.size * ROW_H + LEGEND_H
FONT      = "ui-monospace, 'Cascadia Code', 'Courier New', monospace"

# ── Helpers ───────────────────────────────────────────────────────────────────

def log_x(ratio, chart_min, chart_max)
  log_ratio = Math.log10([ratio, 1e-6].max)
  log_min   = Math.log10(chart_min)
  log_max   = Math.log10(chart_max)
  ((log_ratio - log_min) / (log_max - log_min) * CHART_W).round.clamp(0, CHART_W)
end

def fmt_ratio(r)
  r >= 10 ? format("%.0f×", r) : format("%.1f×", r)
end

def xml_escape(str)
  str.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
end

def marker_svg(shape, cx, cy, color)
  case shape
  when :circle then %(<circle cx="#{cx}" cy="#{cy}" r="5" fill="#{color}"/>)
  when :square then %(<rect x="#{cx - 5}" y="#{cy - 5}" width="10" height="10" fill="#{color}"/>)
  end
end

# ── SVG ───────────────────────────────────────────────────────────────────────

svg = []
svg << <<~SVG.strip
  <svg xmlns="http://www.w3.org/2000/svg" width="#{TOTAL_W}" height="#{TOTAL_H}"
       font-family="#{FONT}" font-size="12">
SVG

svg << %(<rect width="#{TOTAL_W}" height="#{TOTAL_H}" fill="#ffffff"/>)

title_text = "#{chart_cfg[:title]}  —  #{title_detail}  —  Ruby #{ruby_version}  [log scale, best of #{iterations}]"
svg << %(<text x="#{TOTAL_W / 2}" y="20" text-anchor="middle" font-size="13" ) +
       %(font-weight="bold" fill="#212121">#{xml_escape(title_text)}</text>)

# Sub-title: baseline explanation
baseline_note = case chart_cfg[:type]
                when :versions then "Speedup ratio = baseline version time ÷ newer version time  (higher = newer version is faster)"
                when :adapters then "Speedup ratio = SmarterCSV #{chart_cfg[:baseline_version]} time ÷ adapter time  (higher = adapter is faster)"
                end
svg << %(<text x="#{TOTAL_W / 2}" y="36" text-anchor="middle" font-size="10" fill="#9e9e9e">) +
       %(#{xml_escape(baseline_note)}</text>)

# Tick lines + labels
ticks.each do |t|
  x = NAME_W + log_x(t, chart_min, chart_max)
  svg << %(<line x1="#{x}" y1="#{HEADER_H - 18}" x2="#{x}" ) +
         %(y2="#{HEADER_H + rows.size * ROW_H}" stroke="#e0e0e0" stroke-width="1"/>)
  svg << %(<text x="#{x}" y="#{HEADER_H - 22}" text-anchor="middle" ) +
         %(font-size="11" fill="#757575">#{t}×</text>)
end

# 1× baseline
base_x = NAME_W + log_x(1.0, chart_min, chart_max)
svg << %(<line x1="#{base_x}" y1="#{HEADER_H - 18}" x2="#{base_x}" ) +
       %(y2="#{HEADER_H + rows.size * ROW_H}" stroke="#9e9e9e" stroke-width="1.5"/>)

# Axis rule
svg << %(<line x1="#{NAME_W}" y1="#{HEADER_H - 18}" x2="#{NAME_W + CHART_W}" ) +
       %(y2="#{HEADER_H - 18}" stroke="#bdbdbd" stroke-width="1"/>)

# Rows
rows.each_with_index do |row, i|
  y  = HEADER_H + i * ROW_H
  cy = y + ROW_H / 2

  svg << %(<rect x="0" y="#{y}" width="#{TOTAL_W}" height="#{ROW_H}" ) +
         %(fill="#{i.even? ? '#f5f5f5' : '#ffffff'}"/>)

  svg << %(<text x="#{NAME_W - 8}" y="#{cy + 4}" text-anchor="end" ) +
         %(font-size="11" fill="#424242">#{xml_escape(row[:file])}</text>)

  # Collect marker positions for overlap detection
  marker_positions = []
  row[:points].each_with_index do |ratio, si|
    next unless ratio
    s = series_list[si]
    mx = NAME_W + log_x(ratio, chart_min, chart_max)
    marker_positions << { x: mx, ratio: ratio, color: s[:color], shape: s[:shape] }
  end

  # Sort by x for overlap assignment
  marker_positions.sort_by! { |m| m[:x] }

  # Assign label y-offsets to avoid overlap (stack vertically if within 50px)
  label_slots = []
  marker_positions.each do |m|
    slot = label_slots.find { |s| (s[:last_x] - m[:x]).abs < 50 }
    if slot
      slot[:count] += 1
      slot[:last_x] = m[:x]
      m[:label_dy] = slot[:count] * 11 - 4
    else
      label_slots << { last_x: m[:x], count: 0 }
      m[:label_dy] = 4
    end
  end

  marker_positions.each do |m|
    svg << marker_svg(m[:shape], m[:x], cy, m[:color])
    lbl = fmt_ratio(m[:ratio])
    lx  = m[:x] + 8
    lx  = m[:x] - 8 - lbl.length * 7 if lx + lbl.length * 7 > NAME_W + CHART_W
    svg << %(<text x="#{lx}" y="#{cy + m[:label_dy]}" font-size="10" fill="#{m[:color]}">#{lbl}</text>)
  end
end

# Legend
legend_y = HEADER_H + rows.size * ROW_H + 14
series_list.each_with_index do |s, i|
  ly = legend_y + i * 20
  svg << marker_svg(s[:shape], NAME_W + 8, ly, s[:color])
  svg << %(<text x="#{NAME_W + 20}" y="#{ly + 4}" font-size="11" fill="#{s[:color]}">#{xml_escape(s[:name])}</text>)
end

svg << "</svg>"

# ── Save ──────────────────────────────────────────────────────────────────────

svg_path = File.realpath(json_path).sub(/\.json$/, "_#{chart_name}_chart.svg")
File.write(svg_path, svg.join("\n"))
puts "Chart saved to: #{svg_path}"
