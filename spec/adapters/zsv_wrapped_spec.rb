# frozen_string_literal: true

require "spec_helper"

RSpec.describe Adapters::ZSV::ZsvWrapped do
  subject { described_class.new }

  before do
    skip "ZSV not available (see README for setup)" unless subject.available?
  end

  Dir[File.expand_path("../../fixtures/*.csv", __FILE__)].sort.each do |fixture|
    it_behaves_like "equivalent to SmarterCSV", fixture
  end
end
