# frozen_string_literal: true

require "smarter_csv"

# Add project root to load path so `require "adapters/..."` works
root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(root) unless $LOAD_PATH.include?(root)

# ZSV: optional — load from local build if present
zsv_lib = File.join(Dir.home, "GitHub", "zsv-ruby", "lib")
$LOAD_PATH.unshift(zsv_lib) if Dir.exist?(zsv_lib) && !$LOAD_PATH.include?(zsv_lib)

require "adapters/ruby_csv/csv_read"
require "adapters/ruby_csv/csv_hashes"
require "adapters/ruby_csv/csv_table"
require "adapters/smarter_csv/default"
require "adapters/smarter_csv/ruby_path"
require "adapters/zsv/zsv_raw"
require "adapters/zsv/zsv_wrapped"

require "support/equivalence_helper"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.order = :random
  config.seed  = rand(0xFFFF)
end
