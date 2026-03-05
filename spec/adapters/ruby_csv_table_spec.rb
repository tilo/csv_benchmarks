# frozen_string_literal: true

require "spec_helper"

RSpec.describe Adapters::RubyCSV::CsvTable do
  subject { described_class.new }

  # CSV.table is used for timing only (output_type: :raw).
  # Duplicate header handling differs from SmarterCSV, so duplicates.csv is excluded.
  Dir[File.expand_path("../../fixtures/*.csv", __FILE__)].sort
    .reject { |f| File.basename(f) == "duplicates.csv" }
    .each do |fixture|
      it_behaves_like "equivalent to SmarterCSV", fixture
    end
end
