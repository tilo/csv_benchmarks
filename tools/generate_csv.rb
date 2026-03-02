#!/usr/bin/env ruby
# frozen_string_literal: true
#
# tools/generate_csv.rb — Generate synthetic CSV from a profile .txt file
#
# Reads a profile produced by tools/csv_profile.rb and writes a synthetic CSV
# that matches its statistical characteristics exactly (fixed-width files) or
# approximately (variable-width files).
#
# Usage:
#   ruby tools/generate_csv.rb profile.txt output.csv
#   ROWS=20000 SEED=42 ruby tools/generate_csv.rb profile.txt output.csv
#   HEADER=0 ruby tools/generate_csv.rb profile.txt output.csv   # skip header row
#
# Ported from benchmark/generate_csv.rb in the smarter_csv repo.

profile_path = ARGV[0] || abort("Usage: ruby #{File.basename(__FILE__)} profile.txt out.csv")
out_path     = ARGV[1] || abort("Usage: ruby #{File.basename(__FILE__)} profile.txt out.csv")

abort "Profile not found: #{profile_path}" unless File.exist?(profile_path)

text = File.read(profile_path)

seed = (ENV["SEED"] || Random.new_seed).to_i
rng  = Random.new(seed)

# ─── PROFILE PARSERS ────────────────────────────────────────────────────────

