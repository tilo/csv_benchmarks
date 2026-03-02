#!/usr/bin/env ruby
# frozen_string_literal: true
#
# tools/csv_profile.rb — CSV file complexity profiler (stdlib only, no gems)
#
# Produces ~30 metrics in a single run, useful for understanding parsing
# complexity before benchmarking or selecting representative test files.
# The output format is machine-readable by tools/generate_csv.rb.
#
# Usage:
#   ruby tools/csv_profile.rb <file.csv>
#   ruby tools/csv_profile.rb <file.csv> <col_sep> [quote_char]
#
# Three passes:
#   1. Binary    — file size, line lengths/geometry, row separator, UTF-8 encoding
#   2. Raw text  — quoting style (token split, approx) + multiline detection
#   3. CSV parse — logical rows, field content & lengths (Ruby's CSV library)
#
# Ported from benchmark/csv_profile.rb in the smarter_csv repo.

require "csv"

abort "Usage: #{$PROGRAM_NAME} <file.csv> [col_sep] [quote_char]" if ARGV.empty?

filepath   = ARGV[0]
col_sep    = ARGV[1]        # nil = auto-detect below
quote_char = ARGV[2] || '"'

abort "File not found: #{filepath}" unless File.exist?(filepath)

t_start = Time.now

# ─── HELPERS ────────────────────────────────────────────────────────────────

def fmt_bytes(n)
  case n
  when 0...1_024                 then "#{n} B"
  when 1_024...1_048_576         then "#{(n / 1_024.0).round(1)} KB"
  when 1_048_576...1_073_741_824 then "#{(n / 1_048_576.0).round(2)} MB"
  else                                "#{(n / 1_073_741_824.0).round(2)} GB"
  end
end

def pct(n, total)
  total.zero? ? "–" : format("%.2f%%", n.to_f / total * 100)
end

def mean(arr)
  arr.empty? ? 0.0 : arr.sum.to_f / arr.size
end

def stddev(arr, avg = nil)
  return 0.0 if arr.size < 2

  avg ||= mean(arr)
  Math.sqrt(arr.sum { |x| (x - avg)**2 } / arr.size.to_f)
end

def percentile(sorted_arr, p)
  return 0 if sorted_arr.empty?

  sorted_arr[((p / 100.0) * (sorted_arr.size - 1)).round]
end

def section(title)
  puts "\n── #{title} ".ljust(70, "─")
end

def metric(label, value, flag = nil)
  line = format("  %-44s %s", label, value.to_s)
  line += "  ◀ #{flag}" if flag
  puts line
end

# ─── PASS 1: BINARY SCAN ────────────────────────────────────────────────────

file_size       = File.size(filepath)
physical_lines  = 0
line_lengths    = []   # bytesize of each physical line, endings stripped
crlf_count      = 0
lf_count        = 0
cr_only_count   = 0
total_chars     = 0
multibyte_chars = 0
invalid_chars   = 0

File.open(filepath, "rb") do |f|
  f.each_line do |raw|
    physical_lines += 1

    if raw.end_with?("\r\n")
      crlf_count += 1
    elsif raw.end_with?("\r")
      cr_only_count += 1
    else
      lf_count += 1
    end
    line_lengths << raw.chomp.bytesize

    utf8 = raw.dup.force_encoding("UTF-8")
    if utf8.valid_encoding?
      utf8.each_char do |c|
        total_chars     += 1
        multibyte_chars += 1 if c.bytesize > 1
      end
    else
      clean = utf8.encode("UTF-8", invalid: :replace, undef: :replace, replace: "\uFFFD")
      clean.each_char do |c|
        total_chars += 1
        if c == "\uFFFD"
          invalid_chars += 1
        else
          multibyte_chars += 1 if c.bytesize > 1
        end
      end
    end
  end
end

row_sep_label =
  if crlf_count > 0 && crlf_count >= [lf_count, cr_only_count].max
    "\\r\\n  (CRLF — Windows)"
  elsif cr_only_count > lf_count
    "\\r  (CR-only — classic Mac)"
  else
    "\\n  (LF — Unix)"
  end

# ─── AUTO-DETECT COLUMN SEPARATOR ───────────────────────────────────────────

unless col_sep
  candidates = { "," => 0, ";" => 0, "\t" => 0, "|" => 0 }
  File.foreach(filepath).first(21).drop(1).each do |line|
    candidates.each_key { |s| candidates[s] += line.count(s) }
  end
  col_sep = candidates.max_by { |_, v| v }&.first || ","
