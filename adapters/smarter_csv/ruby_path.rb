# frozen_string_literal: true

require_relative "../base"
require "smarter_csv"

module Adapters
  module SmarterCSVAdapter
    # SmarterCSV with the C acceleration disabled. Measures the pure-Ruby
    # parsing path so you can quantify the C extension's contribution.
    class RubyPath < Base
      def name  = "SmarterCSV.process (no acceleration)"
      def label = "SmarterCSV/Rb"

      def call(filepath, **opts)
        SmarterCSV.process(filepath, opts.merge(acceleration: false))
      end
    end
  end
end
