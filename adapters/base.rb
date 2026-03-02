# frozen_string_literal: true

module Adapters
  class Base
    # Human-readable label used in tables and output.
    def name
      raise NotImplementedError, "#{self.class}#name not implemented"
    end

    # Parse the CSV file at filepath.
    #   :equivalent adapters → Array<Hash> with symbol keys
    #   :raw adapters        → Array<Array<String>>
    def call(filepath)
      raise NotImplementedError, "#{self.class}#call not implemented"
    end

    # Return false if the required gem/library is not installed.
    # Benchmarks skip unavailable adapters with a warning, not an error.
    def available?
      true
    end

    # :equivalent → output should match SmarterCSV reference output
    # :raw        → raw arrays, exempt from equivalence tests
    def output_type
      :equivalent
    end
  end
end
