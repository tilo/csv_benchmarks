# csv-benchmarks

A standalone benchmark suite for comparing CSV parsing approaches in Ruby.
Designed to be parser-agnostic, extensible, and **equivalence-first**: RSpec
tests verify that each adapter produces output semantically identical to
SmarterCSV's default output before any timing numbers are trusted.

## Goals

1. **Pluggable adapters** — each CSV mechanism lives in one file; adding a new
   parser means adding one file, nothing else changes.
2. **Equivalence-first** — specs prove identical output before benchmarks run.
3. **Multi-version SmarterCSV** — side-by-side comparison across gem versions
   to track regressions and improvements.
4. **Reproducible results** — benchmark output written to timestamped Markdown
   + JSON so results can be compared across runs and machines.
5. **Self-contained CSV files** — all benchmark CSV files are tracked in
   `csv_files.zip`; unzip once with `rake install` and you're ready to go.

---

## Quick Start

```bash
git clone https://github.com/your-org/csv-benchmarks
cd csv-benchmarks
bundle install

# Unzip the benchmark CSV files
rake install

# Run equivalence specs (must pass before benchmarking)
bundle exec rspec

# Run the full benchmark suite
rake bench

# Fair-group comparison (CSV.table vs SmarterCSV vs ZSV+wrapper)
rake compare

# Multi-version SmarterCSV comparison
rake versions
```

---

## CSV Benchmark Files

All benchmark CSV files are stored in `csv_files.zip` and are **not** checked
in as raw `.csv` files. To install them:

```bash
rake install       # unzips csv_files.zip → csv_files/
rake unzip_csv     # same thing, explicit name
```

The zip contains two subdirectories:

- `csv_files/actual/` — real-world files (anonymized, no PII)
- `csv_files/synthetic/` — generated stress-test files targeting specific
  parser features (quoting, embedded newlines, wide columns, unicode, etc.)

### Contributing CSV files

If you want to add CSV files to the test suite:

- **Do not commit `.csv` files directly** — they are gitignored.
- Remove all PII (Personally Identifiable Information) and HSI (Health/Sensitive
  Information) before adding any file.
- If the file is under an open license, append the license details to
  `csv_files/actual/LICENSE.md`.
- After adding your files, update the zip with:

```bash
rake zip_csv
```

Then commit the updated `csv_files.zip`.

---

## Adapters

### Fair-comparison group

All four return `Array<Hash>` with Symbol keys and numeric conversion — equivalent output.

| Adapter | Mechanism | File |
|---|---|---|
| `CSV.table` | `CSV.table(file).map(&:to_h)` | `adapters/ruby_csv/csv_table.rb` |
| `SmarterCSV` (C) | `SmarterCSV.process(file)` | `adapters/smarter_csv/default.rb` |
| `SmarterCSV` (Ruby) | `SmarterCSV.process(file, acceleration: false)` | `adapters/smarter_csv/ruby_path.rb` |
| `ZSV + wrapper` | ZSV raw + post-processing | `adapters/zsv/zsv_wrapped.rb` |

### Raw reference (not in equivalence tests)

| Adapter | Mechanism | Output |
|---|---|---|
| `CSV.read` | `CSV.read(file)` | `Array<Array<String>>` |
| `CSV.read (hashes)` | `CSV.read(file, headers: true).map(&:to_h)` | `Array<Hash>`, string keys |
| `ZSV raw` | `ZSV.read(file)` | `Array<Array<String>>` |

---

## Equivalence Definition

SmarterCSV with default options is the **reference output**. Equivalent means:

- Same number of rows
- Same keys (Symbols, downcased, whitespace-stripped)
- Same values after type coercion:
  - Integers: `"42"` → `42`
  - Floats: `"3.14"` → `3.14`
  - Whitespace stripped from string values
  - `nil`/empty values removed (key absent from hash)
  - All-empty rows removed
- Duplicate headers suffixed: `name`, `name2`, `name3`, …
- Blank headers named: `column_1`, `column_2`, …

**Known acceptable differences:**
- Scientific notation (`1.5e10`) and `+42`-style values: wrappers use simpler
  regex (`/\A-?\d+\z/`, `/\A-?\d+\.\d+\z/`) that doesn't match these. The
  benchmark files contain only plain integers and simple floats, so output is
  identical in practice.
- ZSV results have GC disabled during calls (zsv-ruby 1.3.1 GC bug on Ruby
  3.4.x) — gives ZSV a slight speed advantage; noted in all output.

---

