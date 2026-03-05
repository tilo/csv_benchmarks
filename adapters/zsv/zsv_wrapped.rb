# frozen_string_literal: true

require_relative "../base"

module Adapters
  module ZSV
    # Full SmarterCSV-equivalent wrapper via ZSV.
    #
    # Applies the same post-processing that SmarterCSV provides out of the box:
    #   - Header normalization (strip, downcase, symbolize, duplicate/blank handling)
    #   - Strip whitespace from string values
    #   - Remove nil/empty values (remove_empty_values)
    #   - Remove all-empty rows (remove_empty_hashes)
    #   - Convert numeric strings to Integer or Float (convert_values_to_numeric)
    #
    # Source: benchmark/compare_with_zsv.rb in the smarter_csv repo.
    #
    # NOTE: zsv-ruby 1.3.1 has a GC marking bug on Ruby 3.4.x that causes crashes
    # on large files. GC is disabled during ZSV calls. This gives ZSV a slight
    # speed advantage (no GC pauses during its run) — noted in benchmark output.
    class ZsvWrapped < Base
      def name  = "ZSV + wrapper (smarter_csv-equivalent)"
      def label = "ZSV+wrapper"

      def available?
        require "zsv"
        true
      rescue LoadError
        false
      end

      def accepts?(**opts)
        opts.fetch(:col_sep, ",").length == 1  # ZSV supports single-char delimiters only
      end

      def call(filepath, col_sep: ",", quote_char: '"', liberal_parsing: false, **_)
        GC.disable
        raw = ::ZSV.read(filepath, col_sep: col_sep, quote_char: quote_char, liberal_parsing: liberal_parsing)
        GC.enable

        return [] if raw.empty?

        # Header normalization: strip, downcase, replace spaces/specials with _,
        # handle blanks (column_N), handle duplicates (_N suffix), symbolize.
        counts  = Hash.new(0)
        headers = raw[0].map.with_index do |h, idx|
          key = (h || "").strip.downcase.gsub(/\s+/, "_").gsub(/[^\w]/, "")
          key = "column_#{idx + 1}" if key.empty?

          counts[key] += 1
          key += counts[key].to_s if counts[key] > 1  # matches SmarterCSV: duplicate_header_suffix: ''
          key.to_sym
        end

        results = []
        i       = 1
        len     = raw.size

        while i < len
          row = raw[i]
          i  += 1

          hash = {}
          headers.each_with_index do |key, j|
            val = row[j]
            next if val.nil? || val.empty? # remove_empty_values

            val = val.strip
            next if val.empty?

            # convert_values_to_numeric
            val = if val.match?(/\A-?\d+\z/)
                    val.to_i
                  elsif val.match?(/\A-?\d+\.\d+\z/)
                    val.to_f
                  else
                    val
                  end

            hash[key] = val
          end

          results << hash unless hash.empty? # remove_empty_hashes
        end

        results
      end
    end
  end
end