end

col_sep_label = col_sep == "\t" ? "\\t  (TAB)" : col_sep.inspect

# ─── PASS 2: RAW SCAN — QUOTING + MULTILINE ─────────────────────────────────

raw_quoted_fields   = 0
raw_unquoted_fields = 0
doubled_escapes     = 0
backslash_escapes   = 0

rows_phys_lines = []
in_quote        = false
phys_in_row     = 1
header_skipped  = false

File.open(filepath, "rb") do |f|
  f.each_line do |raw|
    line = raw.encode("UTF-8", "binary", invalid: :replace, undef: :replace).chomp

    unless header_skipped
      header_skipped = true
      next
    end

    # Quoting stats (token split — approximate)
    line.split(col_sep, -1).each do |tok|
      if tok.start_with?(quote_char)
        raw_quoted_fields += 1
        inner = tok.length > 1 ? tok[1..] : ""
        doubled_escapes   += inner.scan("#{quote_char}#{quote_char}").length
        backslash_escapes += inner.scan("\\#{quote_char}").length
      else
        raw_unquoted_fields += 1
      end
    end

    # Multiline detection (char-level state machine)
    chars = line.chars
    i     = 0
    while i < chars.length
      ch = chars[i]
      if in_quote
        nxt = chars[i + 1]
        if ch == "\\" && nxt == quote_char
          i += 2
          next
        elsif ch == quote_char && nxt == quote_char
          i += 2
          next
        elsif ch == quote_char
          in_quote = false
        end
      elsif ch == quote_char
        in_quote = true
      end
      i += 1
    end

    if in_quote
      phys_in_row += 1
    else
      rows_phys_lines << phys_in_row
      phys_in_row = 1
    end
  end

  rows_phys_lines << phys_in_row if phys_in_row > 1 || !rows_phys_lines.empty?
end

multiline_data   = rows_phys_lines.select { |n| n > 1 }
multiline_rows   = multiline_data.size
max_phys_per_row = multiline_data.max || 0
extra_phys_lines = multiline_data.sum { |n| n - 1 }

# ─── PASS 3: CSV PARSE — FIELD STATS ────────────────────────────────────────

logical_rows          = 0
header_cols           = 0
total_fields          = 0
empty_fields          = 0
numeric_fields        = 0
leading_space_fields  = 0
trailing_space_fields = 0
blank_rows            = 0
wrong_col_rows        = 0
fields_with_sep       = 0
fields_with_newline   = 0
fields_with_quote     = 0
all_field_lengths     = []

numeric_re = /\A[-+]?\d+(\.\d+)?(e[-+]?\d+)?\z/i

io = File.open(filepath, encoding: "utf-8:utf-8", invalid: :replace, undef: :replace)
begin
  csv = CSV.new(io, col_sep: col_sep, quote_char: quote_char, liberal_parsing: true)

  hdr         = csv.shift
  header_cols = hdr&.size || 0

  loop do
    begin
      row_data = csv.shift
    rescue CSV::MalformedCSVError => e
      $stderr.puts "  WARN: malformed row near physical line #{io.lineno + 1}: " \
                   "#{e.message.split("\n").first}"
      $stderr.puts "  (stats reflect rows parsed before this error)"
      break
    end
    break if row_data.nil?

    logical_rows  += 1
    wrong_col_rows += 1 if header_cols > 0 && row_data.size != header_cols

    all_nil = true
    row_data.each do |field|
      total_fields += 1
      if field.nil? || field.empty?
        empty_fields += 1
        next
      end
      all_nil = false
      all_field_lengths    << field.bytesize
      leading_space_fields  += 1 if field.start_with?(" ")
      trailing_space_fields += 1 if field.end_with?(" ")
      numeric_fields        += 1 if numeric_re.match?(field)
      fields_with_sep       += 1 if field.include?(col_sep)
      fields_with_newline   += 1 if field.include?("\n") || field.include?("\r")
      fields_with_quote     += 1 if field.include?(quote_char)
    end
    blank_rows += 1 if all_nil
  end
ensure
  io.close
end

# ─── DERIVED STATS ──────────────────────────────────────────────────────────

total_raw_fields = raw_quoted_fields + raw_unquoted_fields
pct_raw_quoted   = total_raw_fields > 0 ? raw_quoted_fields.to_f / total_raw_fields * 100 : 0.0
nonempty_fields  = total_fields - empty_fields