def extract_int(text, label)
  m = text.match(/^\s*#{Regexp.escape(label)}\s+([0-9][0-9,]*)/i)
  return nil unless m

  m[1].delete(",").to_i
end

def extract_float(text, label)
  m = text.match(/^\s*#{Regexp.escape(label)}\s+([0-9]+(?:\.[0-9]+)?)/i)
  return nil unless m

  m[1].to_f
end

def extract_percent(text, label)
  m = text.match(/^\s*#{Regexp.escape(label)}\s+[0-9][0-9,]*\s+\(([0-9]+(?:\.[0-9]+)?)%\)/i)
  return nil unless m

  m[1].to_f / 100.0
end

def extract_sep(text, label)
  m = text.match(/^\s*#{Regexp.escape(label)}\s+(\\r\\n|\\n|\\r|.+?)\s{2,}/i)
  return nil unless m

  raw = m[1].strip
  case raw
  when "\\r\\n" then "\r\n"
  when "\\n"    then "\n"
  when "\\r"    then "\r"
  else raw
  end
end

def extract_char(text, label)
  m = text.match(/^\s*#{Regexp.escape(label)}\s+"(.*)"\s*$/i)
  return nil unless m

  val = m[1]
  val.gsub('\\"', '"').gsub("\\\\", "\\")
end

# ─── PARSE PROFILE ──────────────────────────────────────────────────────────

cols = extract_int(text, "Header columns") || abort("Couldn't parse: Header columns")
rows = extract_int(text, "Logical data rows") || abort("Couldn't parse: Logical data rows")

rows = ENV["ROWS"].to_i if ENV["ROWS"] && ENV["ROWS"].to_i > 0

col_sep    = extract_char(text, "Column separator") || ","
row_sep    = extract_sep(text, "Row separator")     || "\n"
quote_char = extract_char(text, "Quote character")

total_fields   = extract_int(text, "Total fields (parsed)") || (rows * cols)
empty_fields   = extract_int(text, "Empty fields")          || 0
numeric_fields = extract_int(text, "Numeric fields")        || 0

leading_space_rate  = extract_percent(text, "Leading-space fields")  || 0.0
trailing_space_rate = extract_percent(text, "Trailing-space fields") || 0.0

# Field length block
flen_min = flen_max = flen_mean = flen_med = flen_p90 = flen_p99 = nil

fld = text.match(/── FIELD LENGTH\b.*?── LINE GEOMETRY\b/m)
if fld
  block    = fld[0]
  flen_min  = extract_int(block, "Min")
  flen_max  = extract_int(block, "Max")
  flen_mean = extract_float(block, "Mean")
  flen_med  = extract_int(block, "Median")
  flen_p90  = extract_int(block, "p90")
  flen_p99  = extract_int(block, "p99")
end

flen_min  ||= 1
flen_max  ||= [flen_min, 30].max
flen_mean ||= ((flen_min + flen_max) / 2.0)
flen_med  ||= flen_min
flen_p90  ||= flen_med
flen_p99  ||= flen_max

# Line geometry block
row_len_min = row_len_max = row_len_mean = cv = nil

geom_block = text.match(/── LINE GEOMETRY\b.*?\n\s*Profiled in\b/m)
if geom_block
  block        = geom_block[0]
  row_len_min  = extract_int(block,   "Min length (bytes)")
  row_len_max  = extract_int(block,   "Max length (bytes)")
  row_len_mean = extract_float(block, "Mean (bytes)")
  cv           = extract_float(block, "CV")
end

header_enabled = ENV["HEADER"].nil? || ENV["HEADER"].to_i != 0

sep_len      = col_sep.bytesize
commas_bytes = (cols - 1) * sep_len

fixed_width = row_len_min && row_len_max && row_len_min == row_len_max

target_row_bytes =
  if fixed_width
    row_len_min
  elsif row_len_mean
    row_len_mean.round
  else
    (flen_mean * cols + commas_bytes).round
  end

empties_per_row_base = empty_fields / rows
empties_remainder    = empty_fields % rows

numeric_per_row_base = numeric_fields / rows
numeric_remainder    = numeric_fields % rows

# ─── FIELD GENERATION ───────────────────────────────────────────────────────

def sample_length_from_quantiles(rng, min, med, p90, p99, max)
  x = rng.rand
  if x < 0.50
    rng.rand(min..med)
  elsif x < 0.90
    rng.rand(med..p90)
  elsif x < 0.99
    rng.rand(p90..p99)
  else
    rng.rand(p99..max)
  end
end

def make_field(rng, len:, want_leading_space:, want_trailing_space:, numeric:, col_sep:, quote_char:)
  return "" if len == 0

  inner_len = len
  s = +""

  if want_leading_space && inner_len > 0
    s << " "
    inner_len -= 1
  end

  trailing = false
  if want_trailing_space && inner_len > 0
    inner_len -= 1
    trailing = true
  end

  if inner_len > 0
    if numeric
      inner = inner_len.times.map { rng.rand(0..9).to_s }.join
    else
      alphabet = ("A".."Z").to_a + ("a".."z").to_a + ("0".."9").to_a
      inner = inner_len.times.map { alphabet[rng.rand(alphabet.length)] }.join
    end
    s << inner
  end

  s << " " if trailing

  # Safety: strip forbidden chars and ensure exact byte length
  s = s.delete("\r\n")
  s = s.gsub(col_sep, "X")
  s = s.gsub(quote_char, "X") if quote_char && !quote_char.empty?
  s = s.byteslice(0, len)
  s = s.ljust(len, " ")
  s
end

# ─── WRITE OUTPUT ───────────────────────────────────────────────────────────

File.open(out_path, "wb") do |f|
  if header_enabled
    header_row = (1..cols).map { |i| format("col_%03d", i) }.join(col_sep) + row_sep
    f.write(header_row)
  end

  rows.times do |r|
    empties_this_row = empties_per_row_base + (r < empties_remainder ? 1 : 0)

    fields_bytes_target = target_row_bytes - commas_bytes
    if fields_bytes_target < 0
      raise "Impossible: target_row_bytes=#{target_row_bytes} smaller than " \
            "separator overhead=#{commas_bytes}"
    end

    lengths     = Array.new(cols, 0)
    empty_set   = (0...cols).to_a.sample(empties_this_row, random: rng).to_h { |i| [i, true] }
    non_empty   = (0...cols).reject { |i| empty_set[i] }

    non_empty.each { |i| lengths[i] = sample_length_from_quantiles(rng, flen_min, flen_med, flen_p90, flen_p99, flen_max) }

    # Adjust lengths to hit exact byte target (required for fixed-width files)
    delta = fields_bytes_target - lengths.sum

    if delta != 0 && non_empty.any?
      idx_cycle = non_empty.shuffle(random: rng)
      j = 0
      safety = 0

      while delta != 0
        safety += 1
        raise "Adjustment loop stuck (delta=#{delta})" if safety > 5_000_000

        i = idx_cycle[j % idx_cycle.length]
        j += 1

        if delta > 0
          if lengths[i] < flen_max
            lengths[i] += 1
            delta -= 1
          end
        else
          if lengths[i] > flen_min
            lengths[i] -= 1
            delta += 1
          end
        end

        if j % idx_cycle.length == 0
          break if delta > 0 && idx_cycle.all? { |k| lengths[k] >= flen_max }
          break if delta < 0 && idx_cycle.all? { |k| lengths[k] <= flen_min }
        end
      end
    end

    numeric_this_row = numeric_per_row_base + (r < numeric_remainder ? 1 : 0)
    numeric_set      = non_empty.sample([numeric_this_row, non_empty.length].min, random: rng)
                               .to_h { |i| [i, true] }

    fields = Array.new(cols, "")
    (0...cols).each do |i|
      len = lengths[i]
      next if len == 0

      fields[i] = make_field(
        rng,
        len: len,
        want_leading_space:  rng.rand < leading_space_rate,
        want_trailing_space: rng.rand < trailing_space_rate,
        numeric: numeric_set[i] || false,
        col_sep: col_sep,
        quote_char: quote_char || '"'
      )
    end

    line = fields.join(col_sep)

    if fixed_width && line.bytesize != target_row_bytes
      raise "Row #{r + 1}: expected #{target_row_bytes} bytes, got #{line.bytesize}"
    end

    f.write(line)
    f.write(row_sep)
  end
end

# ─── SUMMARY ────────────────────────────────────────────────────────────────

puts "Generated: #{out_path}"
puts "Seed:      #{seed}"
puts "Cols:      #{cols}"
puts "Rows:      #{rows} (data)"
puts "col_sep:   #{col_sep.inspect} (#{col_sep.bytesize} bytes)"
puts "row_sep:   #{row_sep.inspect}"
puts "Fixed-width: #{fixed_width}"
puts "Target row bytes (excl row_sep): #{target_row_bytes}"
puts "Empty fields:   #{empty_fields} (distributed exactly)"
puts "Numeric fields: #{numeric_fields} (distributed exactly)"
puts "Field length quantiles: min=#{flen_min}, med=#{flen_med}, p90=#{flen_p90}, p99=#{flen_p99}, max=#{flen_max}"
puts "Leading-space rate target:  #{(leading_space_rate * 100).round(2)}%"
puts "Trailing-space rate target: #{(trailing_space_rate * 100).round(2)}%"
