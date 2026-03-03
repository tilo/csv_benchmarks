# frozen_string_literal: true

require_relative "../base"
require "csv"

module Adapters
  module RubyCSV
    class CsvTable < Base
      def name        = "CSV.table (symbol keys + numeric conversion)"
      def label       = "CSV.table"
      def output_type = :raw

      def call(filepath, col_sep: ",", **_)
        CSV.table(filepath, col_sep: col_sep).map(&:to_h)
      end
    end
  end
end
