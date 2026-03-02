# frozen_string_literal: true

require_relative "../base"
require "csv"

module Adapters
  module RubyCSV
    class CsvTable < Base
      def name        = "CSV.table (symbol keys + numeric conversion)"
      def label       = "CSV.table"
      def output_type = :raw

      def call(filepath)
        CSV.table(filepath).map(&:to_h)
      end
    end
  end
end
