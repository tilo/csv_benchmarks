# frozen_string_literal: true

require "spec_helper"

RSpec.describe Adapters::RubyCSV::CsvTable do
  subject { described_class.new }

  Dir[File.expand_path("../../fixtures/*.csv", __FILE__)].sort.each do |fixture|
    it_behaves_like "equivalent to SmarterCSV", fixture
  end
end
