# frozen_string_literal: true

require_relative "../base"
require "csv"

module Adapters
  module RubyCSV
    class CsvRead < Base
      def name        = "CSV.read (raw arrays)"
      def label       = "CSV.read"
      def output_type = :raw

      def call(filepath, col_sep: ",", **_)
        CSV.read(filepath, col_sep: col_sep)
      end
    end
  end
end
