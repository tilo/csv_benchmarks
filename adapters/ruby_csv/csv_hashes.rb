# frozen_string_literal: true

require_relative "../base"
require "csv"

module Adapters
  module RubyCSV
    class CsvHashes < Base
      def name        = "CSV.read (raw hashes, string keys)"
      def label       = "CSV.hashes"
      def output_type = :raw  # string keys, no numeric conversion — not equivalent to SmarterCSV

      def call(filepath)
        CSV.read(filepath, headers: true).map(&:to_h)
      end
    end
  end
end
