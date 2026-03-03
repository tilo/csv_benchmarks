# frozen_string_literal: true

require_relative "../base"
require "csv"

module Adapters
  module RubyCSV
    class CsvHashes < Base
      def name        = "CSV.read (raw hashes, string keys)"
      def label       = "CSV.hashes"
      def output_type = :raw  # string keys, no numeric conversion — not equivalent to SmarterCSV

      def call(filepath, col_sep: ",", **_)
        CSV.read(filepath, headers: true, col_sep: col_sep).map(&:to_h)
      end
    end
  end
end
