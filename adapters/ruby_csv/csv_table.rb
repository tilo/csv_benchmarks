# frozen_string_literal: true

require_relative "../base"
require "csv"

module Adapters
  module RubyCSV
    # Full SmarterCSV-equivalent wrapper using Ruby's CSV library.
    #
    # Replicates SmarterCSV default behaviour:
    #   - Strip BOM and handle invalid UTF-8 bytes
    #   - Downcase and strip headers; replace blanks with column_N
    #   - Suffix duplicate headers: name, name_1, name_2, …
    #   - Symbolize all header keys
    #   - Strip whitespace from string values
    #   - Remove nil/empty values from each hash (remove_empty_values)
    #   - Remove all-empty rows (remove_empty_hashes)
    #   - Convert numeric strings to Integer or Float (convert_values_to_numeric)
    #
    # Source: benchmark/benchmark_ruby_csv.rb in the smarter_csv repo.
    class CsvTable < Base
      def name = "CSV.table (smarter_csv-equivalent)"

      def call(filepath)
        # Read with BOM stripping and UTF-8 invalid byte replacement
        content = File.read(filepath, mode: "r:bom|utf-8",
                                      invalid: :replace, replace: "")

        csv = CSV.new(content, headers: true,
                               header_converters: nil,
                               converters: nil)

        raw_headers = csv.first&.headers || []
        csv.rewind

        # Build normalized symbol headers matching SmarterCSV defaults:
        #   downcase, strip, handle blanks (column_N), handle duplicates (_N suffix)
        counts  = Hash.new(0)
        headers = raw_headers.map.with_index do |h, idx|
          key = (h || "").strip.downcase
          key = "column_#{idx + 1}" if key.empty?

          counts[key] += 1
          key += counts[key].to_s if counts[key] > 1  # matches SmarterCSV: duplicate_header_suffix: ''
          key.to_sym
        end

        result = []

        csv.each do |row|
          # remove_empty_hashes: skip rows where all fields are nil/blank
          next if row.fields.all? { |v| v.nil? || v.strip.empty? }

          hash = {}

          headers.each_with_index do |key, idx|
            value = row[idx]
            next if value.nil?

            value = value.strip
            next if value.empty? # remove_empty_values

            # convert_values_to_numeric
            # .match? avoids MatchData allocation — measurable in tight loops
            value = if value.match?(/\A-?\d+\.\d+\z/)
                      value.to_f
                    elsif value.match?(/\A-?\d+\z/)
                      value.to_i
                    else
                      value
                    end

            hash[key] = value
          end

          result << hash unless hash.empty?
        end

        result
      end
    end
  end
end
