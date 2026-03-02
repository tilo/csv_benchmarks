# frozen_string_literal: true

# Custom matcher: compares two Array<Hash> outputs field by field.
# Reports the first 5 mismatches rather than dumping full arrays.
RSpec::Matchers.define :have_equivalent_output_to do |reference|
  match do |result|
    @failures = []

    if result.size != reference.size
      @failures << "row count: expected #{reference.size}, got #{result.size}"
      return false
    end

    reference.each_with_index do |ref_row, i|
      unless result[i].keys.sort == ref_row.keys.sort
        @failures << "row #{i} keys: expected #{ref_row.keys.sort}, got #{result[i].keys.sort}"
        next
      end

      ref_row.each do |key, ref_val|
        got = result[i][key]
        unless got == ref_val
          @failures << "row #{i}[:#{key}]: expected #{ref_val.inspect} (#{ref_val.class}), " \
                       "got #{got.inspect} (#{got.class})"
        end
      end
    end

    @failures.empty?
  end

  failure_message do
    details = @failures.first(5).map { |f| "  - #{f}" }.join("\n")
    "Output not equivalent to SmarterCSV reference:\n#{details}"
  end
end

# Shared examples used by each :equivalent adapter spec.
# The adapter must be set as `subject` in the describe block.
shared_examples "equivalent to SmarterCSV" do |fixture_path|
  let(:reference) { SmarterCSV.process(fixture_path) }
  let(:result)    { subject.call(fixture_path) }

  it "returns the same number of rows as SmarterCSV for #{File.basename(fixture_path)}" do
    expect(result.size).to eq reference.size
  end

  it "returns only Symbol keys for #{File.basename(fixture_path)}" do
    result.each { |row| expect(row.keys).to all(be_a(Symbol)) }
  end

  it "produces output equivalent to SmarterCSV for #{File.basename(fixture_path)}" do
    expect(result).to have_equivalent_output_to(reference)
  end
end