## ZSV Setup (optional)

ZSV adapters are opt-in. If `require "zsv"` fails, `available?` returns
`false` and both ZSV adapters are silently skipped with a notice.

```bash
# Build zsv-ruby from source
git clone https://github.com/liquidaty/zsv-ruby ~/GitHub/zsv-ruby
cd ~/GitHub/zsv-ruby && bundle install && rake compile

# The benchmarks/specs automatically add ~/GitHub/zsv-ruby/lib to $LOAD_PATH
```

---

## Adding a New Adapter

1. Create `adapters/<parser_name>/<mechanism>.rb` inheriting `Adapters::Base`.
2. Implement `name`, `call(filepath)`, and optionally `available?` and
   `output_type` (default: `:equivalent`).
3. Add the adapter to the `ALL_ADAPTERS` array in `benchmarks/run_all.rb`.
4. If `:equivalent`, add a spec file in `spec/adapters/` using the
   `"equivalent to SmarterCSV"` shared example.

Minimal example:

```ruby
# adapters/my_parser/my_parser.rb
require_relative "../base"

module Adapters
  module MyParser
    class Default < Base
      def name = "MyParser.parse (smarter_csv-equivalent)"

      def available?
        require "my_gem"
        true
      rescue LoadError
        false
      end

      def call(filepath)
        # Must return Array<Hash> with Symbol keys, numeric conversion, etc.
        MyGem.parse(filepath)
      end
    end
  end
end
```

---

## Multi-Version SmarterCSV Comparison

Compare specific installed gem versions side-by-side:

```bash
# Install the versions you want to compare
gem install smarter_csv -v 1.14.4
gem install smarter_csv -v 1.15.2
gem install smarter_csv -v 1.16.0

# Run comparison (each version runs in an isolated subprocess via fork)
rake versions

# Override the version list:
VERSIONS=1.14.4,1.16.0 ruby benchmarks/smarter_csv_versions.rb
```

---

## Benchmark Methodology

- **Warmup:** 2 discarded runs before measurement. C extensions benefit
  disproportionately from warmup (cold I-cache, branch predictors, Ruby object
  caches). Without warmup, C extension times are inflated 1.6×–7.2× versus
  warmed numbers — skipping warmup understates C extension performance.
- **Measurement:** Best of 6 timed runs (minimum time, not mean). Minimum is
  most reproducible and least affected by GC pauses or OS scheduler noise.
- **Between runs:** `GC.start` (and `GC.compact` where supported) to level
  the playing field across adapters.

---

## Running Specs Only

```bash
bundle exec rspec                                        # all specs
bundle exec rspec spec/adapters/ruby_csv_table_spec.rb  # one adapter
bundle exec rspec --format documentation                # verbose
```

---

## Available Rake Tasks

```
rake install       # Unzip CSV benchmark files (alias for unzip_csv)
rake unzip_csv     # Unzip csv_files.zip → csv_files/
rake zip_csv       # Zip csv_files/ → csv_files.zip (run before committing new files)
rake spec          # Run equivalence specs
rake bench         # Run specs, then full benchmark suite
rake compare       # Run specs, then fair-group comparison
rake versions      # Run specs, then multi-version SmarterCSV comparison
rake profile[f]    # Profile a single CSV file with tools/csv_profile.rb
```

---

## Project Structure

```
csv-benchmarks/
├── adapters/               # One file per CSV mechanism
│   ├── base.rb
│   ├── ruby_csv/           # Ruby stdlib CSV adapters
│   ├── smarter_csv/        # SmarterCSV adapters
│   └── zsv/                # ZSV adapters (opt-in)
├── spec/
│   ├── spec_helper.rb
│   ├── support/
│   │   └── equivalence_helper.rb
│   ├── adapters/           # One spec per :equivalent adapter
│   └── fixtures/           # Small hand-crafted CSV files for specs
├── benchmarks/
│   ├── run_all.rb          # All adapters × all csv_files/
│   ├── compare_parsers.rb  # Fair-group comparison
│   └── smarter_csv_versions.rb  # Multi-version comparison
├── tools/
│   ├── csv_profile.rb      # ~30-metric CSV profiler
│   └── generate_csv.rb     # Synthetic CSV generator
├── csv_files/              # Gitignored — populated by rake install
│   ├── actual/             # Real-world files (anonymized)
│   └── synthetic/          # Stress-test files
├── csv_files.zip           # Committed binary — source of truth for csv_files/
└── results/                # Timestamped benchmark output
```
