# frozen_string_literal: true

require_relative "../base"
require "smarter_csv"

module Adapters
  module SmarterCSVAdapter
    # SmarterCSV with C acceleration (default). This is the reference output
    # that all :equivalent adapters must match.
    class Default < Base
      def name = "SmarterCSV.process (C accelerated)"

      def call(filepath)
        SmarterCSV.process(filepath)
      end
    end
  end
end