geo_lengths = line_lengths.drop(1).reject(&:zero?)
geo_mean    = mean(geo_lengths)
geo_sd      = stddev(geo_lengths, geo_mean)
geo_cv      = geo_mean > 0 ? geo_sd / geo_mean * 100 : 0.0

fls     = all_field_lengths.sort
elapsed = Time.now - t_start

# ─── OUTPUT ─────────────────────────────────────────────────────────────────

puts
puts "=" * 70
puts "  CSV PROFILE  #{File.basename(filepath)}"
puts "=" * 70

section "FILE"
metric "Path",                     filepath
metric "File size",                fmt_bytes(file_size)
metric "Physical lines",           physical_lines
metric "Row separator",            row_sep_label

section "ENCODING"
metric "Total characters",         total_chars
metric "Multi-byte characters",    "#{multibyte_chars}  (#{pct(multibyte_chars, total_chars)})"
metric "Invalid/replaced chars",   invalid_chars,
       (invalid_chars > 0 ? "check file_encoding: option" : nil)

section "STRUCTURE"
metric "Column separator",         col_sep_label
metric "Quote character",          quote_char.inspect
metric "Header columns",           header_cols
metric "Logical data rows",        logical_rows
metric "Wrong-column-count rows",  "#{wrong_col_rows}  (#{pct(wrong_col_rows, logical_rows)})"

section "MULTILINE ROWS  (state machine — accurate)"
metric "Multiline rows",           "#{multiline_rows}  (#{pct(multiline_rows, logical_rows)})"
metric "Max physical lines / row", max_phys_per_row
metric "Extra physical lines",     extra_phys_lines

section "QUOTING  (token split — approx. when fields embed the col sep)"
univ_flag = pct_raw_quoted > 95.0 ? "UNIVERSAL — C/Ruby unquoted fast-path bypassed" : nil
metric "Quoted fields",            "#{raw_quoted_fields}  (#{format('%.2f%%', pct_raw_quoted)})", univ_flag
metric "Unquoted fields",          "#{raw_unquoted_fields}  (#{pct(raw_unquoted_fields, total_raw_fields)})"
metric "Doubled-quote escapes (\"\")", doubled_escapes
metric "Backslash escapes (\\\")",     backslash_escapes
metric "Fields with embedded sep",      "#{fields_with_sep}  (#{pct(fields_with_sep, total_fields)})"
metric "Fields with embedded newline",  "#{fields_with_newline}  (#{pct(fields_with_newline, total_fields)})"
metric "Fields with embedded quote",    "#{fields_with_quote}  (#{pct(fields_with_quote, total_fields)})"

section "FIELD CONTENT"
metric "Total fields (parsed)",    total_fields
metric "Empty fields",             "#{empty_fields}  (#{pct(empty_fields, total_fields)})"
metric "Numeric fields",           "#{numeric_fields}  (#{pct(numeric_fields, nonempty_fields)} of non-empty)"
metric "Leading-space fields",     "#{leading_space_fields}  (#{pct(leading_space_fields, total_fields)})"
metric "Trailing-space fields",    "#{trailing_space_fields}  (#{pct(trailing_space_fields, total_fields)})"
metric "Blank rows",               blank_rows

section "FIELD LENGTH  (bytes, non-empty fields only)"
if fls.empty?
  metric "No non-empty fields found", "–"
else
  metric "Min",    fls.first
  metric "Max",    fls.last
  metric "Mean",   format("%.1f", mean(fls))
  metric "Median", percentile(fls, 50)
  metric "p90",    percentile(fls, 90)
  metric "p99",    percentile(fls, 99)
end

section "LINE GEOMETRY  (data rows, excl. header & blank lines)"
if geo_lengths.empty?
  metric "No data lines found", "–"
else
  metric "Min length (bytes)",   geo_lengths.min
  metric "Max length (bytes)",   geo_lengths.max
  metric "Mean (bytes)",         format("%.1f", geo_mean)
  metric "Std deviation",        format("%.1f", geo_sd)
  fw_flag = geo_cv < 2.0 ? "LIKELY FIXED-WIDTH EXPORT" : nil
  metric "CV  (stddev / mean)",  format("%.2f%%", geo_cv), fw_flag
end

puts
puts format("  Profiled in %.2fs", elapsed)
puts "=" * 70
puts
