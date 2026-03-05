# frozen_string_literal: true

require_relative "../base"
require "csv"

module Adapters
  module RubyCSV
    class CsvHashes < Base
      def name        = "CSV.read (raw hashes, string keys)"
      def label       = "CSV.hashes"
      def output_type = :raw  # string keys, no numeric conversion — not equivalent to SmarterCSV

      def call(filepath, col_sep: ",", quote_char: '"', liberal_parsing: false, **_)
        CSV.read(filepath, headers: true, col_sep: col_sep, quote_char: quote_char, liberal_parsing: liberal_parsing).map(&:to_h)
      end
    end
  end
end
